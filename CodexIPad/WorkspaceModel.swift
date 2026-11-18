import Foundation
import SwiftUI

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var sessions: [CodexSessionSummary] = []
    @Published private(set) var projects: [CodexProject] = []
    @Published private(set) var models: [CodexModel] = []
    @Published private(set) var supportsCatalog = false
    @Published private(set) var supportsTerminal = false
    @Published private(set) var supportsProjects = false
    @Published private(set) var codexReady = false
    @Published private(set) var agents: [CLIAgent] = []
    @Published var newAgent = "codex"
    @Published var newSessionMode = "chat"
    @Published var customCommand = ""
    @Published private(set) var historyCursor: String?
    @Published private(set) var catalogStatus = ""
    @Published private(set) var selected: CodexSession?
    @Published private(set) var selectedID: String?
    @Published private(set) var isPrepared = false
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    @Published private(set) var status = "连接后准备工作区"
    @Published private(set) var listing: DirectoryListing?
    @Published private(set) var hasUncertainSend = false
    @Published private(set) var hasUncertainCreate = false
    @Published var draft = ""
    @Published var proxyURL = ""
    @Published var selectedModel = ""
    @Published var selectedEffort = ""
    @Published var search = ""

    let connection: ConnectionModel
    private var isRefreshing = false
    private var isSyncingHistory = false
    private var storageKey: String { "workspace.\(connection.profile.endpoint).\(connection.profile.username)" }
    private var pendingKey: String { storageKey + ".pending" }
    private var pendingCreateKey: String { storageKey + ".pendingCreate" }
    private let pendingOperations = PendingOperationStore()
    private var activeServerKey: String?
    private var savedProxy: String {
        UserDefaults.standard.string(forKey: storageKey + ".proxy") ??
        (connection.savedServers.first?.id == connection.profile.id ? UserDefaults.standard.string(forKey: "codexNetworkProxy") : nil) ?? ""
    }

    init(connection: ConnectionModel) { self.connection = connection }

    var chosenModel: CodexModel? { models.first(where: { $0.model == selectedModel }) }
    var createsTerminal: Bool { newAgent != "codex" || newSessionMode == "terminal" }
    var canCreateSession: Bool {
        if !createsTerminal { return codexReady }
        return supportsTerminal && (newAgent == "custom" ? !customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty :
            agents.contains(where: { $0.id == newAgent && $0.available }))
    }
    var visibleProjects: [CodexProject] {
        projects.filter { project in
            search.isEmpty || project.title.localizedCaseInsensitiveContains(search) || project.id.localizedCaseInsensitiveContains(search) ||
            sessions.contains(where: { $0.cwd == project.id && $0.title.localizedCaseInsensitiveContains(search) })
        }
    }
    func sessions(in project: CodexProject) -> [CodexSessionSummary] {
        sessions.filter { $0.cwd == project.id && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || project.title.localizedCaseInsensitiveContains(search) || project.id.localizedCaseInsensitiveContains(search)) }
    }
    func modelChanged() { selectedEffort = "" }

    func prepare() async {
        guard connection.isConnected, !isBusy else { return }
        isBusy = true
        error = nil
        status = "正在准备服务器工作区…"
        if activeServerKey != storageKey {
            resetWorkspace()
            activeServerKey = storageKey
            proxyURL = savedProxy
        }
        defer { isBusy = false }
        do {
            var resources: [String: String] = [:]
            for name in ["bridge", "terminal_runtime"] {
                guard let url = Bundle.main.url(forResource: name, withExtension: "py") else {
                    throw ConnectionError.message("App 缺少后台脚本资源，请重新构建工程。")
                }
                resources[name + ".py"] = try Data(contentsOf: url).base64EncodedString()
            }
            let resourceData = try JSONEncoder().encode(resources).base64EncodedString()
            let installer = """
            import base64,os,pathlib,tempfile
            os.umask(0o077)
            directory=pathlib.Path.home()/'.local/share/codex-ipad'
            directory.mkdir(parents=True,exist_ok=True,mode=0o700)
            if directory.is_symlink() or directory.stat().st_uid != os.getuid(): raise RuntimeError('Invalid bridge directory')
            directory.chmod(0o700)
            import json
            resources=json.loads(base64.b64decode('\(resourceData)',validate=True))
            for name,encoded in resources.items():
                target=directory/name
                if target.is_symlink(): raise RuntimeError('Invalid bridge file')
                with tempfile.NamedTemporaryFile(dir=directory,delete=False) as file:
                    file.write(base64.b64decode(encoded,validate=True))
                    temporary=file.name
                os.replace(temporary,target)
            print('installed')
            """
            _ = try await connection.runCommand("python3 -c " + RemoteShell.quote(installer), limit: 4096)
            let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(proxy, forKey: storageKey + ".proxy")
            let result: BridgeStatus = try await connection.runBridge(mode: "ensure", proxy: proxy)
            guard (1...3).contains(result.protocol), result.ready else {
                throw ConnectionError.message("后台协议不匹配或工作区未就绪。")
            }
            guard result.protocol >= 3 || result.authenticated else {
                throw ConnectionError.message("服务器的 Codex 尚未登录，请先在服务器完成 codex login。")
            }
            isPrepared = true
            codexReady = result.codexReady ?? true
            supportsCatalog = result.protocol >= 2 && codexReady
            supportsTerminal = result.capabilities?.contains("terminal") == true
            supportsProjects = result.protocol >= 2
            agents = result.agents ?? []
            if !codexReady && newAgent == "codex", let first = agents.first(where: { $0.available }) {
                newAgent = first.id; newSessionMode = "terminal"
            }
            selectedID = UserDefaults.standard.string(forKey: storageKey + ".selection")
            hasUncertainSend = UserDefaults.standard.data(forKey: pendingKey) != nil
            hasUncertainCreate = try pendingOperations.read(pendingCreateKey) != nil
            status = result.upgradePending == true ? "后台更新待完成；请先处理运行中或待审批的任务，再重新准备工作区。" :
                supportsTerminal ? "工作区已就绪 · \(agents.filter(\.available).count) 种 CLI 可用" : "Codex 已就绪 · \(result.accountType)"
            try await refreshThrowing()
            await browse(result.root)
            if supportsCatalog {
                await syncHistory(reset: true)
                await loadModels()
            }
            if let selectedID { await select(selectedID) }
        } catch {
            self.error = error.localizedDescription
            status = "工作区未就绪"
        }
    }

    func poll() async {
        var ticks = 0
        while !Task.isCancelled, connection.isConnected {
            if isPrepared { await refresh() }
            ticks += 1
            if isPrepared, !isBusy, ticks % 15 == 0 { await syncHistory(reset: true) }
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
        if activeServerKey != storageKey {
            resetWorkspace()
            activeServerKey = storageKey
            proxyURL = savedProxy
        }
        if !connection.isConnected {
            isPrepared = false
            status = "连接已断开，服务器上的任务继续执行；重新连接后准备工作区即可恢复。"
        }
    }

    private func resetWorkspace() {
        sessions = []; projects = []; models = []; selected = nil; selectedID = nil
        isPrepared = false; supportsCatalog = false; historyCursor = nil; catalogStatus = ""
        supportsTerminal = false; supportsProjects = false; codexReady = false; agents = []
        newAgent = "codex"; newSessionMode = "chat"; customCommand = ""
        selectedModel = ""; selectedEffort = ""; draft = ""; hasUncertainSend = false; listing = nil; error = nil
        hasUncertainCreate = false
    }

    func syncHistory(reset: Bool) async {
        guard supportsCatalog, !isSyncingHistory else { return }
        isSyncingHistory = true
        defer { isSyncingHistory = false }
        do {
            var cursor = reset ? nil : historyCursor
            var seen: Set<String> = []
            var skipped = 0
            repeat {
                try Task.checkCancellation()
                var fields = ["action": JSONValue.string("catalog")]
                if let cursor { fields["cursor"] = .string(cursor) }
                let page: CodexCatalogPage = try await request(fields)
                historyCursor = page.nextCursor
                skipped += page.skipped
                try await refreshThrowing()
                cursor = page.nextCursor
                if let cursor, !seen.insert(cursor).inserted {
                    throw ConnectionError.message("服务器返回重复的历史分页游标，请重新同步。")
                }
            } while cursor != nil
            catalogStatus = "已读取服务器 Codex 历史，按项目分组。" + (skipped > 0 ? "有 \(skipped) 个会话的目录不可用或超出工作根目录。" : "")
        } catch { self.error = error.localizedDescription }
    }

    func loadModels() async {
        guard supportsCatalog else { return }
        do {
            let catalog: CodexModelCatalog = try await request(["action": .string("models"), "refresh": .bool(true)])
            models = catalog.models
        } catch { self.error = error.localizedDescription }
    }

    func historyPage(sessionID: String, cursor: String?) async throws -> CodexHistoryPage {
        var fields = ["action": JSONValue.string("historyPage"), "sessionId": .string(sessionID)]
        if let cursor { fields["cursor"] = .string(cursor) }
        return try await request(fields)
    }

    func browse(_ path: String) async {
        do {
            listing = try await request(["action": .string("directories"), "path": .string(path)])
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func select(_ identifier: String) async {
        let server = storageKey
        selectedID = identifier
        selected = nil
        UserDefaults.standard.set(identifier, forKey: storageKey + ".selection")
        if supportsCatalog || supportsTerminal {
            do { let _: JSONValue = try await request(["action": .string("open"), "sessionId": .string(identifier)]) }
            catch { self.error = error.localizedDescription }
        }
        guard storageKey == server, selectedID == identifier else { return }
        while isRefreshing {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard storageKey == server, selectedID == identifier, connection.isConnected else { return }
        }
        await refresh()
        if let selected, selected.id == identifier {
            selectedModel = selected.model ?? ""
            selectedEffort = selected.effort ?? ""
        }
    }

    func reloadCurrent() async {
        if let selectedID { await select(selectedID) } else { await refresh() }
    }

    func addProject(cwd: String) async -> Bool {
        var added = false
        await action {
            let _: JSONValue = try await self.request(["action": .string("addProject"), "cwd": .string(cwd), "operationId": .string(UUID().uuidString)])
            added = true
        }
        return added
    }

    func create(cwd: String) async -> Bool {
        guard canCreateSession || hasUncertainCreate else { return false }
        var created = false
        await action {
            let fields: [String: JSONValue]
            if let pending = try self.pendingOperations.read(self.pendingCreateKey) {
                fields = try JSONDecoder().decode([String: JSONValue].self, from: pending)
                guard fields["cwd"]?.string == cwd else {
                    throw ConnectionError.message("另一个目录的新建结果待确认，请先重试原新建请求。")
                }
            } else {
                var body: [String: JSONValue] = ["action": .string("create"), "cwd": .string(cwd), "operationId": .string(UUID().uuidString)]
                if self.supportsTerminal {
                    body["agent"] = .string(self.newAgent)
                    body["mode"] = .string(self.createsTerminal ? "terminal" : "chat")
                    if self.newAgent == "custom" { body["command"] = .string(self.customCommand) }
                }
                if !self.createsTerminal { self.addModelSettings(to: &body) }
                fields = body
                try self.pendingOperations.save(JSONEncoder().encode(fields), for: self.pendingCreateKey)
            }
            self.hasUncertainCreate = true
            let value: JSONValue = try await self.request(fields)
            guard let id = value["id"].string else { throw ConnectionError.message("服务器没有返回新会话 ID。") }
            try self.pendingOperations.remove(self.pendingCreateKey)
            self.hasUncertainCreate = false
            await self.select(id)
            created = true
        }
        return created
    }

    func retryCreate() async {
        do {
            guard let pending = try pendingOperations.read(pendingCreateKey) else { hasUncertainCreate = false; return }
            let fields = try JSONDecoder().decode([String: JSONValue].self, from: pending)
            guard let cwd = fields["cwd"]?.string else { throw ConnectionError.message("待确认的新建记录格式不正确。") }
            _ = await create(cwd: cwd)
        } catch { self.error = error.localizedDescription }
    }

    func discardCreate() {
        do {
            try pendingOperations.remove(pendingCreateKey)
            hasUncertainCreate = false
        } catch { self.error = error.localizedDescription }
    }

    func send() async {
        guard let identifier = selectedID, selected?.isTerminal != true else { return }
        await action {
            let request: [String: JSONValue]
            if let data = UserDefaults.standard.data(forKey: self.pendingKey) {
                request = try JSONDecoder().decode([String: JSONValue].self, from: data)
                guard request["sessionId"]?.string == identifier else {
                    throw ConnectionError.message("另一会话有待确认的发送，请先切回该会话处理。")
                }
            } else {
                guard !self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                var fields: [String: JSONValue] = ["action": .string("send"), "sessionId": .string(identifier),
                           "text": .string(self.draft), "operationId": .string(UUID().uuidString)]
                self.addModelSettings(to: &fields)
                request = fields
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
        if let projects = snapshot.projects { self.projects = projects }
        else {
            self.projects = Array(Set(sessions.map(\.cwd))).sorted().map { CodexProject(id: $0, title: URL(fileURLWithPath: $0).lastPathComponent) }
        }
        guard selectedID == requestedID else { return }
        selected = snapshot.selected
        if snapshot.codexReady == false {
            codexReady = false; supportsCatalog = false
        }
        if !snapshot.ready {
            isPrepared = false
            throw ConnectionError.message("Codex 后台已退出，请检查服务器后台日志。")
        }
    }

    private func action(_ body: () async throws -> Void) async {
        guard !isBusy, isPrepared, connection.isConnected else { return }
        isBusy = true
        let server = storageKey
        error = nil
        defer { isBusy = false }
        do { try await body(); try await refreshThrowing() }
        catch { if server == storageKey { self.error = error.localizedDescription } }
    }

    private func request<Value: Decodable>(_ fields: [String: JSONValue]) async throws -> Value {
        let server = storageKey
        let value: Value = try await connection.runBridge(mode: "call", fields: fields)
        guard server == storageKey else { throw CancellationError() }
        return value
    }

    private func addModelSettings(to fields: inout [String: JSONValue]) {
        guard supportsCatalog, !selectedModel.isEmpty else { return }
        fields["model"] = .string(selectedModel)
        if !selectedEffort.isEmpty { fields["effort"] = .string(selectedEffort) }
    }
}
