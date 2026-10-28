import Foundation
import SwiftUI

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var sessions: [CodexSessionSummary] = []
    @Published private(set) var projects: [CodexProject] = []
    @Published private(set) var models: [CodexModel] = []
    @Published private(set) var supportsCatalog = false
    @Published private(set) var supportsAccessMode = false
    @Published private(set) var supportsSessionManagement = false
    @Published private(set) var supportsDownloads = false
    @Published private(set) var historyCursor: String?
    @Published private(set) var catalogStatus = ""
    @Published private(set) var selected: CodexSession?
    @Published private(set) var selectedID: String?
    @Published private(set) var isPrepared = false
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    @Published private(set) var status = "连接后准备 Codex 工作区"
    @Published private(set) var listing: DirectoryListing?
    @Published private(set) var hasUncertainSend = false
    @Published private(set) var localSubmissions: [LocalSubmission] = []
    @Published private(set) var isSending = false
    @Published private(set) var accountUsage: AccountUsage?
    @Published private(set) var isUsageLoading = false
    @Published private(set) var usageError: String?
    @Published private var attachmentDrafts: [String: [UploadedAttachment]] = [:]
    @Published private(set) var isImportingAttachment = false
    @Published private(set) var isUploadingAttachment = false
    @Published private(set) var attachmentProgress = 0.0
    @Published private(set) var uploadingAttachmentName = ""
    @Published private(set) var supportsAttachments = false
    @Published private var completionReads = CompletionReads()
    private var readingSessionID: String?
    private var supportsUsage = false
    private var usageSchedule = UsageRefreshSchedule()
    private var usageRequestID: UUID?
    private let draftStore: DraftStore
    private var draftOwner: DraftAddress?
    private var draftRecord = DraftRecord()
    private var restoringDraft = false
    private var nextPrepareAttempt = Date.distantPast
    @Published var draft = "" {
        didSet {
            guard !restoringDraft, oldValue != draft, let draftOwner else { return }
            draftRecord = DraftRecord(text: draft)
            draftStore.save(draftRecord, at: draftOwner)
        }
    }
    @Published var proxyURL = ""
    @Published var selectedModel = ""
    @Published var selectedEffort = ""
    @Published var accessMode: AccessMode = .fullAccess
    @Published var search = ""

    let connection: ConnectionModel
    private var isRefreshing = false
    private var isSyncingHistory = false
    private var storageKey: String { "workspace.\(connection.profile.endpoint).\(connection.profile.username)" }
    private var pendingKey: String { storageKey + ".pending" }
    private var outboxKey: String { storageKey + ".outbox" }
    private var activeServerKey: String?
    private var savedProxy: String {
        UserDefaults.standard.string(forKey: storageKey + ".proxy") ??
        (connection.savedServers.first?.id == connection.profile.id ? UserDefaults.standard.string(forKey: "codexNetworkProxy") : nil) ?? ""
    }

    init(connection: ConnectionModel, defaults: UserDefaults = .standard) {
        self.connection = connection
        self.draftStore = DraftStore(defaults: defaults)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-workspace") {
            activeServerKey = storageKey
            isPrepared = true
            supportsCatalog = true; supportsAccessMode = true
            supportsSessionManagement = true; supportsDownloads = true
            models = [CodexModel(model: "gpt-5.4", displayName: "GPT-5.4", defaultReasoningEffort: "medium",
                                supportedReasoningEfforts: [CodexEffort(reasoningEffort: "medium", description: nil)], isDefault: true)]
            selectedModel = "gpt-5.4"
            var messages = [
                CodexMessage(id: "preview-user", kind: "userMessage", text: "整理工作区界面，让命令执行更简洁。", status: "completed"),
                CodexMessage(id: "preview-intro", kind: "agentMessage", text: "我会先检查界面结构，再调整消息展示和输入区。", status: "completed"),
                CodexMessage(id: "preview-cmd-1", kind: "commandExecution", text: "rg --files Sources\nSources/WorkspaceView.swift", status: "completed"),
                CodexMessage(id: "preview-cmd-2", kind: "commandExecution", text: "swift test\nAll tests passed", status: "completed"),
                CodexMessage(id: "preview-cmd-3", kind: "commandExecution", text: "git diff --check", status: "completed"),
                CodexMessage(id: "preview-file", kind: "fileChange", text: "Sources/WorkspaceView.swift\n+ Compact activity summary", status: "completed"),
                CodexMessage(id: "preview-reply", kind: "agentMessage", text: "已整理好工作区。\n\n- 连续命令收进执行摘要，点开查看详情。\n- 模型和权限集中在输入区。\n- 保留完整输出，方便需要时检查。", status: "completed")
            ]
            if ProcessInfo.processInfo.arguments.contains("--preview-markdown") {
                draft = "继续优化阅读体验"
                messages = [CodexMessage(id: "markdown-demo", kind: "agentMessage", text: """
                ## Markdown 阅读体验
                **加粗重点**、*斜体说明*、~~删除线~~，以及 `inline code` 都会保留格式。

                ### 清单与引用
                - [x] 标题、列表和任务清单
                - [x] 代码块可复制

                1. 分层列表
                   - 子项保持缩进
                2. 继续阅读

                > 提示：执行详情仍然默认折叠，正文只保留需要阅读的内容。

                ### 代码示例
                ```swift
                let message = "Hello, iPad"
                print(message)
                ```

                | 格式 | 支持情况 |
                | :--- | :---: |
                | 标题 / 列表 | 已支持 |
                | 代码 / 表格 | 已支持 |

                [查看文档](https://example.com/docs)
                """, status: "completed")]
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-message-attachments") {
                messages[0].attachments = [UploadedAttachment(id: "preview-sent", name: "界面截图.jpg", size: 256000, kind: "image", path: "/projects/codex-ipad/screenshot.jpg")]
            }
            selectedID = "preview-session"
            selected = CodexSession(id: "preview-session", title: "整理工作区界面", cwd: "/projects/codex-ipad",
                status: "completed", turnId: nil, messages: messages, approvals: [], diff: "", error: nil,
                historyTruncated: false, readOnly: false, model: "gpt-5.4", effort: "medium", accessMode: "fullAccess")
            sessions = [CodexSessionSummary(id: "preview-session", title: "整理工作区界面", cwd: "/projects/codex-ipad",
                                          status: "completed", updatedAt: 0, origin: "app", model: "gpt-5.4")]
            projects = [CodexProject(id: "/projects/codex-ipad", title: "codex-ipad")]
            if ProcessInfo.processInfo.arguments.contains("--preview-session-management") {
                sessions[0].pinned = true
                sessions.append(CodexSessionSummary(id: "preview-archived", title: "之前的连接排查", cwd: "/projects/codex-ipad",
                    status: "completed", updatedAt: -1, origin: "app", model: nil, archived: true))
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-unread") {
                completionReads.observe(id: "preview-unread", completedTurnID: nil)
                completionReads.observe(id: "preview-unread", completedTurnID: "done")
                sessions.append(CodexSessionSummary(id: "preview-unread", title: "检查服务器连接状态",
                    cwd: "/projects/codex-ipad", status: "completed", updatedAt: 1, origin: "app", model: "gpt-5.4",
                    completedTurnId: "done"))
            }
            status = "界面预览 · 示例数据"
            supportsUsage = true
            supportsAttachments = true
            if ProcessInfo.processInfo.arguments.contains("--preview-attachments") {
                attachmentDrafts["preview-session"] = [
                    UploadedAttachment(id: "preview-image", name: "界面截图.jpg", size: 256000, kind: "image", path: "/preview/image.jpg"),
                    UploadedAttachment(id: "preview-file", name: "需求说明.pdf", size: 42000, kind: "file", path: "/preview/doc.pdf")]
            }
            let total = TokenBreakdown(totalTokens: 28560, inputTokens: 24120, cachedInputTokens: 18400,
                                       outputTokens: 4440, reasoningOutputTokens: 1800)
            let last = TokenBreakdown(totalTokens: 8430, inputTokens: 7500, cachedInputTokens: 6200,
                                      outputTokens: 930, reasoningOutputTokens: 400)
            selected?.tokenUsage = ThreadTokenUsage(total: total, last: last, modelContextWindow: 200000)
            accountUsage = AccountUsage(rateLimits: nil, rateLimitsByLimitId: ["codex": RateLimitBucket(
                limitId: "codex", limitName: "Codex", primary: RateLimitWindow(usedPercent: 28, windowDurationMins: 300,
                    resetsAt: Date().timeIntervalSince1970 + 7200), secondary: RateLimitWindow(usedPercent: 46, windowDurationMins: 10080,
                    resetsAt: Date().timeIntervalSince1970 + 86400 * 3), planType: "pro")],
                threadUsage: selected?.tokenUsage, updatedAt: Date().timeIntervalSince1970, error: nil)
            let previewUsed: Double? = ProcessInfo.processInfo.arguments.contains("--preview-usage-critical") ? 95 :
                ProcessInfo.processInfo.arguments.contains("--preview-usage-warning") ? 85 : nil
            if let previewUsed {
                accountUsage = AccountUsage(rateLimits: RateLimitBucket(limitId: "codex", limitName: "Codex",
                    primary: RateLimitWindow(usedPercent: previewUsed, windowDurationMins: 300, resetsAt: nil),
                    secondary: nil, planType: nil), rateLimitsByLimitId: nil,
                    threadUsage: selected?.tokenUsage, updatedAt: Date().timeIntervalSince1970, error: nil)
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-sending") {
                localSubmissions = [LocalSubmission(operationID: "preview-sending", sessionID: "preview-session",
                                                    text: "把这些改动安装到 iPad。", state: "sending")]
            }
        }
        #endif
    }

    var chosenModel: CodexModel? { models.first(where: { $0.model == selectedModel }) }
    func messages(for session: CodexSession) -> [CodexMessage] {
        MessageTimeline.merge(remote: session.messages, local: localSubmissions, sessionID: session.id)
    }

    private func restoreOutbox() {
        localSubmissions = (UserDefaults.standard.data(forKey: outboxKey).flatMap {
            try? JSONDecoder().decode([LocalSubmission].self, from: $0)
        } ?? []).map { value in
            var restored = value
            if restored.state == "sending" { restored.state = "unknown" }
            return restored
        }
        if let data = UserDefaults.standard.data(forKey: pendingKey),
           let pending = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            let state = localSubmissions.first(where: { $0.operationID == pending["operationId"]?.string })?.state ?? "unknown"
            showSubmission(pending, state: state)
        }
    }

    private func saveOutbox() {
        if let data = try? JSONEncoder().encode(localSubmissions) { UserDefaults.standard.set(data, forKey: outboxKey) }
    }

    private func showSubmission(_ request: [String: JSONValue], state: String) {
        guard let operation = request["operationId"]?.string, let session = request["sessionId"]?.string,
              let rawText = request["text"]?.string else { return }
        let text = request["displayText"]?.string ?? rawText
        let attachmentValues = request["attachmentDetails"]?.array ?? []
        let details = try? JSONDecoder().decode([UploadedAttachment].self, from: JSONEncoder().encode(attachmentValues))
        if let index = localSubmissions.firstIndex(where: { $0.operationID == operation }) {
            localSubmissions[index].state = state
            localSubmissions[index].request = request
        } else {
            localSubmissions.append(LocalSubmission(operationID: operation, sessionID: session, text: text, state: state, attachments: details, request: request))
        }
        saveOutbox()
    }
    var visibleProjects: [CodexProject] {
        projects.filter { project in
            search.isEmpty || project.title.localizedCaseInsensitiveContains(search) || project.id.localizedCaseInsensitiveContains(search) ||
            sessions.contains(where: { $0.archived != true && $0.cwd == project.id && $0.title.localizedCaseInsensitiveContains(search) })
        }
    }
    func sessions(in project: CodexProject) -> [CodexSessionSummary] {
        SessionListPolicy.visible(sessions.filter { $0.cwd == project.id && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || project.title.localizedCaseInsensitiveContains(search) || project.id.localizedCaseInsensitiveContains(search)) })
    }
    func updateSession(_ id: String, title: String? = nil, pinned: Bool? = nil, archived: Bool? = nil) async -> Bool {
        guard supportsSessionManagement else { error = "请先更新服务器后台。"; return false }
        if archived == true && hasUncertainSend { error = "请先确认待发送消息的结果，再归档。"; return false }
        let server = storageKey
        let wasSelected = selectedID == id
        var updated = false
        await action {
            var fields: [String: JSONValue] = ["action": .string("sessionMetadata"), "sessionId": .string(id),
                "operationId": .string(UUID().uuidString)]
            if let title { fields["title"] = .string(title) }
            if let pinned { fields["pinned"] = .bool(pinned) }
            if let archived { fields["archived"] = .bool(archived) }
            let _: JSONValue = try await self.request(fields)
            updated = true
        }
        guard storageKey == server else { return false }
        if updated, archived == true, wasSelected {
            if let next = sessions.first(where: { $0.id != id && $0.archived != true }) { await select(next.id) }
            else {
                clearSelection()
            }
        }
        return updated
    }

    func downloadFile(sessionID: String, path: String, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL {
        guard supportsDownloads else { throw ConnectionError.message("请先更新服务器后台。") }
        let server = storageKey
        let info: RemoteFileInfo = try await request(["action": .string("fileInfo"), "sessionId": .string(sessionID), "path": .string(path)])
        guard URL(fileURLWithPath: info.name).lastPathComponent == info.name, !info.name.isEmpty else { throw ConnectionError.message("无效文件名。") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(info.name)
        do {
            try await connection.downloadFile(info, to: target, progress: progress)
            guard storageKey == server else { throw CancellationError() }
            return target
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    private func clearSelection() {
        selectedID = nil; selected = nil; draftOwner = nil; draft = ""
        UserDefaults.standard.removeObject(forKey: storageKey + ".selection")
    }

    var canAddAttachments: Bool {
        isPrepared && connection.isConnected && supportsAttachments && !isBusy && !isPreparingAttachment &&
        !hasUncertainSend && attachments.count < AttachmentPolicy.maximumCount
    }

    func modelChanged() { selectedEffort = "" }
    func accessModeChanged() {
        UserDefaults.standard.set(accessMode.rawValue, forKey: storageKey + ".accessMode")
    }

    private func restoreAccessMode() {
        accessMode = AccessMode(rawValue: UserDefaults.standard.string(forKey: storageKey + ".accessMode") ?? "fullAccess") ?? .standard
    }

    func prepare() async {
        guard connection.isConnected, !isBusy else { return }
        isBusy = true
        nextPrepareAttempt = Date().addingTimeInterval(15)
        error = nil
        status = "正在准备服务器工作区…"
        if activeServerKey != storageKey {
            resetWorkspace()
            activeServerKey = storageKey
            proxyURL = savedProxy
            restoreAccessMode()
            restoreOutbox()
            restoreCompletionReads()
            restoreAttachments()
        }
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
            UserDefaults.standard.set(proxy, forKey: storageKey + ".proxy")
            let result: BridgeStatus = try await connection.runBridge(mode: "ensure", proxy: proxy)
            guard (1...2).contains(result.protocol), result.ready else {
                throw ConnectionError.message("后台协议不匹配或 Codex 未就绪。")
            }
            guard result.authenticated else {
                throw ConnectionError.message("服务器的 Codex 尚未登录，请先在服务器完成 codex login。")
            }
            isPrepared = true
            supportsCatalog = result.protocol >= 2
            supportsAccessMode = result.capabilities?.contains("accessMode") == true
            supportsUsage = result.capabilities?.contains("usage") == true
            supportsAttachments = result.capabilities?.contains("attachments") == true
            supportsSessionManagement = result.capabilities?.contains("manageSessions") == true
            supportsDownloads = result.capabilities?.contains("downloadFiles") == true
            selectedID = UserDefaults.standard.string(forKey: storageKey + ".selection")
            if let selectedID { activateDraft(selectedID) }
            hasUncertainSend = UserDefaults.standard.data(forKey: pendingKey) != nil
            await reconcilePendingSend()
            status = result.upgradePending == true ? "后台更新待完成；请先处理运行中或待审批的任务，再重新准备工作区。" : "Codex 已就绪 · \(result.accountType)"
            try await refreshThrowing()
            await browse(result.root)
            if supportsCatalog {
                await syncHistory(reset: true)
                await loadModels()
                if let selectedID { await select(selectedID) }
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
            status = "工作区未就绪"
        }
    }

    func poll() async {
        var ticks = 0
        while !Task.isCancelled, connection.isConnected {
            if isPrepared { await refresh() }
            else if !isBusy, Date() >= nextPrepareAttempt { await prepare() }
            ticks += 1
            if isPrepared, !isBusy, ticks % 15 == 0 { await syncHistory(reset: true) }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    func pollUsage() async {
        while !Task.isCancelled, connection.isConnected {
            if isPrepared, supportsUsage { await refreshUsage() }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-workspace") { return }
        #endif
        if activeServerKey != storageKey {
            resetWorkspace()
            activeServerKey = storageKey
            proxyURL = savedProxy
            restoreAccessMode()
            restoreOutbox()
            restoreCompletionReads()
            restoreAttachments()
        }
        if !connection.isConnected {
            isPrepared = false
            usageRequestID = nil; isUsageLoading = false
            usageSchedule = UsageRefreshSchedule(); accountUsage = nil; usageError = nil
            status = "连接已断开，服务器上的任务继续执行；重新连接后准备工作区即可恢复。"
        }
    }

    var unreadSessions: [CodexSessionSummary] { sessions.filter { $0.archived != true && isUnread($0.id) } }
    var archivedSessions: [CodexSessionSummary] { sessions.filter { $0.archived == true } }

    func isUnread(_ id: String) -> Bool { completionReads.isUnread(id) }

    func setReadingSession(_ id: String?) {
        readingSessionID = id
        acknowledgeVisibleCompletion()
    }

    private func acknowledgeVisibleCompletion() {
        guard let selected, selected.id == readingSessionID else { return }
        completionReads.markRead(id: selected.id, completedTurnID: selected.completedTurnId)
        saveCompletionReads()
    }

    private func saveCompletionReads() {
        if let data = try? JSONEncoder().encode(completionReads) {
            UserDefaults.standard.set(data, forKey: storageKey + ".completionReads")
        }
    }

    private func restoreCompletionReads() {
        guard let data = UserDefaults.standard.data(forKey: storageKey + ".completionReads"),
              let saved = try? JSONDecoder().decode(CompletionReads.self, from: data) else { return }
        completionReads = saved
    }

    private func resetWorkspace() {
        draftOwner = nil
        nextPrepareAttempt = .distantPast
        sessions = []; projects = []; models = []; selected = nil; selectedID = nil
        isPrepared = false; supportsCatalog = false; historyCursor = nil; catalogStatus = ""
        supportsAccessMode = false; supportsSessionManagement = false; supportsDownloads = false
        supportsUsage = false; accountUsage = nil; usageError = nil
        usageRequestID = nil; isUsageLoading = false; usageSchedule = UsageRefreshSchedule()
        localSubmissions = []
        attachmentDrafts = [:]; supportsAttachments = false
        completionReads = CompletionReads(); readingSessionID = nil
        selectedModel = ""; selectedEffort = ""; draft = ""; hasUncertainSend = false; listing = nil; error = nil
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
            catalogStatus = "已读取服务器 CLI / Codex 会话，按项目分组。" + (skipped > 0 ? "有 \(skipped) 个会话的目录不可用或超出工作根目录。" : "")
        } catch { self.error = error.localizedDescription }
    }

    func loadModels() async {
        guard supportsCatalog else { return }
        do {
            let catalog: CodexModelCatalog = try await request(["action": .string("models"), "refresh": .bool(true)])
            models = catalog.models
        } catch { self.error = error.localizedDescription }
    }

    func refreshUsage(force: Bool = false) async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-workspace") { return }
        #endif
        guard !isUsageLoading else { return }
        guard connection.isConnected, isPrepared else { usageError = "请先连接服务器并准备工作区。"; return }
        guard supportsUsage else { usageError = "当前后台需要更新，请在设置中重新准备工作区。"; return }
        let now = Date()
        guard force || usageSchedule.isDue(at: now) else { return }
        usageSchedule.recordAttempt(at: now)
        let requestID = UUID()
        usageRequestID = requestID
        isUsageLoading = true
        usageError = nil
        let session = selectedID
        defer { if usageRequestID == requestID { isUsageLoading = false } }
        do {
            // Client cadence already throttles reads. Always bypass the daemon cache
            // here so the two 60-second timers cannot turn into a two-minute cadence.
            var fields: [String: JSONValue] = ["action": .string("usage"), "refresh": .bool(true)]
            if let session { fields["sessionId"] = .string(session) }
            let result: AccountUsage = try await request(fields)
            guard usageRequestID == requestID else { return }
            accountUsage = result
            usageError = result.error
        } catch { if usageRequestID == requestID { usageError = error.localizedDescription } }
    }

    func historyPage(sessionID: String, cursor: String?) async throws -> CodexHistoryPage {
        var fields = ["action": JSONValue.string("historyPage"), "sessionId": .string(sessionID)]
        if let cursor { fields["cursor"] = .string(cursor) }
        return try await request(fields)
    }

    func messageBody(sessionID: String, messageID: String, offset: Int, revision: String?) async throws -> MessageBodyPage {
        var fields: [String: JSONValue] = ["action": .string("messageBody"), "sessionId": .string(sessionID),
            "messageId": .string(messageID), "offset": .number(Double(offset))]
        if let revision { fields["revision"] = .string(revision) }
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
        readingSessionID = nil
        selectedID = identifier
        activateDraft(identifier)
        selected = nil
        UserDefaults.standard.set(identifier, forKey: storageKey + ".selection")
        if supportsCatalog {
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
        var created = false
        await action {
            try self.validateAccessMode()
            var fields: [String: JSONValue] = ["action": .string("create"), "cwd": .string(cwd), "operationId": .string(UUID().uuidString)]
            self.addModelSettings(to: &fields)
            let value: JSONValue = try await self.request(fields)
            guard let id = value["id"].string else { throw ConnectionError.message("服务器没有返回新会话 ID。") }
            await self.select(id)
            created = true
        }
        return created
    }

    private func reconcilePendingSend() async {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else {
            hasUncertainSend = false
            return
        }
        hasUncertainSend = true
        do {
            let pending = try JSONDecoder().decode([String: JSONValue].self, from: data)
            let result: PendingSendStatus = try await request(["action": .string("operationStatus"), "operation": .object(pending)])
            guard result.isResolved else { return }
            showSubmission(pending, state: result.state == "accepted" ? "accepted" : "failed")
            UserDefaults.standard.removeObject(forKey: pendingKey)
            hasUncertainSend = false
            if result.state == "accepted" { removeSentAttachments(pending) }
            if result.state == "accepted" { clearSubmittedDraft(pending) }
        } catch {
            // An unreachable/older bridge cannot prove that it is safe to send again.
        }
    }

    private func activateDraft(_ session: String) {
        let address = DraftAddress(server: storageKey, session: session)
        guard address != draftOwner else { return }
        draftOwner = address
        draftRecord = draftStore.load(address)
        restoringDraft = true
        draft = draftRecord.text
        restoringDraft = false
    }

    func clearSubmittedDraft(_ request: [String: JSONValue]) {
        guard let session = request["sessionId"]?.string,
              draftOwner == DraftAddress(server: storageKey, session: session),
              request["draftRevision"]?.string == draftRecord.revision else { return }
        draft = ""
    }

    var isPreparingAttachment: Bool { isImportingAttachment || isUploadingAttachment }

    func beginAttachmentImport() -> Bool {
        guard !isPreparingAttachment, !isSending, !hasUncertainSend else { return false }
        isImportingAttachment = true
        return true
    }

    func endAttachmentImport() { isImportingAttachment = false }

    var attachments: [UploadedAttachment] { selectedID.flatMap { attachmentDrafts[$0] } ?? [] }

    func removeAttachment(_ id: String) {
        guard let selectedID, !isUploadingAttachment, !hasUncertainSend, !isSending else { return }
        attachmentDrafts[selectedID]?.removeAll { $0.id == id }
        saveAttachments()
    }

    private func removeSentAttachments(_ request: [String: JSONValue]) {
        guard let session = request["sessionId"]?.string else { return }
        let ids = Set(request["attachments"]?.array.compactMap(\.string) ?? [])
        attachmentDrafts[session]?.removeAll { ids.contains($0.id) }
        saveAttachments()
    }

    private func saveAttachments() {
        if let data = try? JSONEncoder().encode(attachmentDrafts) {
            UserDefaults.standard.set(data, forKey: storageKey + ".attachments")
        }
    }

    private func restoreAttachments() {
        if let data = UserDefaults.standard.data(forKey: storageKey + ".attachments"),
           let saved = try? JSONDecoder().decode([String: [UploadedAttachment]].self, from: data) { attachmentDrafts = saved }
    }

    func attachmentFailed(_ message: String) { error = message }

    func attachFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try AttachmentPolicy.validate(size: size, count: attachments.count)
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            await attachData(data, name: url.lastPathComponent)
        } catch { self.error = error.localizedDescription }
    }

    func attachData(_ original: Data, name originalName: String) async {
        guard let session = selectedID, isPrepared, connection.isConnected, supportsAttachments else {
            error = "请先连接并准备支持附件的工作区。"; return
        }
        guard !isUploadingAttachment, !isSending, !hasUncertainSend else { error = "请先完成上一项上传或发送。"; return }
        let server = storageKey
        do {
            try AttachmentPolicy.validate(size: original.count, count: attachments.count)
            let prepared = AttachmentImage.prepare(original, name: originalName)
            let data = prepared.data
            let name = prepared.name
            try AttachmentPolicy.validate(size: data.count, count: attachments.count)
            isUploadingAttachment = true; attachmentProgress = 0; uploadingAttachmentName = name
            defer { isUploadingAttachment = false; uploadingAttachmentName = "" }
            error = nil
            let start: UploadedAttachment = try await request(["action": .string("attachmentBegin"),
                "sessionId": .string(session), "name": .string(name), "size": .number(Double(data.count))])
            guard let path = start.uploadPath else { throw ConnectionError.message("服务器没有返回上传路径。") }
            try await connection.uploadAttachment(data, to: path) { [weak self] value in self?.attachmentProgress = value }
            guard storageKey == server else { throw CancellationError() }
            let ready: UploadedAttachment = try await request(["action": .string("attachmentFinish"),
                "sessionId": .string(session), "id": .string(start.id)])
            attachmentDrafts[session, default: []].append(ready)
            saveAttachments()
        } catch { if storageKey == server { self.error = "附件上传失败：" + error.localizedDescription } }
    }

    var canSubmit: Bool {
        connection.isConnected && isPrepared && !isBusy && !isPreparingAttachment && !hasUncertainSend &&
        selected != nil && selected?.isRunning != true && selected?.readOnly != true &&
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    var pendingSessionID: String? {
        guard let data = UserDefaults.standard.data(forKey: pendingKey),
              let request = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return nil }
        return request["sessionId"]?.string
    }

    func isPendingMessage(_ messageID: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: pendingKey),
              let request = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              let operation = request["operationId"]?.string else { return false }
        return messageID == "local:" + operation && request["sessionId"]?.string == selectedID
    }

    func retryRequest(for messageID: String) -> [String: JSONValue]? {
        guard let submission = localSubmissions.first(where: { $0.id == messageID && $0.sessionID == selectedID }),
              ["failed", "unknown"].contains(submission.state) else { return nil }
        if let request = submission.request { return request }
        // Migrate pending records from versions that did not retain per-message requests.
        guard let data = UserDefaults.standard.data(forKey: pendingKey),
              let request = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              request["operationId"]?.string == submission.operationID else { return nil }
        return request
    }

    func send(retryMessageID: String? = nil) async {
        let sendServer = storageKey
        let retryPending = retryMessageID != nil
        let savedRetry = retryMessageID.flatMap { retryRequest(for: $0) }
        if retryPending, savedRetry == nil { error = "找不到这条消息的重试记录，请刷新会话确认状态。"; return }
        guard let identifier = selectedID else {
            error = "请先选择一个会话。"
            return
        }
        guard !isBusy, !isPreparingAttachment else { error = "请等待当前操作或附件上传完成。"; return }
        guard connection.isConnected, isPrepared else {
            error = "连接或工作区尚未就绪，请重新连接并准备工作区。"
            return
        }
        if selected?.isRunning == true, !retryPending || !isPendingMessage(retryMessageID ?? "") {
            error = "当前任务仍在运行，请等待完成或停止后再发送。"
            return
        }
        if selected?.readOnly == true {
            error = selected?.writerOccupied == true ? "此会话被其他客户端占用，请退出另一端会话后重新检查。" : "这个会话正在 CLI 中运行，请在 CLI 完成任务并刷新后再发送。"
            return
        }
        isSending = true
        defer { isSending = false }
        await action {
            try self.validateAccessMode()
            if !retryPending { await self.reconcilePendingSend() }
            let request: [String: JSONValue]
            if let savedRetry {
                if let data = UserDefaults.standard.data(forKey: self.pendingKey) {
                    let pending = try JSONDecoder().decode([String: JSONValue].self, from: data)
                    guard pending["operationId"]?.string == savedRetry["operationId"]?.string else {
                        throw ConnectionError.message("另一条消息的结果仍待确认，请先在对应消息中处理。")
                    }
                }
                request = savedRetry
                guard request["sessionId"]?.string == identifier else {
                    throw ConnectionError.message("另一会话有待确认的发送，请先切回该会话处理。")
                }
                UserDefaults.standard.set(try JSONEncoder().encode(request), forKey: self.pendingKey)
            } else if UserDefaults.standard.data(forKey: self.pendingKey) != nil {
                throw ConnectionError.message("上一条消息的结果仍待确认，请在对应消息中点击重试。")
            } else {
                guard !self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !self.attachments.isEmpty else { return }
                var fields: [String: JSONValue] = ["action": .string("send"), "sessionId": .string(identifier),
                           "text": .string(self.draft), "draftRevision": .string(self.draftRecord.revision), "operationId": .string(UUID().uuidString)]
                if !self.attachments.isEmpty {
                    fields["attachments"] = .array(self.attachments.map { .string($0.id) })
                    fields["attachmentDetails"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self.attachments))
                    fields["displayText"] = .string(AttachmentPolicy.displayText(self.draft, names: self.attachments.map(\.name)))
                }
                self.addModelSettings(to: &fields)
                request = fields
                UserDefaults.standard.set(try JSONEncoder().encode(request), forKey: self.pendingKey)
            }
            self.hasUncertainSend = true
            self.showSubmission(request, state: "sending")
            if !retryPending { self.clearSubmittedDraft(request) }
            do {
                let _: JSONValue = try await self.request(request)
                self.showSubmission(request, state: "accepted")
                self.removeSentAttachments(request)
            } catch {
                if self.storageKey == sendServer {
                    self.showSubmission(request, state: "unknown")
                    await self.reconcilePendingSend()
                }
                throw error
            }
            UserDefaults.standard.removeObject(forKey: self.pendingKey)
            self.hasUncertainSend = false
            // The saved revision was cleared before sending; never clear newer typing here.
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
        if !isSending { await reconcilePendingSend() }
        let requestedID = selectedID
        var fields = ["action": JSONValue.string("snapshot")]
        if let requestedID { fields["sessionId"] = .string(requestedID) }
        let snapshot: CodexSnapshot = try await request(fields)
        sessions = snapshot.sessions
        for session in sessions {
            completionReads.observe(id: session.id, completedTurnID: session.completedTurnId)
        }
        saveCompletionReads()
        if let projects = snapshot.projects { self.projects = projects }
        else {
            self.projects = Array(Set(sessions.map(\.cwd))).sorted().map { CodexProject(id: $0, title: URL(fileURLWithPath: $0).lastPathComponent) }
        }
        guard selectedID == requestedID else { return }
        if sessions.contains(where: { $0.id == requestedID && $0.archived == true }) { clearSelection(); return }
        selected = snapshot.selected
        acknowledgeVisibleCompletion()
        if let selected {
            let known = Set(selected.messages.map(\.id))
            localSubmissions.removeAll { $0.sessionID == selected.id && known.contains($0.id) && $0.state == "accepted" }
            saveOutbox()
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
        fields["accessMode"] = .string(accessMode.rawValue)
        guard supportsCatalog, !selectedModel.isEmpty else { return }
        fields["model"] = .string(selectedModel)
        if !selectedEffort.isEmpty { fields["effort"] = .string(selectedEffort) }
    }

    private func validateAccessMode() throws {
        if accessMode == .fullAccess, !supportsAccessMode {
            throw ConnectionError.message("当前后台尚未支持 Full Access。请完成现有任务后，点击“重新准备 / 应用后台更新”。")
        }
    }
}
