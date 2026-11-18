import SwiftUI
import WebKit

@MainActor
final class TerminalSessionModel: ObservableObject {
    @Published private(set) var error: String?
    @Published private(set) var hasPendingInput = false
    @Published private(set) var isLive = false
    private let connection: ConnectionModel
    private let sessionID: String
    private let serverKey: String
    private let pendingKey: String
    private let pendingStore = PendingOperationStore()
    private weak var webView: WKWebView?
    private var ready = false
    private var offset = 0
    private var epoch = ""
    private var queued = Data()
    private var inputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var size = (cols: 100, rows: 30)

    init(connection: ConnectionModel, sessionID: String) {
        self.connection = connection
        self.sessionID = sessionID
        serverKey = connection.profile.credentialAccount
        pendingKey = "terminal.\(serverKey).\(sessionID).pending"
        do { hasPendingInput = try pendingStore.read(pendingKey) != nil }
        catch { hasPendingInput = true; self.error = error.localizedDescription }
    }

    func attach(_ view: WKWebView) {
        webView = view; ready = true; offset = 0; epoch = ""
    }

    func detach() {
        ready = false; webView = nil
        inputTask?.cancel(); inputTask = nil
        resizeTask?.cancel(); resizeTask = nil
        queued.removeAll()
    }

    private var available: Bool {
        connection.isConnected && connection.profile.credentialAccount == serverKey
    }

    private func request<Value: Decodable>(_ fields: [String: JSONValue]) async throws -> Value {
        guard available else { throw ConnectionError.message("SSH 已断开，重新连接后可继续读取终端。") }
        var body = fields
        body["sessionId"] = .string(sessionID)
        let result: Value = try await connection.runBridge(mode: "call", fields: body)
        guard available else { throw CancellationError() }
        return result
    }

    func poll() async {
        while !Task.isCancelled {
            var more = false
            if !available { isLive = false }
            if ready, let view = webView, available {
                do {
                    let chunk: TerminalChunk = try await request([
                        "action": .string("terminalRead"), "offset": .number(Double(offset)), "epoch": .string(epoch)
                    ])
                    guard !Task.isCancelled, ready, webView === view else { return }
                    isLive = ["starting", "inProgress"].contains(chunk.status)
                    // Await xterm's write callback before acknowledging the output offset.
                    _ = try await view.callAsyncJavaScript("""
                        window.cliTerminal.setInput(enabled);
                        await window.cliTerminal.write(data, reset, replay);
                        """, arguments: ["data": chunk.data, "reset": chunk.reset,
                                         "replay": chunk.replay, "enabled": isLive && !hasPendingInput],
                        in: nil, contentWorld: .page)
                    offset = chunk.nextOffset; epoch = chunk.epoch; more = chunk.hasMore
                    if !hasPendingInput { error = nil }
                } catch {
                    self.error = error.localizedDescription
                    try? await view.evaluateJavaScript("window.cliTerminal?.setInput(false)")
                }
            }
            do { try await Task.sleep(for: more ? .milliseconds(50) : .milliseconds(600)) }
            catch { return }
        }
    }

    func enqueue(_ text: String) {
        guard available, isLive, !hasPendingInput else { return }
        guard queued.count + text.utf8.count <= 65536 else {
            error = "待发送输入过多，请等待发送完成。"; return
        }
        queued.append(contentsOf: text.utf8)
        scheduleInput()
    }

    private func scheduleInput() {
        guard inputTask == nil else { return }
        inputTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            guard let self else { return }
            await self.flushInput()
            self.inputTask = nil
        }
    }

    private func flushInput() async {
        while !Task.isCancelled, available {
            do {
                let fields: [String: JSONValue]
                let bytes: Data
                if let pending = try pendingStore.read(pendingKey) {
                    fields = try JSONDecoder().decode([String: JSONValue].self, from: pending)
                    guard let raw = fields["dataBase64"]?.string, let decoded = Data(base64Encoded: raw) else {
                        throw ConnectionError.message("本机待确认输入格式不正确。")
                    }
                    bytes = decoded
                } else {
                    guard !queued.isEmpty else { return }
                    bytes = Data(queued.prefix(8192))
                    fields = ["action": .string("terminalInput"), "dataBase64": .string(bytes.base64EncodedString()),
                              "operationId": .string(UUID().uuidString)]
                    try pendingStore.save(JSONEncoder().encode(fields), for: pendingKey)
                    queued.removeFirst(bytes.count)
                }
                struct Receipt: Decodable { let written: Int }
                let receipt: Receipt = try await request(fields)
                guard receipt.written > 0, receipt.written <= bytes.count else {
                    throw ConnectionError.message("终端输入回执不正确，请核实终端状态。")
                }
                try pendingStore.remove(pendingKey)
                hasPendingInput = false
                if receipt.written < bytes.count {
                    queued.insert(contentsOf: bytes.dropFirst(receipt.written), at: 0)
                }
                error = nil
            } catch {
                error = "输入结果待确认：\(error.localizedDescription)"
                hasPendingInput = true
                return
            }
        }
    }

    func retryInput() { scheduleInput() }

    func sendKey(_ data: String) async {
        guard available, ready, isLive, !hasPendingInput, let view = webView else { return }
        do {
            _ = try await view.callAsyncJavaScript("window.cliTerminal.key(data)",
                arguments: ["data": data], in: nil, contentWorld: .page)
        } catch { self.error = error.localizedDescription }
    }

    func pasteAndSubmit(_ text: String) async -> Bool {
        guard available, ready, isLive, !hasPendingInput, let view = webView else { return false }
        guard text.utf8.count + queued.count <= 60000 else {
            error = "提示词过长，请分段输入。"; return false
        }
        do {
            let result = try await view.callAsyncJavaScript("return window.cliTerminal.pasteAndSubmit(text)",
                arguments: ["text": text], in: nil, contentWorld: .page)
            return result as? Bool == true
        } catch { self.error = error.localizedDescription; return false }
    }

    func discardInput() {
        do {
            try pendingStore.remove(pendingKey)
            queued.removeAll(); hasPendingInput = false; error = nil
        } catch { self.error = error.localizedDescription }
    }

    func resize(cols: Int, rows: Int) {
        size = (max(20, min(cols, 400)), max(5, min(rows, 200)))
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, self.available else { return }
            do {
                let _: JSONValue = try await self.request([
                    "action": .string("terminalResize"), "cols": .number(Double(self.size.cols)),
                    "rows": .number(Double(self.size.rows))
                ])
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct CLIWebTerminal: UIViewRepresentable {
    @ObservedObject var model: TerminalSessionModel

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "terminal")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        if let url = Bundle.main.url(forResource: "terminal", withExtension: "html", subdirectory: "Terminal") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
        view.navigationDelegate = nil
        coordinator.model.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let model: TerminalSessionModel
        init(_ model: TerminalSessionModel) { self.model = model }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let view = message.webView,
                  let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready": model.attach(view)
            case "input": if let data = body["data"] as? String { model.enqueue(data) }
            case "resize":
                if let cols = body["cols"] as? Int, let rows = body["rows"] as? Int {
                    model.resize(cols: cols, rows: rows)
                }
            default: break
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            model.detach(); webView.reload()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let allowed = navigationAction.request.url?.isFileURL == true && navigationAction.navigationType == .other
            decisionHandler(allowed ? .allow : .cancel)
        }
    }
}

struct TerminalSessionView: View {
    @StateObject private var model: TerminalSessionModel
    @State private var draft = ""
    @State private var discard = false

    init(connection: ConnectionModel, sessionID: String) {
        _model = StateObject(wrappedValue: TerminalSessionModel(connection: connection, sessionID: sessionID))
    }

    var body: some View {
        VStack(spacing: 0) {
            CLIWebTerminal(model: model)
            VStack(alignment: .leading, spacing: 8) {
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if model.hasPendingInput {
                    HStack {
                        Text("输入回执待确认").font(.caption)
                        Button("重试原输入") { model.retryInput() }
                        Button("清除待确认输入") { discard = true }
                    }.font(.caption)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        key("Esc", "\u{1b}"); key("Tab", "\t"); key("Shift Tab", "\u{1b}[Z")
                        key("↑", "\u{1b}[A"); key("↓", "\u{1b}[B")
                        key("←", "\u{1b}[D"); key("→", "\u{1b}[C")
                        key("Ctrl-C", "\u{03}"); key("Ctrl-D", "\u{04}"); key("Enter", "\r")
                    }.buttonStyle(.bordered)
                }.disabled(!model.isLive || model.hasPendingInput)
                HStack(alignment: .bottom) {
                    TextField("输入提示词或回复…", text: $draft, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().lineLimit(1...5)
                    Button("输入并回车") {
                        let text = draft
                        Task { if await model.pasteAndSubmit(text), draft == text { draft = "" } }
                    }.disabled(draft.isEmpty || !model.isLive || model.hasPendingInput)
                }
                Text("点终端可直接输入。登录、模型选择与审批按各 CLI 的提示操作。")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(12).background(Color(.secondarySystemGroupedBackground))
        }
        .task { await model.poll() }
        .confirmationDialog("已核实终端状态，清除本机待确认输入？", isPresented: $discard, titleVisibility: .visible) {
            Button("清除本机记录", role: .destructive) { model.discardInput() }
        } message: {
            Text("已送达的输入不会撤销。请先查看终端，避免再次输入同一条命令。")
        }
    }

    private func key(_ title: String, _ data: String) -> some View {
        Button(title) { Task { await model.sendKey(data) } }
    }
}
