import Foundation
import SwiftUI

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var sessions: [CodexSessionSummary] = []
    @Published private(set) var selected: CodexSession?
    @Published private(set) var selectedID: String?
    @Published private(set) var isPrepared = false
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    @Published private(set) var status = "连接后准备 Codex 工作区"
    @Published private(set) var listing: DirectoryListing?
    @Published private(set) var hasUncertainSend = false
    @Published var draft = ""
    @Published var proxyURL = UserDefaults.standard.string(forKey: "codexNetworkProxy") ?? ""

    let connection: ConnectionModel
    private var isRefreshing = false
    private var storageKey: String { "workspace.\(connection.profile.endpoint).\(connection.profile.username)" }
    private var pendingKey: String { storageKey + ".pending" }

    init(connection: ConnectionModel) { self.connection = connection }

    func prepare() async {
        guard connection.isConnected, !isBusy else { return }
        isBusy = true
        error = nil
        status = "正在准备服务器工作区…"
        defer { isBusy = false }
        do {
            guard let url = Bundle.main.url(forResource: "bridge", withExtension: "py") else {
                throw ConnectionError.message("App 缺少后台脚本资源，请重新构建工程。")
            }
            let encoded = try Data(contentsOf: url).base64EncodedString()
            let installer = """
            import base64,os,pathlib,tempfile
            os.umask(0o077)
            directory=pathlib.Path.home()/'.local/share/codex-ipad'
            directory.mkdir(parents=True,exist_ok=True,mode=0o700)
            if directory.is_symlink() or directory.stat().st_uid != os.getuid(): raise RuntimeError('Invalid bridge directory')
            directory.chmod(0o700)
            target=directory/'bridge.py'
            if target.is_symlink(): raise RuntimeError('Invalid bridge file')
            with tempfile.NamedTemporaryFile(dir=directory,delete=False) as file:
                file.write(base64.b64decode('\(encoded)',validate=True))
                temporary=file.name
            os.replace(temporary,target)
            print('installed')
            """
            _ = try await connection.runCommand("python3 -c " + RemoteShell.quote(installer), limit: 4096)
            let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(proxy, forKey: "codexNetworkProxy")
            let result: BridgeStatus = try await connection.runBridge(mode: "ensure", proxy: proxy)
            guard result.protocol == 1, result.ready else {
                throw ConnectionError.message("后台协议不匹配或 Codex 未就绪。")
            }
            guard result.authenticated else {
                throw ConnectionError.message("服务器的 Codex 尚未登录，请先在服务器完成 codex login。")
            }
            isPrepared = true
            selectedID = UserDefaults.standard.string(forKey: storageKey + ".selection")
            hasUncertainSend = UserDefaults.standard.data(forKey: pendingKey) != nil
            status = "Codex 已就绪 · \(result.accountType)"
            try await refreshThrowing()
            await browse(result.root)
        } catch {
            self.error = error.localizedDescription
            status = "工作区未就绪"
        }
    }

    func poll() async {
        while !Task.isCancelled, connection.isConnected {
            if isPrepared { await refresh() }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    func restart() async {
        guard !isBusy, connection.isConnected else { return }
        isBusy = true
        do {
            let _: JSONValue = try await request(["action": .string("shutdown")])
            isPrepared = false
            try await Task.sleep(for: .seconds(2))
        } catch {
            self.error = error.localizedDescription
            isBusy = false
            return
        }
        isBusy = false
        await prepare()
    }

    func connectionChanged() {
        if !connection.isConnected {
            isPrepared = false
            status = "连接已断开，服务器上的任务继续执行；重新连接后准备工作区即可恢复。"
        }
    }

    func browse(_ path: String) async {
        do {
            listing = try await request(["action": .string("directories"), "path": .string(path)])
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func select(_ identifier: String) async {
        selectedID = identifier
        selected = nil
        UserDefaults.standard.set(identifier, forKey: storageKey + ".selection")
        await refresh()
    }

    func create(cwd: String) async -> Bool {
        var created = false
        await action {
            let value: JSONValue = try await self.request(["action": .string("create"), "cwd": .string(cwd),
                "operationId": .string(UUID().uuidString)])
            guard let id = value["id"].string else { throw ConnectionError.message("服务器没有返回新会话 ID。") }
            await self.select(id)
            created = true
        }
        return created
    }

    func send() async {
        guard let identifier = selectedID else { return }
        await action {
            let request: [String: JSONValue]
            if let data = UserDefaults.standard.data(forKey: self.pendingKey) {
                request = try JSONDecoder().decode([String: JSONValue].self, from: data)
                guard request["sessionId"]?.string == identifier else {
                    throw ConnectionError.message("另一会话有待确认的发送，请先切回该会话处理。")
                }
            } else {
                guard !self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                request = ["action": .string("send"), "sessionId": .string(identifier),
                           "text": .string(self.draft), "operationId": .string(UUID().uuidString)]
                UserDefaults.standard.set(try JSONEncoder().encode(request), forKey: self.pendingKey)
            }
            self.hasUncertainSend = true
            let _: JSONValue = try await self.request(request)
            UserDefaults.standard.removeObject(forKey: self.pendingKey)
            self.hasUncertainSend = false
            self.draft = ""
        }
    }

    func discardPending() {
        // Explicitly clearing only the local retry record never stops a server task.
        UserDefaults.standard.removeObject(forKey: pendingKey)
        hasUncertainSend = false
    }

    func answer(_ approval: CodexApproval, decision: String? = nil, answers: [String: String] = [:]) async {
        guard let identifier = selectedID else { return }
        await action {
            var fields: [String: JSONValue] = ["action": .string("answer"), "sessionId": .string(identifier),
                "requestId": .string(approval.id), "operationId": .string(UUID().uuidString)]
            if let decision { fields["decision"] = .string(decision) }
            fields["answers"] = .object(answers.mapValues(JSONValue.string))
            let _: JSONValue = try await self.request(fields)
        }
    }

    func stop() async {
        guard let identifier = selectedID else { return }
        await action {
            let _: JSONValue = try await self.request(["action": .string("stop"), "sessionId": .string(identifier),
                "operationId": .string(UUID().uuidString)])
        }
    }

    func refresh() async {
        do { try await refreshThrowing() } catch { self.error = error.localizedDescription }
    }

    private func refreshThrowing() async throws {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let requestedID = selectedID
        var fields = ["action": JSONValue.string("snapshot")]
        if let requestedID { fields["sessionId"] = .string(requestedID) }
        let snapshot: CodexSnapshot = try await request(fields)
        sessions = snapshot.sessions
        guard selectedID == requestedID else { return }
        selected = snapshot.selected
        if !snapshot.ready {
            isPrepared = false
            throw ConnectionError.message("Codex 后台已退出，请检查服务器后台日志。")
        }
    }

    private func action(_ body: () async throws -> Void) async {
        guard !isBusy, isPrepared, connection.isConnected else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do { try await body(); try await refreshThrowing() }
        catch { self.error = error.localizedDescription }
    }

    private func request<Value: Decodable>(_ fields: [String: JSONValue]) async throws -> Value {
        try await connection.runBridge(mode: "call", fields: fields)
    }
}
