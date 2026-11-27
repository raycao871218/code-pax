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
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--preview-landscape") {
                    try? await Task.sleep(for: .milliseconds(600))
                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
                    }
                }
                #endif
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                connection.foregroundChanged(phase == .active, workspaceVisible: !showConnections)
            }
            .onChange(of: showConnections, initial: true) { _, showingHome in
                connection.foregroundChanged(scenePhase == .active, workspaceVisible: !showingHome)
            }
            .onChange(of: connection.isConnected) { _, connected in
                if connected { showConnections = false }
            }
    }
}

struct WorkspaceView: View {
    @Environment(\.interfaceTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var visibleConversationID: String?
    let isWorkspaceVisible: Bool
    @ObservedObject var connection: ConnectionModel
    @StateObject private var model: WorkspaceModel
    @State private var showAgents = ProcessInfo.processInfo.arguments.contains("--preview-agents")
    @State private var showSearch = false
    @State private var projectTerminal = false
    @State private var showAddProject = false
    @State private var clearPendingCreate = false
    @State private var restartBackend = false
    @State private var expandedProjects: Set<String> = []
    @State private var historySession: CodexSession?
    @State private var showSettings = false
    @State private var showTerminal = false
    @State private var showCollaboration = false
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
                    Button { showSearch = true; showAgents = false; searchFocused = true } label: {
                        Label("搜索会话", systemImage: "magnifyingglass")
                    }
                    Button { showAgents = true; preferredColumn = .detail } label: {
                        Label("Agents", systemImage: "chevron.left.forwardslash.chevron.right")
                    }.listRowBackground(RoundedRectangle(cornerRadius: 8).fill(showAgents ? theme.selection : .clear))
                        .accessibilityIdentifier("workspace.agents")
                    Button { showCollaboration = true } label: { Label("协作", systemImage: "person.2") }
                }.tint(.primary)
                if showSearch || !model.search.isEmpty {
                    Section {
                        TextField("搜索会话", text: $model.search).textInputAutocapitalization(.never).focused($searchFocused)
                    }
                }
                Section {
                    ForEach(model.visibleProjects) { project in
                        DisclosureGroup(isExpanded: Binding(get: { expandedProjects.contains(project.id) }, set: {
                            if $0 { expandedProjects.insert(project.id) } else { expandedProjects.remove(project.id) }
                        })) {
                            if model.draftProject == project.id { draftRow }
                            ForEach(model.sessions(in: project)) { session in
                                Button { showAgents = false; Task { await model.select(session.id) } } label: {
                                    HStack(spacing: 8) {
                                        if ["inProgress", "starting", "waiting"].contains(session.status) {
                                            Circle().fill(session.status == "waiting" ? Color.orange : Color.green).frame(width: 6, height: 6)
                                        }
                                        if session.pinned == true { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(session.title).lineLimit(1).font(.subheadline)
                                                .fontWeight(model.isUnread(session.id) ? .semibold : .regular)

                                        }
                                        Spacer(minLength: 0)
                                        if model.isUnread(session.id) {
                                            Circle().fill(theme.accent).frame(width: 8, height: 8)
                                                .accessibilityLabel("回答完成，未读")
                                        }
                                    }.padding(.vertical, 4).padding(.horizontal, 6)
                                        .background(session.id == model.selectedID && !showAgents ? theme.selection : .clear,
                                                    in: RoundedRectangle(cornerRadius: 8))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(!model.isPrepared || model.isBusy || model.isPreparingAttachment)
                                    .contextMenu { sessionActions(session) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Label(project.title, systemImage: "folder").font(.subheadline).lineLimit(1)
                                let count = model.unreadSessions.filter { $0.cwd == project.id }.count
                                if count > 0 {
                                    Text("\(count)").font(.caption2.bold()).foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 2).background(theme.actionFill, in: Capsule())
                                        .accessibilityLabel("\(count) 个已完成的未读对话")
                                }
                                Spacer(minLength: 4)
                                Button { newSession(in: project.id) } label: {
                                    Image(systemName: "square.and.pencil").font(.footnote)
                                        .frame(width: 28, height: 28).contentShape(Rectangle())
                                }.buttonStyle(.borderless).foregroundStyle(.secondary)
                                    .accessibilityLabel("在此项目新建会话")
                                    .disabled(!model.isPrepared || model.isBusy)
                            }
                        }.contextMenu { projectActions(project) }
                    }
                } header: {
                    HStack {
                        Text("项目")
                        Spacer()
                        Button { showAddProject = true } label: { Image(systemName: "folder.badge.plus") }
                            .accessibilityLabel("添加项目").disabled(!model.isPrepared || model.isBusy)
                    }
                }
            }.listStyle(.sidebar)
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(removing: .sidebarToggle)
                .scrollContentBackground(theme.isCompanion ? .hidden : .visible)
                .background(theme.sidebar.ignoresSafeArea())
                .safeAreaInset(edge: .top) {
                    HStack {
                        Text("Code Pax").font(.title3.weight(.semibold))
                        Spacer()
                        Button { newSession() } label: {
                            Image(systemName: "square.and.pencil").frame(width: 36, height: 36)
                        }.accessibilityLabel("新建会话").keyboardShortcut("n", modifiers: .command)
                            .disabled(model.isBusy || !model.isPrepared)
                    }.tint(.primary).padding(.horizontal, 20).padding(.vertical, 14)
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
                        Menu {
                            Button("服务器终端", systemImage: "terminal") { showTerminal = true }
                                .disabled(!connection.isConnected)
                            Button("用量与额度", systemImage: "chart.pie") { showUsage = true }
                            Button("已归档会话", systemImage: "archivebox") { showArchived = true }
                            Divider()
                            Button("设置", systemImage: "gearshape") { showSettings = true }
                        } label: {
                            Image(systemName: "gearshape").frame(width: 36, height: 36)
                                .overlay(alignment: .topTrailing) {
                                    if let severity = model.accountUsage?.severity, severity != .normal {
                                        Circle().fill(usageIconColor).frame(width: 6, height: 6)
                                    }
                                }
                        }.tint(.primary).accessibilityLabel("工具与设置")
                    }.padding(.horizontal, 20).padding(.vertical, 10).background(theme.chrome)
                }
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            VStack(spacing: 0) {
                workspaceHeader
                Divider()
                if !connection.isConnected {
                    HStack(spacing: 8) {
                        if connection.willReconnect { ProgressView().controlSize(.small) }
                        AppText(connection.status).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if connection.willReconnect {
                            Button("取消重连") { Task { await connection.disconnect() } }.font(.caption)
                        } else { Button("连接", action: onOpenConnections).font(.caption) }
                    }.padding(.horizontal, 18).padding(.vertical, 8).background(theme.chrome)
                }
                if let error = model.error {
                    AppText(error).font(.callout).foregroundStyle(.red)
                        .textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.06))
                }
                if projectTerminal && !showAgents {
                    RemoteTerminalScreen(model: connection.terminal, connection: connection,
                        workingDirectory: model.selected?.cwd ?? model.draftProject, embedded: true)
                } else if showAgents {
                    AgentLibraryView(model: model, openTerminal: { showTerminal = true }, startSession: { newSession() })
                } else if let session = model.selected {
                    conversation(session).id(session.id)
                        .onAppear { visibleConversationID = session.id }
                        .onDisappear { if visibleConversationID == session.id { visibleConversationID = nil } }
                } else if let project = model.draftProject {
                    draftView(project)
                } else {
                    ContentUnavailableView {
                        Label("开始一个项目会话", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text(LocalizedStringKey(connection.isConnected ? "连接后自动读取服务器历史。在侧栏选择已有对话，或添加项目新建会话。" : "先在“连接”页面登录服务器。"))
                    } actions: {
                        if connection.isConnected {
                            Button("新建会话") { newSession() }.buttonStyle(.borderedProminent)
                                .disabled(!model.isPrepared || model.isBusy)
                            Button("添加项目") { showAddProject = true }
                                .disabled(!model.isPrepared || model.isBusy)
                        }
                    }
                }
            }
            .background(theme.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewStyle(.balanced)
        .onChange(of: model.selectedID) { _, _ in projectTerminal = false }
        .onChange(of: showAgents) { _, _ in projectTerminal = false }
        .onChange(of: readingSessionID, initial: true) { _, id in model.setReadingSession(id) }
        .onDisappear { model.setReadingSession(nil) }
        .background {
            Button("打开项目终端") { showTerminal = true }.keyboardShortcut("t", modifiers: [.command, .shift]).hidden()
            Button("搜索聊天") { showSearch = true; showAgents = false; columnVisibility = .all; preferredColumn = .sidebar; searchFocused = true }.keyboardShortcut("k", modifiers: .command).hidden()
            Button("添加项目") { showAddProject = true }.keyboardShortcut("n", modifiers: [.command, .shift]).hidden()
        }
        .alert("重命名聊天", isPresented: $showRename) {
            TextField("聊天名称", text: $renameTitle)
            Button("取消", role: .cancel) {}
            Button("保存") { let id = renameID; let title = renameTitle; Task { _ = await model.updateSession(id, title: title) } }
                .disabled(!model.isPrepared || model.isBusy || renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .sheet(isPresented: $showArchived) { ArchivedChatsView(model: model).appAppearance() }
        .sheet(isPresented: $showAddProject) {
            AddProjectSheet(model: model, didChoose: { newSession(in: $0) }).appAppearance()
        }
        .sheet(isPresented: $showCollaboration) {
            CollaborationView(workspace: model) { identifier in
                showCollaboration = false
                showAgents = false
                Task { await model.select(identifier) }
            }.id(connection.profile.credentialAccount).appAppearance()
        }
        .sheet(isPresented: $showSettings) { workspaceSettings }
        .fullScreenCover(isPresented: $showTerminal) {
            RemoteTerminalScreen(model: connection.terminal, connection: connection, workingDirectory: model.selected?.cwd ?? model.draftProject)
                .appAppearance()
        }
        .sheet(isPresented: $showUsage) { UsageView(model: model) }
        .sheet(item: $historySession) { session in HistoryBrowser(model: model, sessionID: session.id).appAppearance() }
        .onAppear { if let path = selectedProjectID { expandedProjects.insert(path) } }
        .onChange(of: selectedProjectID) { _, path in if let path { expandedProjects.insert(path) } }
        .onChange(of: model.projects.map(\.id)) { old, new in
            expandedProjects.formUnion(Set(new).subtracting(old))
        }
        .task(id: connectionTaskID) { await runWorkspaceTasks() }
        .confirmationDialog("重启后台？", isPresented: $restartBackend, titleVisibility: .visible) {
            Button("重启后台并应用代理设置") { Task { await model.restart() } }
        } message: {
            Text("会保留历史会话。如果仍有运行中或待审批的任务，服务器会拒绝重启。代理设置在新的后台进程启动时生效。")
        }
        .confirmationDialog("已检查会话列表，清除本机待确认的新建记录？", isPresented: $clearPendingCreate, titleVisibility: .visible) {
            Button("清除本机记录", role: .destructive) { model.discardCreate() }
        } message: {
            Text("服务器可能已经启动了 CLI。请先刷新并检查会话列表，清除后重新新建可能重复启动。")
        }
    }

    private var connectionTaskID: String {
        connection.profile.credentialAccount + "|" + String(connection.isConnected)
    }

    private func runWorkspaceTasks() async {
        model.connectionChanged()
        guard connection.isConnected else { return }
        let workspace = model
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await workspace.pollUsage() }
            await workspace.prepare()
            group.addTask { await workspace.poll() }
            await group.waitForAll()
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
            .disabled(!model.isPrepared || !model.supportsSessionManagement || model.isBusy || ["inProgress", "starting", "waiting", "externalActive", "externalOccupied", "unknown"].contains(session.status))
    }

    /// The sidebar group of the selected chat or open draft. The bridge groups by project root,
    /// which can differ from the session's own working directory (worktrees, subfolders).
    private var selectedProjectID: String? {
        model.draftProject ?? model.sessions.first(where: { $0.id == model.selectedID })?.cwd ?? model.selected?.cwd
    }

    private var readingSessionID: String? {
        guard scenePhase == .active, isWorkspaceVisible, !showAgents, !projectTerminal, !showTerminal, !showAddProject, !showSettings,
              !showUsage, !showArchived, !showRename, !showCollaboration, historySession == nil else { return nil }
        return visibleConversationID
    }

    private var workspaceSettings: some View {
        NavigationStack {
            List {
                Section("连接") {
                    LabeledContent("当前服务器", value: connection.profile.displayName)
                    Button("管理服务器连接", systemImage: "server.rack") { showSettings = false; onOpenConnections() }
                }
                Section("偏好设置") {
                    NavigationLink {
                        Form {
                            Section("语言与外观") { LanguagePicker(); SkinPicker(); PalettePicker(); AppearancePicker() }
                            Section("个性化") {
                                NavigationLink { AppearanceCustomizationView() } label: { Label("配色与自定义头像", systemImage: "paintpalette") }
                            }
                        }.navigationTitle("外观与个性化")
                    } label: { Label("外观与个性化", systemImage: "paintpalette") }
                    Button("Agents 与启动配置", systemImage: "square.stack.3d.up") { showSettings = false; showAgents = true }
                }
                Section("服务器维护") {
                    NavigationLink {
                        Form {
                            Section("后台状态") {
                                AppText(model.status).font(.callout).foregroundStyle(.secondary)
                                Button("重新准备 / 应用更新") { Task { await model.prepare() } }
                                    .disabled(!connection.isConnected || model.isBusy)
                            }
                            Section("网络代理") {
                                TextField("HTTP 代理（可选）", text: $model.proxyURL)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                    .disabled(model.isBusy)
                                Button("重启后台并应用代理") { showSettings = false; restartBackend = true }
                                    .disabled(!connection.isConnected || model.isBusy)
                            }
                        }.navigationTitle("网络与后台")
                    } label: { Label("网络与后台", systemImage: "network") }
                    NavigationLink {
                        Form {
                            Section("Codex 数据") {
                                Button("同步服务器历史") { Task { await model.syncHistory(reset: true) } }
                                    .disabled(!model.supportsCatalog || model.isBusy)
                                Button("刷新模型列表") { Task { await model.loadModels() } }
                                    .disabled(!model.supportsCatalog || model.isBusy)
                                if !model.catalogStatus.isEmpty { AppText(model.catalogStatus).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.navigationTitle("历史与模型")
                    } label: { Label("历史与模型", systemImage: "clock.arrow.circlepath") }
                }
                if model.hasUncertainCreate {
                    Section("待确认操作") {
                        Text("有一次新建会话的结果待确认，请先检查服务器会话。")
                        Button("重试原新建请求") { Task { await model.retryCreate() } }.disabled(model.isBusy)
                        Button("清除本机记录") { showSettings = false; clearPendingCreate = true }
                    }
                }
            }.navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } } }
        }.appAppearance().presentationDetents([.large])
    }

    private var workspaceHeader: some View {
        HStack(spacing: 12) {
            Button { columnVisibility = columnVisibility == .all ? .detailOnly : .all; preferredColumn = .sidebar } label: {
                Image(systemName: "sidebar.left")
            }.accessibilityLabel("显示或隐藏侧栏")
            if showAgents {
                Text("Agents").font(.subheadline.weight(.medium))
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        if let cwd = model.selected?.cwd ?? model.draftProject { Text(URL(fileURLWithPath: cwd).lastPathComponent).foregroundStyle(.secondary); Text("/").foregroundStyle(.tertiary) }
                        Text(headerTitle).lineLimit(1)
                    }
                    Text(headerTitle).lineLimit(1)
                }.font(.subheadline)
            }
            Spacer(minLength: 8)
            if !showAgents {
                if let session = model.selected {
                    AppText(session.agentTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                }
                Button { projectTerminal.toggle() } label: {
                    Image(systemName: "terminal").frame(width: 32, height: 30)
                        .background(projectTerminal ? theme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                }.disabled(!connection.isConnected || (model.selected == nil && model.draftProject == nil))
                    .accessibilityLabel("打开项目终端")
                Menu {
                    Button("新建会话", systemImage: "square.and.pencil") { newSession() }
                        .disabled(!model.isPrepared || model.isBusy)
                    Button("刷新会话", systemImage: "arrow.clockwise") { Task { await model.reloadCurrent() } }.disabled(!model.isPrepared)
                    if let session = model.selected, !session.isTerminal {
                        Button("会话历史", systemImage: "clock") { historySession = session }
                    }
                    if model.hasUncertainSend, let pending = model.pendingSessionID {
                        Button("查看待确认消息") { Task { await model.select(pending) } }
                    }
                    if let session = model.sessions.first(where: { $0.id == model.selectedID }) { sessionActions(session) }
                    if !model.unreadSessions.isEmpty {
                        Section("未读回复") {
                            ForEach(model.unreadSessions) { session in
                                Button(session.title) { Task { await model.select(session.id) } }
                            }
                        }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 32) }.accessibilityLabel("会话操作")
            }
        }.tint(.primary).buttonStyle(.plain).padding(.horizontal, 22).frame(minHeight: 64)
            .background(theme.canvas)
    }

    private var headerTitle: String {
        model.selected?.title ?? L10n.text(model.isDrafting ? "新会话" : "工作区")
    }

    /// Opens the new-session composer (no dialog). Without any project, asks for one first.
    private func newSession(in project: String? = nil, agent: String? = nil) {
        guard model.isPrepared, !model.isBusy else { return }
        if model.startDraft(in: project, agent: agent) {
            showAgents = false
            projectTerminal = false
            preferredColumn = .detail
        } else {
            showAddProject = true
        }
    }

    private var draftRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil").font(.caption).foregroundStyle(theme.accent)
            Text("新会话").font(.subheadline).lineLimit(1)
            Spacer(minLength: 0)
            Button { Task { await model.closeDraft() } } label: {
                Image(systemName: "xmark").font(.caption2).frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("关闭新会话")
        }.padding(.vertical, 4).padding(.horizontal, 6)
            .background(!showAgents ? theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { showAgents = false; preferredColumn = .detail }
    }

    @ViewBuilder
    private func projectActions(_ project: CodexProject) -> some View {
        Button("新建会话", systemImage: "square.and.pencil") { newSession(in: project.id) }
            .disabled(!model.isPrepared || model.isBusy)
        Menu {
            ForEach(Self.agentIDs, id: \.self) { agent in
                Button { newSession(in: project.id, agent: agent) } label: { AppText(cliAgentTitle(agent)) }
            }
        } label: { Label("使用其他 Agent 新建", systemImage: "chevron.left.forwardslash.chevron.right") }
            .disabled(!model.isPrepared || model.isBusy)
        Button("复制路径", systemImage: "doc.on.doc") { UIPasteboard.general.string = project.id }
        Text(project.id)
    }

    static let agentIDs = ["codex", "claude", "gemini", "opencode", "copilot", "custom"]

    /// T3-style empty composer for a project: nothing exists on the server until the first send.
    private func draftView(_ project: String) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    if model.newAgent == "claude" && !model.createsTerminal {
                        ClaudeAvatar(animated: true).frame(width: 64, height: 56)
                    } else {
                        Image(systemName: model.createsTerminal ? "terminal" : "bubble.left.and.bubble.right")
                            .font(.system(size: 34)).foregroundStyle(.secondary)
                    }
                    Text("要做点什么？").font(.title2.weight(.semibold))
                    projectSwitcher(project)
                    let agent = L10n.text(cliAgentTitle(model.newAgent))
                    Group {
                        if model.createsTerminal {
                            Text("\(agent) 将在这个项目的交互终端中运行。")
                        } else {
                            Text("发送第一条消息后创建会话，\(agent) 会直接在这个项目中工作。")
                        }
                    }.font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if model.needsClaudeChatUpgrade {
                        Text("当前后台不支持 Claude 聊天。更新后台后才能创建；不会改用 Codex。")
                            .font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
                        Button("更新聊天后台") { Task { await model.prepare() } }
                            .disabled(model.isBusy || !connection.isConnected)
                    } else if model.isPrepared && !model.canCreateSession {
                        Text("当前 Agent 不可用，请在 Agents 中检查安装或启动配置。")
                            .font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
                        Button("管理 Agents →") { showAgents = true }
                    }
                    if model.hasUncertainCreate {
                        Text("有一次新建会话的结果待确认，请先检查服务器会话。")
                            .font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
                        HStack {
                            Button("重试原新建请求") { Task { await model.retryCreate() } }.disabled(model.isBusy)
                            Button("清除本机记录", role: .destructive) { clearPendingCreate = true }
                        }
                    }
                }.padding(.horizontal, 30).padding(.top, 72).padding(.bottom, 24)
                    .frame(maxWidth: 820).frame(maxWidth: .infinity)
            }
            if model.createsTerminal { terminalLauncher } else { composer(nil) }
        }
    }

    private func projectSwitcher(_ project: String) -> some View {
        Menu {
            ForEach(model.projects) { item in
                Button { newSession(in: item.id) } label: {
                    if item.id == project { Label(item.title, systemImage: "checkmark") } else { Text(item.title) }
                }
            }
            Divider()
            Button("添加项目…", systemImage: "folder.badge.plus") { showAddProject = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(URL(fileURLWithPath: project).lastPathComponent).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }.font(.subheadline).padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.primary.opacity(0.05), in: Capsule())
        }.tint(.primary).accessibilityLabel("切换项目")
    }

    private var terminalLauncher: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                AppText(cliAgentTitle(model.newAgent)).font(.subheadline.weight(.medium))
                AppText(model.loginNextSession ? "登录终端" : "交互终端").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            modelControls.fixedSize(horizontal: true, vertical: false)
            Button { Task { await model.startDraftTerminal() } } label: {
                Label(LocalizedStringKey(model.loginNextSession ? "启动登录终端" : "启动终端"), systemImage: "play.fill")
            }.buttonStyle(.borderedProminent).tint(theme.accent).disabled(!model.canStartDraftTerminal)
        }.padding(.horizontal, 14).padding(.vertical, 12)
            .background(theme.canvas, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.border, lineWidth: 1))
            .frame(maxWidth: 960).padding(.horizontal, 24).padding(.bottom, 16).padding(.top, 8)
            .frame(maxWidth: .infinity)
    }

    private func conversation(_ session: CodexSession) -> some View {
        let messages = theme.isCompanion || session.agent == "claude" ? CompanionReplyPolicy.displayedMessages(model.messages(for: session), state: companionState) : model.messages(for: session)
        let latestReplyID = CompanionReplyPolicy.latestReplyID(in: messages)
        return VStack(spacing: 0) {
            if session.isTerminal {
                HStack {
                    AppText(session.agentTitle + " · " + sessionStatus(session.status))
                    Spacer()
                    if session.isRunning {
                        Button("结束 CLI", role: .destructive) { Task { await model.stop() } }
                            .disabled(model.isBusy || !model.isPrepared)
                    }
                }.padding()
                if let error = session.error {
                    AppText(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(8)
                }
                TerminalSessionView(connection: connection, sessionID: session.id)
                    .id(connection.profile.credentialAccount + "|" + session.id)
            } else {
                if session.readOnly == true {
                    HStack {
                        Label(LocalizedStringKey(session.writerOccupied == true ? "此会话被其他 Codex 客户端占用。请退出另一端会话后重新检查。" : "此会话正在其他客户端运行，目前仅供查看。"), systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("重新检查") { Task { await model.reloadCurrent() } }.disabled(model.isBusy)
                    }.padding(12).background(theme.card)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if session.historyTruncated {
                            Text("当前显示最近 40 条消息，更早记录保留在服务器。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(ConversationEntry.group(messages)) { entry in
                            ConversationRow(entry: entry, model: model, sessionID: session.id,
                                avatarState: entry.replyMessages.contains(where: { $0.id == latestReplyID }) ? companionState : nil)
                        }
                        if let error = session.error, !error.isEmpty {
                            AppLabel(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
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
                        if model.messages(for: session).isEmpty {
                            if session.agent == "claude" { ClaudeAvatar(animated: true).frame(width: 64, height: 56) }
                            Text("在下面输入任务，\(session.agentTitle) 会直接在这个项目中工作。")
                                .foregroundStyle(.secondary).padding(.vertical)
                        }
                    }.padding(.horizontal, 30).padding(.vertical, 28).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
                }.defaultScrollAnchor(.bottom)
                if session.collaborationRunId != nil {
                    HStack {
                        Text("协作成员由后台调度。可在协作面板留言、停止或重试；审批仍在上方处理。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("打开协作") { showCollaboration = true }
                    }.padding()
                } else { composer(session) }
            }
        }
    }

    /// The message composer. Without a session it is the draft composer: sending creates the
    /// session first, and attachments become available once the session exists.
    private func composer(_ session: CodexSession?) -> some View {
        let isDraft = session == nil
        let control: ComposerState = session.map {
            ComposerState.resolve(status: $0.status, draft: model.draft.isEmpty && !model.attachments.isEmpty ? "附件" : model.draft, sending: model.isSending, pending: model.hasUncertainSend)
        } ?? (model.isBusy || model.isSending ? .sending : .ready)
        let running = session?.isRunning == true
        let canSubmit = isDraft ? model.canSubmitDraft : model.canSubmit
        return VStack(alignment: .leading, spacing: 8) {
            if !isDraft { AttachmentTray(model: model) }
            HStack(alignment: .bottom, spacing: 10) {
                if !isDraft { AttachmentPickerButton(model: model) }
                ComposerTextInput(text: $model.draft, canSubmit: canSubmit, canAttach: !isDraft && model.canAddAttachments, receiveAttachments: { model.attachProviders($0) }) {
                    Task { if isDraft { await model.sendDraft() } else { await model.send() } }
                }.overlay(alignment: .topLeading) {
                    if model.draft.isEmpty {
                        Text(LocalizedStringKey(isDraft ? "描述任务，发送后创建会话…" : "描述任务…")).foregroundStyle(.tertiary).padding(.top, 6).allowsHitTesting(false)
                    }
                }.frame(minWidth: 60).layoutPriority(1)
                modelControls.fixedSize(horizontal: true, vertical: false).padding(.bottom, 10)
                ComposerActionButton(state: control,
                    disabled: running ? (!connection.isConnected || !model.isPrepared || model.isBusy) : !canSubmit) {
                    Task {
                        if control == .running { await model.stop() }
                        else if isDraft { await model.sendDraft() }
                        else { await model.send() }
                    }
                }
            }
            if model.isBusy && !model.isSending { ProgressView(LocalizedStringKey(isDraft ? "正在创建会话…" : "正在处理请求…")).font(.caption) }
        }.padding(.horizontal, 14).padding(.vertical, 10)
            .background(theme.canvas, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(isDropTargeted ? theme.accent : theme.border, lineWidth: isDropTargeted ? 2 : 1))
            .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
                guard model.canAddAttachments else { return false }
                model.attachProviders(providers); return true
            }
            .frame(maxWidth: 960).padding(.horizontal, 24).padding(.bottom, 16).padding(.top, 8)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.2), value: control)
    }

    private var modelControls: some View {
        let session = model.selected
        return ComposerControls(
            codexModels: model.models, claudeModels: model.claudeModels, chosen: model.chosenModel,
            agent: session?.agent ?? model.newAgent,
            isDraft: model.isDrafting && session == nil,
            terminal: session?.isTerminal ?? model.createsTerminal,
            selectedModel: model.selectedModel, selectedEffort: model.selectedEffort, accessMode: model.accessMode,
            isClaudeChat: model.isClaudeChat, supportsAccessMode: model.supportsAccessMode,
            needsBackendUpdate: model.isClaudeChat && !model.supportsClaudeModels,
            enabled: model.isPrepared && !model.isBusy,
            compact: sizeClass != .regular,
            selectModel: { model.chooseModel($0, agent: $1) },
            selectEffort: { model.chooseEffort($0) },
            selectAccess: { model.accessMode = $0; model.accessModeChanged() },
            chooseTerminal: { model.chooseTerminal(agent: $0) },
            newSession: { newSession(agent: $0) },
            manageAgents: { showAgents = true },
            showUsage: { showUsage = true },
            refresh: { Task { await model.loadModels() } },
            updateBackend: { Task { await model.prepare() } }
        ).equatable()
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

/// The composer's Agent / model, effort and permission controls, modelled on T3 Code's
/// provider-model picker: one menu lists every agent's models. A draft can switch agents
/// freely; an existing session keeps its agent and offers a new session for the others.
/// It is compared by value only (closures are ignored), so the workspace's periodic
/// refreshes cannot rebuild the menus while the user is choosing.
private struct ComposerControls: View, Equatable {
    let codexModels: [CodexModel]
    let claudeModels: [CodexModel]
    let chosen: CodexModel?
    let agent: String
    let isDraft: Bool
    let terminal: Bool
    let selectedModel: String
    let selectedEffort: String
    let accessMode: AccessMode
    let isClaudeChat: Bool
    let supportsAccessMode: Bool
    let needsBackendUpdate: Bool
    let enabled: Bool
    let compact: Bool
    let selectModel: (String, String) -> Void
    let selectEffort: (String) -> Void
    let selectAccess: (AccessMode) -> Void
    let chooseTerminal: (String) -> Void
    let newSession: (String) -> Void
    let manageAgents: () -> Void
    let showUsage: () -> Void
    let refresh: () -> Void
    let updateBackend: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.codexModels == b.codexModels && a.claudeModels == b.claudeModels && a.chosen == b.chosen &&
        a.agent == b.agent && a.isDraft == b.isDraft && a.terminal == b.terminal &&
        a.selectedModel == b.selectedModel && a.selectedEffort == b.selectedEffort && a.accessMode == b.accessMode &&
        a.isClaudeChat == b.isClaudeChat && a.supportsAccessMode == b.supportsAccessMode &&
        a.needsBackendUpdate == b.needsBackendUpdate && a.enabled == b.enabled && a.compact == b.compact
    }

    private static let chatAgents = ["codex", "claude"]
    private static let terminalAgents = ["gemini", "opencode", "copilot", "custom"]

    private var hasEfforts: Bool { !terminal && chosen?.supportedReasoningEfforts.isEmpty == false }

    var body: some View {
        HStack(spacing: 10) {
            Menu { modelMenu } label: {
                HStack(spacing: 4) {
                    if compact { Image(systemName: "slider.horizontal.3") }
                    else { Text(verbatim: modelTitle).lineLimit(1).frame(maxWidth: 190) }
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }.accessibilityLabel("选择 Agent 与模型")
            if !compact && hasEfforts {
                Menu { effortPicker } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: effortTitle).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }.accessibilityLabel("推理强度")
            }
            if !compact && !terminal {
                Menu { accessPicker } label: {
                    Label { AppText(accessMode.title) } icon: { Image(systemName: accessMode.symbol) }
                        .labelStyle(.titleAndIcon)
                }.accessibilityLabel("下次任务的权限")
            }
        }.font(.caption).tint(.primary).disabled(!enabled)
    }

    private var modelTitle: String {
        let agentTitle = L10n.text(cliAgentTitle(agent))
        if terminal { return agentTitle + " · " + L10n.text("终端") }
        let name = chosen?.displayName ?? (selectedModel.isEmpty ? L10n.text("默认模型") : selectedModel)
        let effort = compact && isClaudeChat && !selectedEffort.isEmpty ? " · " + selectedEffort : ""
        return isDraft ? agentTitle + " · " + name + effort : name + effort
    }

    private var effortTitle: String {
        guard let effort = chosen?.supportedReasoningEfforts.first(where: { $0.reasoningEffort == selectedEffort }) else {
            return L10n.text("默认推理强度")
        }
        return isClaudeChat ? L10n.text(effort.title) : effort.reasoningEffort
    }

    @ViewBuilder
    private var modelMenu: some View {
        if isDraft {
            ForEach(Self.chatAgents, id: \.self) { id in
                Section {
                    modelButtons(for: id)
                    Button { chooseTerminal(id) } label: { checkLabel(L10n.text("在终端中运行"), checked: terminal && agent == id) }
                } header: { AppText(cliAgentTitle(id)) }
            }
            Section {
                ForEach(Self.terminalAgents, id: \.self) { id in
                    Button { chooseTerminal(id) } label: { checkLabel(L10n.text(cliAgentTitle(id)), checked: agent == id) }
                }
            } header: { AppText("仅终端") }
        } else {
            if !terminal {
                Section { modelButtons(for: agent) } header: { AppText(cliAgentTitle(agent)) }
            }
            Menu {
                ForEach(Self.chatAgents + Self.terminalAgents, id: \.self) { id in
                    Button { newSession(id) } label: { AppText(cliAgentTitle(id)) }
                }
            } label: { Label("用其他 Agent 新建会话", systemImage: "square.and.pencil") }
        }
        if compact && hasEfforts { effortPicker }
        if compact && !terminal { accessPicker }
        Divider()
        if !terminal && !isClaudeChat && agent == "codex" {
            Button("Codex 用量与额度", systemImage: "chart.pie", action: showUsage)
        }
        if !terminal { Button("刷新模型与强度", systemImage: "arrow.clockwise", action: refresh) }
        if needsBackendUpdate { Button("更新聊天后台", action: updateBackend) }
        Button("管理 Agents →", action: manageAgents)
    }

    @ViewBuilder
    private func modelButtons(for id: String) -> some View {
        let models = id == "claude" ? claudeModels : codexModels
        let active = agent == id && !terminal
        Button { selectModel("", id) } label: {
            checkLabel(L10n.text(isDraft ? "默认模型" : "沿用会话 / 默认模型"), checked: active && selectedModel.isEmpty)
        }
        if active && !selectedModel.isEmpty && !models.contains(where: { matches($0) }) {
            Button { selectModel(selectedModel, id) } label: { checkLabel(selectedModel, checked: true) }
        }
        ForEach(models) { item in
            Button { selectModel(item.model, id) } label: { checkLabel(item.displayName, checked: active && matches(item)) }
        }
    }

    private func matches(_ item: CodexModel) -> Bool {
        item.model == selectedModel || item.aliases?.contains(selectedModel) == true
    }

    @ViewBuilder
    private func checkLabel(_ title: String, checked: Bool) -> some View {
        if checked { Label(title, systemImage: "checkmark") } else { Text(verbatim: title) }
    }

    @ViewBuilder
    private var effortPicker: some View {
        if let chosen, !chosen.supportedReasoningEfforts.isEmpty {
            Picker("推理强度", selection: Binding(get: { selectedEffort }, set: selectEffort)) {
                Text("默认推理强度").tag("")
                ForEach(chosen.supportedReasoningEfforts) { AppText(isClaudeChat ? $0.title : $0.reasoningEffort).tag($0.reasoningEffort) }
            }
        }
    }

    private var accessPicker: some View {
        Picker("下次任务的权限", selection: Binding(get: { accessMode }, set: selectAccess)) {
            ForEach(AccessMode.allCases) { mode in Label(LocalizedStringKey(mode.title), systemImage: mode.symbol).tag(mode) }
        }.disabled(!supportsAccessMode)
    }
}

/// Picks a server directory to add as a project, then opens a new session in it.
private struct AddProjectSheet: View {
    @ObservedObject var model: WorkspaceModel
    let didChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var manualPath = ""

    var body: some View {
        NavigationStack {
            List {
                if let listing = model.listing {
                    Section("当前目录") {
                        Text(listing.path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Button { Task { await choose(listing.path) } } label: {
                            Label(LocalizedStringKey(primaryTitle(listing.path)), systemImage: "plus.circle.fill")
                        }.disabled(model.isBusy || !model.isPrepared)
                        if let parent = listing.parent {
                            Button("返回上级目录", systemImage: "arrow.up") { Task { await model.browse(parent) } }
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
                        .onSubmit { Task { await model.browse(manualPath) } }
                    Button("打开目录") { Task { await model.browse(manualPath) } }
                        .disabled(manualPath.isEmpty || model.isBusy)
                    Text("默认只允许当前 SSH 用户的 Home 目录及其子目录。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.error { AppText(error).foregroundStyle(.red) }
            }
            .navigationTitle("添加项目")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func primaryTitle(_ path: String) -> String {
        if model.projects.contains(where: { $0.id == path }) { return "在此项目新建会话" }
        return model.supportsProjects ? "添加项目并新建会话" : "在此目录新建会话"
    }

    private func choose(_ path: String) async {
        if model.supportsProjects && !model.projects.contains(where: { $0.id == path }) {
            guard await model.addProject(cwd: path) else { return }
        }
        dismiss()
        didChoose(path)
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
                    if let error { AppText(error).foregroundStyle(.red) }
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
    private var agent: String { model.sessions.first(where: { $0.id == sessionID })?.agent ?? "codex" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if entry.isUserMessage {
                ForEach(entry.messages) { message in messageContent(message) }
            } else {
                if !entry.replyMessages.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        if agent == "claude" {
                            HStack(spacing: 8) {
                                ClaudeAvatar(state: avatarState ?? .idle, animated: avatarState != nil)
                                    .frame(width: theme.isCompanion ? 64 : 38, height: theme.isCompanion ? 56 : 34)
                                Text("Claude Code").font(.subheadline.weight(.semibold))
                                Spacer()
                            }
                        } else if theme.isCompanion {
                            HStack(spacing: 8) {
                                if let avatarState {
                                    CompanionAvatar(state: avatarState).frame(width: 72, height: 72)
                                } else { BrandMark().frame(width: 56, height: 56) }
                                Text("Codex").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                        if !theme.isCompanion && agent != "claude" {
                            Label("Codex", systemImage: "chevron.left.forwardslash.chevron.right")
                                .font(.subheadline.weight(.semibold)).padding(.bottom, 4)
                        }
                        ForEach(entry.replyMessages) { message in messageContent(message) }
                    }
                    .padding(theme.isCompanion ? 18 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.isCompanion ? theme.card : .clear, in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.isCompanion ? theme.border : .clear, lineWidth: 1))
                }
                if !entry.activityMessages.isEmpty {
                    ActivityGroup(entry: ConversationEntry(messages: entry.activityMessages), model: model, sessionID: sessionID)
                }
            }
        }.modifier(RemoteFileLinks(model: model, sessionID: sessionID))
    }

    @ViewBuilder
    private func messageContent(_ message: CodexMessage) -> some View {
        if !message.text.isEmpty || message.kind == "userMessage" {
            MessageCard(message: message, model: model, sessionID: sessionID)
        }
        if message.textTruncated == true {
            FullMessageButton(model: model, sessionID: sessionID, messageID: message.id,
                              length: message.contentLength ?? message.text.count, plainText: message.kind == "userMessage")
        }
    }
}

private struct ActivityGroup: View {
    @Environment(\.locale) private var locale
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
                            Group {
                                if message.kind == "commandExecution" { Text(verbatim: message.activityTitle) }
                                else { AppText(message.activityTitle) }
                            }.lineLimit(1).truncationMode(.middle)
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
                Text(verbatim: entry.localizedSummary(locale: locale)).lineLimit(1)
            }.font(.subheadline).foregroundStyle(.secondary)
        }.tint(.secondary).padding(12)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }
}

private struct MessageCard: View {
    @Environment(\.interfaceTheme) private var theme
    let message: CodexMessage
    @ObservedObject var model: WorkspaceModel
    let sessionID: String
    @State private var clearPending = false
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
                    if ["sending", "unknown", "failed"].contains(message.status) {
                    AppLabel(deliveryLabel, systemImage: message.status == "sending" ? "clock" :
                            message.status == "unknown" || message.status == "failed" ? "exclamationmark.circle" : "checkmark")
                        .font(.caption2).foregroundStyle(deliveryColor).padding(.trailing, 8)
                    }
                    if model.retryRequest(for: message.id) != nil {
                        HStack(spacing: 12) {
                            Button(message.status == "failed" ? "重试" : "确认并重试") {
                                Task { await model.send(retryMessageID: message.id) }
                            }.disabled(model.isBusy || !model.isPrepared || model.isSending || model.selected?.readOnly == true ||
                                       (model.selected?.isRunning == true && !model.isPendingMessage(message.id)))
                            if model.isPendingMessage(message.id) {
                                Button("清除待确认记录") { clearPending = true }
                            }
                        }.font(.caption)
                        if message.status == "unknown" {
                            Text("发送结果待确认。重试会核对原消息，不会发送输入框中的新草稿。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }.confirmationDialog("清除这条消息的待确认记录？", isPresented: $clearPending, titleVisibility: .visible) {
                Button("已核实服务器状态，清除记录", role: .destructive) {
                    if model.isPendingMessage(message.id) { model.discardPending() }
                }
            } message: { Text("这不会停止服务器上的任务。请先检查会话，避免重复执行。") }
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
            Label(LocalizedStringKey(approval.isQuestion ? "需要你的回答" : "需要你的审批"), systemImage: "hand.raised")
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
