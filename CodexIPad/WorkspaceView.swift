import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connection = ConnectionModel()
    #if DEBUG
    @State private var showConnections = !ProcessInfo.processInfo.arguments.contains("--preview-workspace")
    #else
    @State private var showConnections = true
    #endif

    var body: some View {
        WorkspaceView(connection: connection, isWorkspaceVisible: !showConnections, onOpenConnections: { showConnections = true })
            .fullScreenCover(isPresented: $showConnections) {
                ConnectionView(model: connection, onOpenWorkspace: { showConnections = false })
                    .interactiveDismissDisabled(!connection.isConnected)
            }
            .task { await connection.maintainConnection() }
            .onChange(of: scenePhase, initial: true) { _, phase in connection.foregroundChanged(phase == .active) }
            .onChange(of: connection.isConnected) { _, connected in
                if connected { showConnections = false }
            }
    }
}

struct WorkspaceView: View {
    @Environment(\.interfaceTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var visibleConversationID: String?
    let isWorkspaceVisible: Bool
    @ObservedObject var connection: ConnectionModel
    @StateObject private var model: WorkspaceModel
    @State private var showProjects = false
    @State private var clearPending = false
    @State private var restartBackend = false
    @State private var expandedProjects: Set<String> = []
    @State private var historySession: CodexSession?
    @State private var showSettings = false
    @State private var showTerminal = false
    @State private var showArchived = false
    @State private var showRename = false
    @State private var renameID = ""
    @State private var renameTitle = ""
    @State private var isDropTargeted = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredColumn: NavigationSplitViewColumn = .detail
    @FocusState private var searchFocused: Bool
    @State private var showUsage = ProcessInfo.processInfo.arguments.contains("--preview-usage")
    let onOpenConnections: () -> Void

    init(connection: ConnectionModel, isWorkspaceVisible: Bool = true, onOpenConnections: @escaping () -> Void = {}) {
        self.isWorkspaceVisible = isWorkspaceVisible
        self.onOpenConnections = onOpenConnections
        self.connection = connection
        _model = StateObject(wrappedValue: WorkspaceModel(connection: connection))
    }

    private var companionState: CompanionState {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-workspace"),
           let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--companion-state=") }),
           let state = CompanionState(rawValue: String(value.dropFirst("--companion-state=".count))) { return state }
        #endif
        return CompanionState.resolve(connected: connection.isConnected, status: model.selected?.status,
            messages: model.selected.map { model.messages(for: $0) } ?? [], sending: model.isSending,
            uncertain: model.hasUncertainSend, hasApprovals: model.selected?.approvals.isEmpty == false)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredColumn) {
            List {
                Section {
                    Button { showProjects = true } label: {
                        Label("新建聊天", systemImage: "square.and.pencil")
                    }.keyboardShortcut("n", modifiers: .command).tint(theme.isCompanion ? theme.accent : .primary).disabled(model.isBusy || !model.isPrepared)
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索聊天", text: $model.search).textInputAutocapitalization(.never).focused($searchFocused)
                    }
                }
                Section {
                    ForEach(model.visibleProjects) { project in
                        DisclosureGroup(isExpanded: Binding(get: { expandedProjects.contains(project.id) }, set: {
                            if $0 { expandedProjects.insert(project.id) } else { expandedProjects.remove(project.id) }
                        })) {
                            ForEach(model.sessions(in: project)) { session in
                                Button { Task { await model.select(session.id) } } label: {
                                    HStack(spacing: 8) {
                                        if ["inProgress", "starting", "waiting"].contains(session.status) {
                                            Circle().fill(session.status == "waiting" ? Color.orange : Color.green).frame(width: 6, height: 6)
                                        }
                                        if session.pinned == true { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                                        Text(session.title).lineLimit(1).font(.subheadline)
                                            .fontWeight(model.isUnread(session.id) ? .semibold : .regular)
                                        Spacer(minLength: 0)
                                        if model.isUnread(session.id) {
                                            Circle().fill(theme.accent).frame(width: 8, height: 8)
                                                .accessibilityLabel("回答完成，未读")
                                        }
                                    }.padding(.vertical, 4).padding(.horizontal, 6)
                                        .background(session.id == model.selectedID ? theme.selection : .clear,
                                                    in: RoundedRectangle(cornerRadius: 8))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(!model.isPrepared || model.isBusy || model.isPreparingAttachment)
                                    .contextMenu { sessionActions(session) }
                            }
                        } label: {
                            HStack {
                                Label(project.title, systemImage: "folder").font(.subheadline)
                                let count = model.unreadSessions.filter { $0.cwd == project.id }.count
                                if count > 0 {
                                    Text("\(count)").font(.caption2.bold()).foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 2).background(theme.actionFill, in: Capsule())
                                        .accessibilityLabel("\(count) 个已完成的未读对话")
                                }
                            }
                        }.contextMenu {
                            Button("新建聊天", systemImage: "square.and.pencil") { Task { _ = await model.create(cwd: project.id) } }
                                .disabled(!model.isPrepared || model.isBusy)
                            Text(project.id)
                        }
                    }
                } header: {
                    HStack {
                        Text("项目")
                        Spacer()
                        Button { showProjects = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("添加项目").disabled(!model.isPrepared || model.isBusy)
                    }
                }
            }.listStyle(.sidebar)
                .scrollContentBackground(theme.isCompanion ? .hidden : .visible)
                .background(theme.sidebar.ignoresSafeArea())
                .navigationTitle("")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text("Code Pax").font(.headline)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 10) {
                        Button(action: onOpenConnections) {
                            HStack(spacing: 8) {
                                Circle().fill(connection.isConnected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                                Text(connection.profile.displayName).lineLimit(1).font(.subheadline)
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button { showSettings = true } label: {
                            Image(systemName: "slider.horizontal.3").frame(width: 30, height: 32)
                        }.tint(.primary).accessibilityLabel("工作区设置")
                    }.padding(.horizontal, 20).padding(.vertical, 10).background(theme.chrome)
                }
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if !connection.isConnected {
                    HStack(spacing: 8) {
                        if connection.willReconnect { ProgressView().controlSize(.small) }
                        Text(connection.status).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if connection.willReconnect {
                            Button("取消重连") { Task { await connection.disconnect() } }.font(.caption)
                        } else { Button("连接", action: onOpenConnections).font(.caption) }
                    }.padding(.horizontal, 18).padding(.vertical, 8).background(theme.chrome)
                }
                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                        .textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.06))
                }
                if let session = model.selected {
                    conversation(session).id(session.id)
                        .onAppear { visibleConversationID = session.id }
                        .onDisappear { if visibleConversationID == session.id { visibleConversationID = nil } }
                } else {
                    ContentUnavailableView("开始一个项目会话", systemImage: "bubble.left.and.bubble.right",
                        description: Text(connection.isConnected ? "连接后自动读取服务器历史。在侧栏选择已有对话，或添加项目新建会话。" : "先在“连接”页面登录服务器。"))
                }
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(model.selected?.title ?? "工作区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showTerminal = true } label: { Image(systemName: "terminal") }
                        .accessibilityLabel("打开终端").keyboardShortcut("t", modifiers: [.command, .shift])
                        .disabled(!connection.isConnected)
                }
                if !model.unreadSessions.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ForEach(model.unreadSessions) { session in
                                Button(session.title) { Task { await model.select(session.id) } }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "bubble.left.fill")
                                Text("\(model.unreadSessions.count)")
                            }.font(.subheadline.bold())
                        }.tint(.blue).accessibilityLabel("\(model.unreadSessions.count) 个已完成的未读对话")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("刷新会话", systemImage: "arrow.clockwise") { Task { await model.reloadCurrent() } }
                            .disabled(!model.isPrepared)
                        if let selected = model.selected {
                            Button("会话历史", systemImage: "clock") { historySession = selected }
                            Text(selected.cwd)
                        }
                        if let session = model.sessions.first(where: { $0.id == model.selectedID }) {
                            sessionActions(session)
                            Divider()
                        }
                        Button("已归档聊天", systemImage: "archivebox") { showArchived = true }
                        Button("设置", systemImage: "slider.horizontal.3") { showSettings = true }
                        Button("Usage", systemImage: "chart.pie") { showUsage = true }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
        }
        .onChange(of: readingSessionID, initial: true) { _, id in model.setReadingSession(id) }
        .onDisappear { model.setReadingSession(nil) }
        .background {
            Button("搜索聊天") { columnVisibility = .all; preferredColumn = .sidebar; searchFocused = true }.keyboardShortcut("k", modifiers: .command).hidden()
        }
        .alert("重命名聊天", isPresented: $showRename) {
            TextField("聊天名称", text: $renameTitle)
            Button("取消", role: .cancel) {}
            Button("保存") { let id = renameID; let title = renameTitle; Task { _ = await model.updateSession(id, title: title) } }
                .disabled(!model.isPrepared || model.isBusy || renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .sheet(isPresented: $showArchived) { ArchivedChatsView(model: model).appAppearance() }
        .sheet(isPresented: $showProjects) { ProjectPicker(model: model).appAppearance() }
        .sheet(isPresented: $showSettings) { workspaceSettings }
        .fullScreenCover(isPresented: $showTerminal) {
            RemoteTerminalScreen(model: connection.terminal, connection: connection, workingDirectory: model.selected?.cwd)
                .appAppearance()
        }
        .sheet(isPresented: $showUsage) { UsageView(model: model) }
        .sheet(item: $historySession) { session in HistoryBrowser(model: model, sessionID: session.id).appAppearance() }
        .onAppear { if let path = model.selected?.cwd { expandedProjects.insert(path) } }
        .onChange(of: model.selected?.cwd) { _, path in if let path { expandedProjects.insert(path) } }
        .onChange(of: model.projects.map(\.id)) { old, new in
            expandedProjects.formUnion(Set(new).subtracting(old))
        }
        .task(id: connection.profile.credentialAccount + "|" + String(connection.isConnected)) {
            model.connectionChanged()
            if connection.isConnected {
                let workspace = model
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await workspace.pollUsage() }
                    await workspace.prepare()
                    group.addTask { await workspace.poll() }
                    await group.waitForAll()
                }
            }
        }
        .confirmationDialog("清除本机待确认的发送记录？", isPresented: $clearPending, titleVisibility: .visible) {
            Button("已核实服务器状态，清除重试记录", role: .destructive) { model.discardPending() }
        } message: {
            Text("这不会停止服务器上的任务。清除后再次发送相同任务可能重复执行，请先刷新并检查会话。")
        }
        .confirmationDialog("重启 Codex 后台？", isPresented: $restartBackend, titleVisibility: .visible) {
            Button("重启后台并应用代理设置") { Task { await model.restart() } }
        } message: {
            Text("会保留历史会话。如果仍有运行中或待审批的任务，服务器会拒绝重启。代理设置在新的后台进程启动时生效。")
        }
    }

    @ViewBuilder
    private func sessionActions(_ session: CodexSessionSummary) -> some View {
        Button("重命名", systemImage: "pencil") { renameID = session.id; renameTitle = session.title; showRename = true }
            .disabled(!model.isPrepared || !model.supportsSessionManagement || model.isBusy)
        Button(session.pinned == true ? "取消置顶" : "置顶", systemImage: session.pinned == true ? "pin.slash" : "pin") {
            Task { _ = await model.updateSession(session.id, pinned: session.pinned != true) }
        }.disabled(!model.isPrepared || !model.supportsSessionManagement || model.isBusy)
        Button("归档聊天", systemImage: "archivebox") { Task { _ = await model.updateSession(session.id, archived: true) } }
            .disabled(!model.isPrepared || !model.supportsSessionManagement || model.isBusy || ["inProgress", "starting", "waiting", "externalActive", "unknown"].contains(session.status))
    }

    private var readingSessionID: String? {
        guard scenePhase == .active, isWorkspaceVisible, !showProjects, !showSettings,
              !showUsage, !showArchived, !showRename, historySession == nil else { return nil }
        return visibleConversationID
    }

    private var workspaceSettings: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    SkinPicker()
                    PalettePicker()
                    AppearancePicker()
                    NavigationLink { AppearanceCustomizationView() } label: { Label("配色与自定义头像", systemImage: "paintpalette") }
                    Text("两套皮肤都支持浅色、深色和跟随系统。").font(.caption).foregroundStyle(.secondary)
                }
                Section("服务器") {
                    Label(connection.profile.displayName, systemImage: "server.rack")
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                    Button("管理连接") { showSettings = false; onOpenConnections() }
                }
                Section("工作区") {
                    Button("同步历史") { Task { await model.syncHistory(reset: true) } }
                        .disabled(!model.supportsCatalog || model.isBusy)
                    Button("刷新模型列表") { Task { await model.loadModels() } }
                        .disabled(!model.supportsCatalog || model.isBusy)
                    Button("重新准备 / 应用更新") { Task { await model.prepare() } }
                        .disabled(!connection.isConnected || model.isBusy)
                }
                Section("网络与后台") {
                    TextField("HTTP 代理（可选）", text: $model.proxyURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .disabled(model.isBusy)
                    Button("重启后台并应用代理") { showSettings = false; restartBackend = true }
                        .disabled(!connection.isConnected || model.isBusy)
                }
            }.navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } } }
        }.appAppearance().presentationDetents([.medium, .large])
    }

    private func conversation(_ session: CodexSession) -> some View {
        let messages = theme.isCompanion ? CompanionReplyPolicy.displayedMessages(model.messages(for: session), state: companionState) : model.messages(for: session)
        let latestReplyID = CompanionReplyPolicy.latestReplyID(in: messages)
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if session.historyTruncated {
                        Text("当前显示最近 40 条消息，更早记录保留在服务器。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(ConversationEntry.group(messages)) { entry in
                        ConversationRow(entry: entry, model: model, sessionID: session.id,
                            avatarState: entry.id == latestReplyID ? companionState : nil)
                    }
                    if let error = session.error, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                    }
                    ForEach(session.approvals) { approval in
                        ApprovalCard(approval: approval, disabled: model.isBusy || !model.isPrepared) { decision, answers in
                            Task { await model.answer(approval, decision: decision, answers: answers) }
                        }
                    }
                    if !session.diff.isEmpty {
                        DisclosureGroup("当前任务的代码差异") {
                            DiffView(text: session.diff)
                            if let length = session.diffLength, session.diffTruncated == true {
                                FullMessageButton(model: model, sessionID: session.id, messageID: "__diff__", length: length, plainText: true)
                            }
                        }
                            .padding().background(Color.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if session.status == "completed", !model.hasUncertainSend, !model.isSending {
                        Label("回答完成", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium)).foregroundStyle(.green).padding(.top, 4)
                    }
                    if model.messages(for: session).isEmpty {
                        Text("在下面输入任务，Codex 会直接在这个项目中工作。")
                            .foregroundStyle(.secondary).padding(.vertical)
                    }
                }.padding(20).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
            }.defaultScrollAnchor(.bottom)
            Divider()
            composer(session)
        }
    }

    private func composer(_ session: CodexSession) -> some View {
        let control = ComposerState.resolve(status: session.status, draft: model.draft.isEmpty && !model.attachments.isEmpty ? "附件" : model.draft, sending: model.isSending, pending: model.hasUncertainSend)
        return VStack(alignment: .leading, spacing: 10) {
            if model.hasUncertainSend {
                Text("上一条消息的发送结果待确认。你可以继续编辑草稿；确认上一条结果后即可发送新消息。重试只会处理之前保存的消息。")
                    .font(.caption).foregroundStyle(.orange)
                Button("重试上一条消息") { Task { await model.send(retryPending: true) } }
                    .disabled(model.isBusy || !model.isPrepared || session.readOnly == true)
                Button("已检查会话，清除本机重试记录") { clearPending = true }.font(.caption)
            }
            if session.readOnly == true {
                Text("这个会话正在 CLI 中运行，目前仅供查看。请在 CLI 结束任务后刷新，再继续对话。")
                    .font(.caption).foregroundStyle(.orange)
            }
            AttachmentTray(model: model)
            HStack(alignment: .bottom, spacing: 8) {
                ComposerTextInput(text: $model.draft, canSubmit: model.canSubmit, canAttach: model.canAddAttachments, receiveAttachments: { model.attachProviders($0) }) {
                    Task { await model.send() }
                }
                    .overlay(alignment: .topLeading) {
                        if model.draft.isEmpty {
                            Text("给 Codex 一个任务…").foregroundStyle(.tertiary)
                                .allowsHitTesting(false)
                        }
                    }.padding(12)
                    .background(theme.input, in: RoundedRectangle(cornerRadius: 14))
            }
            if model.isBusy && !model.isSending {
                ProgressView("正在处理请求…").font(.caption)
            }
            HStack(spacing: 10) {
                AttachmentPickerButton(model: model)
                modelControls
                Spacer(minLength: 0)
                if control == .completed {
                    HStack(spacing: 6) {
                        Text("已完成").font(.caption.weight(.medium))
                        Image(systemName: "checkmark").fontWeight(.semibold).frame(width: 44, height: 44)
                            .background(Color.green.opacity(0.14), in: Circle())
                    }.foregroundStyle(.green).accessibilityLabel("回答已完成，输入新消息即可继续")
                } else {
                    ComposerActionButton(state: control,
                        disabled: session.isRunning ? (!connection.isConnected || !model.isPrepared || model.isBusy) : !model.canSubmit) {
                        Task { if control == .running { await model.stop() } else { await model.send() } }
                    }
                }
            }
            if session.accessMode != model.accessMode.rawValue {
                Text("下次任务使用：" + model.accessMode.title).font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(14)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(isDropTargeted ? theme.accent : theme.border, lineWidth: isDropTargeted ? 2 : 1))
            .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
                guard model.canAddAttachments else { return false }
                model.attachProviders(providers); return true
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .animation(.easeInOut(duration: 0.2), value: control)
    }

    private var modelControls: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("模型", selection: Binding(get: { model.selectedModel }, set: {
                    model.selectedModel = $0; model.modelChanged()
                })) {
                    Text("沿用会话 / 默认模型").tag("")
                    if !model.selectedModel.isEmpty && !model.models.contains(where: { $0.model == model.selectedModel }) {
                        Text(model.selectedModel).tag(model.selectedModel)
                    }
                    ForEach(model.models) { Text($0.displayName).tag($0.model) }
                }
                if let chosen = model.chosenModel {
                    Picker("推理强度", selection: $model.selectedEffort) {
                        Text("默认推理强度").tag("")
                        ForEach(chosen.supportedReasoningEfforts) { Text($0.reasoningEffort).tag($0.reasoningEffort) }
                    }
                }
                Button("刷新模型") { Task { await model.loadModels() } }
            } label: {
                HStack(spacing: 4) {
                    Text(model.chosenModel?.displayName ?? (model.selectedModel.isEmpty ? "默认模型" : model.selectedModel))
                        .lineLimit(1)
                    if !model.selectedEffort.isEmpty { Text(model.selectedEffort).foregroundStyle(.secondary) }
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }.disabled(!model.supportsCatalog || model.isBusy)
            Menu {
                Picker("下次任务的权限", selection: Binding(get: { model.accessMode }, set: {
                    model.accessMode = $0; model.accessModeChanged()
                })) {
                    ForEach(AccessMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                }
                Text("Full Access：允许访问服务器文件和网络，无需逐项审批。切换从下一次任务生效。")
            } label: {
                ViewThatFits(in: .horizontal) {
                    Label(model.accessMode.title, systemImage: model.accessMode.symbol).fixedSize()
                    Image(systemName: model.accessMode.symbol)
                }.accessibilityLabel(model.accessMode.title)
            }.disabled(model.isBusy || !model.supportsAccessMode)
            Button { showUsage = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chart.pie").foregroundStyle(usageIconColor)
                    Text("Usage")
                }.lineLimit(1)
            }.accessibilityLabel("查看 token 用量与账号额度")
        }.font(.caption).tint(.primary)
    }

    private var usageIconColor: Color {
        switch model.accountUsage?.severity {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        case nil: return .secondary
        }
    }

}

private struct ProjectPicker: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var manualPath = ""

    var body: some View {
        NavigationStack {
            List {
                if let listing = model.listing {
                    Section("当前目录") {
                        Text(listing.path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Button("在这个目录新建会话") {
                            Task { if await model.create(cwd: listing.path) { dismiss() } }
                        }.disabled(model.isBusy)
                        if model.supportsCatalog {
                            Button("仅添加这个项目") {
                                Task { if await model.addProject(cwd: listing.path) { dismiss() } }
                            }.disabled(model.isBusy)
                        }
                        if let parent = listing.parent {
                            Button("返回上级目录") { Task { await model.browse(parent) } }
                        }
                    }
                    Section("子目录") {
                        ForEach(listing.directories) { directory in
                            Button { Task { await model.browse(directory.id) } } label: {
                                Label(directory.name, systemImage: "folder")
                            }
                        }
                    }
                }
                Section("直接输入目录") {
                    TextField("服务器上的绝对路径", text: $manualPath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("打开目录") { Task { await model.browse(manualPath) } }
                        .disabled(manualPath.isEmpty || model.isBusy)
                    Text("默认只允许当前 SSH 用户的 Home 目录及其子目录。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("选择项目")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

private struct HistoryBrowser: View {
    @ObservedObject var model: WorkspaceModel
    let sessionID: String
    @Environment(\.dismiss) private var dismiss
    @State private var pages: [CodexHistoryPage] = []
    @State private var index = 0
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let error { Text(error).foregroundStyle(.red) }
                    if loading { ProgressView("读取历史…") }
                    if pages.indices.contains(index) {
                        HStack {
                            Button("较新一页") { index -= 1 }.disabled(index == 0 || loading)
                            Spacer()
                            Text("第 \(index + 1) 页").font(.caption)
                            Spacer()
                            Button("更早一页") {
                                if index + 1 < pages.count { index += 1 }
                                else if let cursor = pages[index].nextCursor { Task { await load(cursor) } }
                            }.disabled(loading || (index + 1 == pages.count && pages[index].nextCursor == nil))
                        }
                        ForEach(ConversationEntry.group(pages[index].messages)) { entry in ConversationRow(entry: entry, model: model, sessionID: sessionID) }
                    }
                }.padding()
            }
            .navigationTitle("会话历史")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.task { await load(nil) }
    }

    private func load(_ cursor: String?) async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let page = try await model.historyPage(sessionID: sessionID, cursor: cursor)
            pages.append(page); index = pages.count - 1
        } catch { self.error = error.localizedDescription }
    }
}

private struct ConversationRow: View {
    @Environment(\.interfaceTheme) private var theme
    let entry: ConversationEntry
    @ObservedObject var model: WorkspaceModel
    let sessionID: String
    var avatarState: CompanionState? = nil
    var body: some View {
        if entry.isActivity { ActivityGroup(entry: entry, model: model, sessionID: sessionID) }
        else if let message = entry.messages.first { VStack(alignment: .leading, spacing: 12) {
                if theme.isCompanion && message.kind != "userMessage" {
                    HStack(spacing: 8) {
                        if let avatarState {
                            CompanionAvatar(state: avatarState).frame(width: 72, height: 72)
                        } else { BrandMark().frame(width: 56, height: 56) }
                        Text("Codex").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                if !message.text.isEmpty || message.kind == "userMessage" {
                    MessageCard(message: message, model: model, sessionID: sessionID)
                }
                if message.textTruncated == true {
                    FullMessageButton(model: model, sessionID: sessionID, messageID: message.id,
                                      length: message.contentLength ?? message.text.count, plainText: message.kind == "userMessage")
                }
            }.padding(theme.isCompanion && message.kind != "userMessage" ? 18 : 0)
                .background(theme.isCompanion && message.kind != "userMessage" ? theme.card : .clear,
                            in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.isCompanion && message.kind != "userMessage" ? theme.border : .clear, lineWidth: 1))
                .modifier(RemoteFileLinks(model: model, sessionID: sessionID)) }
    }
}

private struct ActivityGroup: View {
    let entry: ConversationEntry
    @ObservedObject var model: WorkspaceModel
    let sessionID: String
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(entry.messages) { message in
                    DisclosureGroup {
                        ScrollView([.horizontal, .vertical]) {
                            Text(message.text).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 240)
                        if message.textTruncated == true {
                            FullMessageButton(model: model, sessionID: sessionID, messageID: message.id,
                                              length: message.contentLength ?? message.text.count, plainText: true)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: message.kind == "commandExecution" ? "terminal" : "doc.text")
                            Text(message.activityTitle).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if message.status == "failed" { Image(systemName: "exclamationmark.circle").foregroundStyle(.red) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(.leading, 4).padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                if entry.isRunning { ProgressView().controlSize(.mini) }
                else { Image(systemName: entry.messages.contains(where: { $0.status == "failed" }) ? "exclamationmark.circle" : "checkmark.circle") }
                Text(entry.summary).lineLimit(1)
            }.font(.subheadline).foregroundStyle(.secondary)
        }.tint(.secondary).padding(.vertical, 4)
    }
}

private struct MessageCard: View {
    @Environment(\.interfaceTheme) private var theme
    let message: CodexMessage
    @ObservedObject var model: WorkspaceModel
    let sessionID: String
    private var deliveryColor: Color {
        switch message.status {
        case "sending", "unknown": return .orange
        case "failed": return .red
        default: return .secondary
        }
    }
    private var deliveryLabel: String {
        switch message.status {
        case "sending": return "发送中"
        case "unknown": return "待确认"
        case "failed": return "未送达"
        default: return "已送达"
        }
    }
    var body: some View {
        if message.kind == "userMessage" {
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 5) {
                    if let attachments = message.attachments, !attachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(attachments) { attachment in
                                    AttachmentPreviewButton(model: model, sessionID: sessionID, attachment: attachment)
                                        .padding(10).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }.frame(maxWidth: 400).defaultScrollAnchor(.trailing)
                    }
                    if !message.userMessageText.isEmpty {
                    Text(message.userMessageText).textSelection(.enabled)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(message.status == "sending" || message.status == "unknown" || message.status == "failed"
                                    ? deliveryColor.opacity(0.13) : theme.userBubble,
                                    in: RoundedRectangle(cornerRadius: 20))
                    }
                    Label(deliveryLabel, systemImage: message.status == "sending" ? "clock" :
                            message.status == "unknown" || message.status == "failed" ? "exclamationmark.circle" : "checkmark")
                        .font(.caption2).foregroundStyle(deliveryColor).padding(.trailing, 8)
                }
            }
        } else if message.kind == "plan" {
            DisclosureGroup("执行计划") {
                RichMarkdown(text: message.text).equatable().padding(.top, 8)
            }.tint(.secondary)
        } else {
            RichMarkdown(text: message.text).equatable().padding(.vertical, 4)
        }
    }
}

private struct ApprovalCard: View {
    let approval: CodexApproval
    let disabled: Bool
    let respond: (String?, [String: String]) -> Void
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(approval.isQuestion ? "Codex 需要你的回答" : "需要你的审批", systemImage: "hand.raised")
                .font(.headline)
            if let reason = approval.params["reason"].string { Text(reason) }
            if let cwd = approval.params["cwd"].string { Text(cwd).font(.caption).foregroundStyle(.secondary) }
            if let command = approval.params["command"].string {
                DisclosureGroup {
                    Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                } label: {
                    Label(command.components(separatedBy: .newlines).first ?? "查看命令", systemImage: "terminal")
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                }
            }
            if approval.isQuestion {
                ForEach(Array(approval.questions.enumerated()), id: \.offset) { _, question in
                    let key = question["id"].string ?? ""
                    Text(question["question"].string ?? question["header"].string ?? "问题")
                    ForEach(Array(question["options"].array.enumerated()), id: \.offset) { _, option in
                        if let label = option["label"].string {
                            Button(label) { answers[key] = label }.buttonStyle(.bordered)
                            if let description = option["description"].string {
                                Text(description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if question["isSecret"].boolean {
                        SecureField("输入回答", text: Binding(get: { answers[key] ?? "" }, set: { answers[key] = $0 }))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        TextField("输入回答", text: Binding(get: { answers[key] ?? "" }, set: { answers[key] = $0 }), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Button("提交回答") { respond(nil, answers) }.buttonStyle(.borderedProminent)
                    .disabled(approval.questions.contains { (answers[$0["id"].string ?? ""] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            } else if approval.isPermission {
                Text("当前版本不支持授予额外权限。可以拒绝请求，或停止当前任务。")
                Button("拒绝额外权限", role: .destructive) { respond("decline", [:]) }.buttonStyle(.bordered)
            } else {
                HStack {
                    if approval.decisions.contains("accept") {
                        Button("允许这一次") { respond("accept", [:]) }.buttonStyle(.borderedProminent)
                    }
                    if approval.decisions.contains("decline") {
                        Button("拒绝", role: .destructive) { respond("decline", [:]) }.buttonStyle(.bordered)
                    }
                    if approval.decisions.contains("cancel") {
                        Button("取消") { respond("cancel", [:]) }.buttonStyle(.bordered)
                    }
                }
            }
            DisclosureGroup("完整请求详情") {
                Text(approval.params.pretty).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
        .disabled(disabled).padding(18)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct DiffView: View {
    let text: String
    var body: some View {
        ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(line.hasPrefix("+") ? Color.green : line.hasPrefix("-") ? Color.red : Color.primary)
                }
            }.textSelection(.enabled).padding(.top, 10)
        }
    }
}
