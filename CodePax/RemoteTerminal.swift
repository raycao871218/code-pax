import SwiftUI
import UIKit
import SwiftTerm
import Citadel
import NIOCore
import NIOSSH

struct TerminalDimensions: Equatable {
    let columns: Int
    let rows: Int
    init(columns: Int, rows: Int) {
        self.columns = min(500, max(2, columns))
        self.rows = min(250, max(1, rows))
    }
}

enum TerminalPolicy {
    static func request(_ size: TerminalDimensions) -> SSHChannelRequestEvent.PseudoTerminalRequest {
        .init(wantReply: true, term: "xterm-256color", terminalCharacterWidth: size.columns,
              terminalRowHeight: size.rows, terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))
    }
    static func startDirectoryCommand(_ directory: String?) -> String? {
        guard let directory, !directory.isEmpty, !directory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return "cd -- " + RemoteShell.quote(directory) + "\r"
    }
}

/// Keep at most three trailing bytes so network packet boundaries cannot split a UTF-8 scalar.
/// Escape sequences stay byte-for-byte intact; their parser already carries state across packets.
struct TerminalOutputBuffer {
    private var pending: [UInt8] = []
    mutating func append(_ bytes: [UInt8]) -> [UInt8] {
        var data = pending + bytes
        pending = []
        guard !data.isEmpty else { return [] }
        var start = data.count - 1
        while start > 0, data[start] & 0xc0 == 0x80, data.count - start < 4 { start -= 1 }
        let lead = data[start]
        let expected = (0xc2...0xdf).contains(lead) ? 2 : (0xe0...0xef).contains(lead) ? 3 : (0xf0...0xf4).contains(lead) ? 4 : 1
        if expected > data.count - start, data[(start + 1)...].allSatisfy({ $0 & 0xc0 == 0x80 }) {
            pending = Array(data[start...]); data.removeSubrange(start...)
        }
        return data
    }
}

enum TerminalSessionState: Equatable {
    case idle, connecting, running, ended, disconnected, failed
    var active: Bool { self == .connecting || self == .running }
    var title: String {
        switch self {
        case .idle: return "尚未启动"
        case .connecting: return "正在打开终端…"
        case .running: return "已连接"
        case .ended: return "终端已结束"
        case .disconnected: return "SSH 已断开"
        case .failed: return "终端连接失败"
        }
    }
}

@MainActor
protocol TerminalConnection: AnyObject {
    var isConnected: Bool { get }
    func withTerminal(dimensions: TerminalDimensions,
                      perform: @MainActor (TTYOutput, TTYStdinWriter) async throws -> Void) async throws
}

/// One PTY per server connection. Retain its emulator while the screen is tucked away.
@MainActor
final class RemoteTerminalModel: NSObject, ObservableObject, @preconcurrency TerminalViewDelegate {
    @Published private(set) var state: TerminalSessionState = .idle
    @Published private(set) var error: String?
    @Published private(set) var directory = ""
    @Published var fontSize: Double = 14 {
        didSet { terminal.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    }
    let terminal: TerminalView
    private weak var connection: (any TerminalConnection)?
    private var sessionTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var events: AsyncStream<Input>.Continuation?
    private var generation = UUID()
    private var dimensions = TerminalDimensions(columns: 80, rows: 24)
    private enum Input { case bytes([UInt8]), resize(TerminalDimensions) }

    init(connection: any TerminalConnection) {
        self.connection = connection
        terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        terminal.terminalDelegate = self
        terminal.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminal.getTerminal().changeHistorySize(2000)
        terminal.optionAsMetaKey = false
        terminal.inputAccessoryView = nil // The screen supplies its own compact key row.
        terminal.accessibilityLabel = "远程命令行终端"
    }

    func start(directory: String?) {
        guard !state.active, let connection, connection.isConnected else { return }
        stop()
        let id = UUID(); generation = id
        self.directory = directory ?? ""
        error = nil; state = .connecting
        terminal.getTerminal().resetToInitialState()
        terminal.feed(text: "\u{1b}[2J\u{1b}[H")
        let input = AsyncStream<Input>.makeStream()
        events = input.continuation
        let initialSize = dimensions
        sessionTask = Task { [weak self, weak connection] in
            guard let self, let connection else { return }
            do {
                try await connection.withTerminal(dimensions: initialSize) { [weak self] inbound, outbound in
                    guard let self, self.generation == id else { throw CancellationError() }
                    try Task.checkCancellation()
                    // Initial shell request and all subsequent input use the same ordered writer.
                    try await outbound.changeSize(cols: self.dimensions.columns, rows: self.dimensions.rows, pixelWidth: 0, pixelHeight: 0)
                    if let command = TerminalPolicy.startDirectoryCommand(directory) {
                        try await outbound.write(ByteBuffer(bytes: command.utf8))
                    }
                    guard self.generation == id else { throw CancellationError() }
                    self.state = .running
                    self.inputTask = Task { [weak self] in
                        do {
                            for await event in input.stream {
                                try Task.checkCancellation()
                                guard self?.generation == id else { return }
                                switch event {
                                case .bytes(let bytes): try await outbound.write(ByteBuffer(bytes: bytes))
                                case .resize(let size):
                                    try await outbound.changeSize(cols: size.columns, rows: size.rows, pixelWidth: 0, pixelHeight: 0)
                                }
                            }
                        } catch {
                            guard let self, self.generation == id, !Task.isCancelled else { return }
                            self.fail(error.localizedDescription)
                        }
                    }
                    defer {
                        input.continuation.finish()
                        if self.generation == id { self.inputTask?.cancel(); self.inputTask = nil; self.events = nil }
                    }
                    var outputBuffer = TerminalOutputBuffer()
                    for try await output in inbound {
                        try Task.checkCancellation()
                        guard self.generation == id else { throw CancellationError() }
                        switch output {
                        case .stdout(let buffer), .stderr(let buffer):
                            let bytes = outputBuffer.append(Array(buffer.readableBytesView))
                            if !bytes.isEmpty { self.terminal.feed(byteArray: bytes[...]) }
                        }
                    }
                }
                guard self.generation == id else { return }
                self.state = .ended
            } catch {
                guard self.generation == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                self.state = connection.isConnected ? .failed : .disconnected
            }
            if self.generation == id { self.sessionTask = nil; self.events?.finish(); self.events = nil }
        }
    }

    func startIfNeeded(directory: String?) { if state == .idle { start(directory: directory) } }
    func stop(disconnected: Bool = false) {
        generation = UUID()
        events?.finish(); events = nil
        inputTask?.cancel(); inputTask = nil
        sessionTask?.cancel(); sessionTask = nil
        if state != .idle { state = disconnected ? .disconnected : .ended }
        _ = terminal.resignFirstResponder()
    }
    private func fail(_ message: String) { stop(); error = message; state = .failed }
    func sendBytes(_ bytes: [UInt8]) {
        guard state == .running, !bytes.isEmpty else { return }
        for offset in stride(from: 0, to: bytes.count, by: 4096) {
            events?.yield(.bytes(Array(bytes[offset..<min(offset + 4096, bytes.count)])))
        }
    }
    func sendKey(_ text: String) {
        let value = terminal.getTerminal().applicationCursor && ["\u{1b}[A", "\u{1b}[B", "\u{1b}[C", "\u{1b}[D"].contains(text)
            ? text.replacingOccurrences(of: "[", with: "O") : text
        sendBytes(Array(value.utf8))
    }
    func clearScreen() { terminal.feed(text: "\u{1b}[2J\u{1b}[H\u{1b}[3J") }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        let updated = TerminalDimensions(columns: newCols, rows: newRows)
        guard updated != dimensions else { return }
        dimensions = updated
        if state == .running { events?.yield(.resize(updated)) }
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sendBytes(Array(data)) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        if let directory, let url = URL(string: directory), url.scheme == "file" { self.directory = url.path }
    }
    func scrolled(source: TerminalView, position: Double) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        UIApplication.shared.open(url)
    }
}

struct RemoteTerminalScreen: View {
    @ObservedObject var model: RemoteTerminalModel
    @ObservedObject var connection: ConnectionModel
    let workingDirectory: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.interfaceTheme) private var theme
    @State private var showKeyBar = true
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                TerminalSurface(model: model).padding(.horizontal, 8).frame(maxWidth: .infinity, maxHeight: .infinity)
                if showKeyBar {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        key("Esc", "\u{1b}"); key("Tab", "\t"); key("Ctrl-C", "\u{03}")
                        key("Ctrl-D", "\u{04}"); key("↑", "\u{1b}[A"); key("↓", "\u{1b}[B")
                        key("←", "\u{1b}[D"); key("→", "\u{1b}[C")
                        Button { if model.terminal.isFirstResponder { _ = model.terminal.resignFirstResponder() } else { _ = model.terminal.becomeFirstResponder() } } label: {
                            Image(systemName: "keyboard").frame(minWidth: 36, minHeight: 36)
                        }.buttonStyle(.bordered)
                    }.padding(.horizontal, 10).padding(.vertical, 4)
                }.background(theme.sidebar)
                }
            }.background(theme.canvas)
                .navigationTitle("终端").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 2) {
                            Text("终端 · " + connection.profile.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                            HStack(spacing: 5) {
                                Circle().fill(model.state == .running ? Color.green : Color.secondary).frame(width: 5, height: 5)
                                Text(model.state.title).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !model.state.active {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("新建终端") { model.start(directory: workingDirectory) }.disabled(!connection.isConnected)
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Toggle("快捷键栏", isOn: $showKeyBar)
                            Button("清屏", systemImage: "eraser") { model.clearScreen() }
                            Stepper("字号 \(Int(model.fontSize))", value: $model.fontSize, in: 11...24)
                            if model.state.active { Button("结束终端", systemImage: "stop.circle", role: .destructive) { model.stop() } }
                            if !model.directory.isEmpty { Text(model.directory) }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("收起") { _ = model.terminal.resignFirstResponder(); dismiss() } }
                }
        }.task {
            model.startIfNeeded(directory: workingDirectory)
            // Sheet presentation may attach the retained terminal after this task starts.
            for _ in 0..<20 {
                guard !Task.isCancelled else { return }
                if model.terminal.window != nil, model.terminal.becomeFirstResponder() { return }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }
    private func key(_ label: String, _ value: String) -> some View {
        Button(label) { model.sendKey(value) }.font(.system(.caption, design: .monospaced))
            .frame(minWidth: 36, minHeight: 36).buttonStyle(.bordered).disabled(model.state != .running)
    }
}

private struct TerminalSurface: UIViewRepresentable {
    @ObservedObject var model: RemoteTerminalModel
    @Environment(\.interfaceTheme) private var theme
    final class Coordinator { var scheme: ColorScheme? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> TerminalView { model.terminal }
    func updateUIView(_ view: TerminalView, context: Context) {
        view.nativeBackgroundColor = UIColor(theme.canvas)
        view.nativeForegroundColor = theme.colorScheme == .dark ? .white : .black
        view.caretColor = UIColor(theme.accent)
        if context.coordinator.scheme != theme.colorScheme {
            context.coordinator.scheme = theme.colorScheme
            let dark = [0x242631, 0xef7b83, 0x80c991, 0xe9c46a, 0x8ea2ff, 0xc397e9, 0x70c7cf, 0xd8dee9,
                        0x7e8493, 0xff9aa2, 0xa3e4b2, 0xffdf91, 0xb2bdff, 0xdfb8ff, 0x9ee4ea, 0xffffff]
            let light = [0x242631, 0xa3263e, 0x286c39, 0x805d13, 0x3356ab, 0x7d3da0, 0x236e78, 0x505764,
                         0x626978, 0xb82f49, 0x327745, 0x8b6418, 0x3b61b8, 0x8a48ad, 0x2b7b85, 0x39404c]
            view.installColors((theme.colorScheme == .dark ? dark : light).map { rgb in
                SwiftTerm.Color(red: UInt16((rgb >> 16) & 255) * 257,
                                green: UInt16((rgb >> 8) & 255) * 257, blue: UInt16(rgb & 255) * 257)
            })
        }
    }
}

#if DEBUG
extension RemoteTerminalModel {
    func loadPreview() {
        state = .running; directory = "/projects/code-pax"
        terminal.feed(text: "\u{1b}[1;35mCode Pax — SSH Terminal\u{1b}[0m\r\n\r\n")
        terminal.feed(text: "\u{1b}[32mdeveloper@server\u{1b}[0m:~/projects/code-pax$ pwd\r\n/projects/code-pax\r\n")
        terminal.feed(text: "\u{1b}[32mdeveloper@server\u{1b}[0m:~/projects/code-pax$ ls\r\n\u{1b}[34mSources  Tests  docs\u{1b}[0m  README.md  Package.swift\r\n")
        terminal.feed(text: "\u{1b}[32mdeveloper@server\u{1b}[0m:~/projects/code-pax$ echo '终端已准备好'\r\n终端已准备好\r\n")
        terminal.feed(text: "\u{1b}[32mdeveloper@server\u{1b}[0m:~/projects/code-pax$ ")
    }
}
struct TerminalPreviewScene: View {
    @StateObject private var connection = ConnectionModel()
    var body: some View {
        RemoteTerminalScreen(model: connection.terminal, connection: connection, workingDirectory: "/projects/code-pax")
            .task { connection.terminal.loadPreview() }
    }
}
#endif
