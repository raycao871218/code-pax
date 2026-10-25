import SwiftUI

struct RootView: View {
    @StateObject private var connection = ConnectionModel()
    @State private var tab = 1

    var body: some View {
        TabView(selection: $tab) {
            WorkspaceView(connection: connection)
                .tabItem { Label("工作区", systemImage: "bubble.left.and.bubble.right") }.tag(0)
            ConnectionView(model: connection)
                .tabItem { Label("连接", systemImage: "network") }.tag(1)
        }
        .onChange(of: connection.isConnected) { _, connected in
            if connected { tab = 0 }
        }
    }
}

struct WorkspaceView: View {
    @ObservedObject var connection: ConnectionModel
    @StateObject private var model: WorkspaceModel
    @State private var showProjects = false
    @State private var clearPending = false
    @State private var restartBackend = false

    init(connection: ConnectionModel) {
        self.connection = connection
        _model = StateObject(wrappedValue: WorkspaceModel(connection: connection))
    }

    var body: some View {
        NavigationSplitView {
            List {
                Section {
                    Label(connection.isConnected ? "SSH 已连接" : "SSH 未连接",
                          systemImage: connection.isConnected ? "checkmark.circle.fill" : "network")
                        .foregroundStyle(connection.isConnected ? Color.green : Color.secondary)
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                    TextField("HTTP 代理（可选）", text: $model.proxyURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .disabled(model.isBusy)
                    if !model.isPrepared {
                        Button("准备 Codex 工作区") { Task { await model.prepare() } }
                            .disabled(!connection.isConnected || model.isBusy)
                        Text("将后台脚本安装到服务器当前用户目录。任务在服务器运行，断开 App 后仍可继续。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button { showProjects = true } label: { Label("新建项目会话", systemImage: "plus") }
                            .disabled(model.isBusy)
                    }
                    Button("重启 Codex 后台") { restartBackend = true }
                        .font(.caption).disabled(!connection.isConnected || model.isBusy)
                }
                Section("最近会话") {
                    ForEach(model.sessions) { session in
                        Button { Task { await model.select(session.id) } } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(session.title).fontWeight(.medium).lineLimit(1)
                                    if session.id == model.selectedID { Image(systemName: "checkmark") }
                                }
                                Text(session.cwd).font(.caption).lineLimit(1)
                                Text(sessionStatus(session.status)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .tint(.primary)
                        .disabled(!model.isPrepared)
                    }
                }
            }
            .navigationTitle("Codex iPad")
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                        .textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.06))
                }
                if let session = model.selected {
                    conversation(session)
                } else {
                    ContentUnavailableView("开始一个项目会话", systemImage: "bubble.left.and.bubble.right",
                        description: Text(connection.isConnected ? "先准备工作区，然后选择项目目录并新建会话。" : "先在“连接”页面登录服务器。"))
                }
            }
            .navigationTitle(model.selected?.title ?? "工作区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(!model.isPrepared)
                }
            }
        }
        .sheet(isPresented: $showProjects) { ProjectPicker(model: model) }
        .task(id: connection.isConnected) {
            model.connectionChanged()
            if connection.isConnected { await model.poll() }
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

    private func conversation(_ session: CodexSession) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(sessionStatus(session.status)).font(.subheadline.weight(.medium))
                Spacer()
                Text(session.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if session.isRunning {
                    Button("停止", role: .destructive) { Task { await model.stop() } }
                        .disabled(model.isBusy || !model.isPrepared)
                }
            }.padding()
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if session.historyTruncated {
                        Text("当前显示最近 40 条消息，更早记录保留在服务器。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(session.messages) { message in MessageCard(message: message) }
                    if let error = session.error, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                    }
                    ForEach(session.approvals) { approval in
                        ApprovalCard(approval: approval, disabled: model.isBusy || !model.isPrepared) { decision, answers in
                            Task { await model.answer(approval, decision: decision, answers: answers) }
                        }
                    }
                    if !session.diff.isEmpty {
                        DisclosureGroup("当前任务的代码差异") { DiffView(text: session.diff) }
                            .padding().background(Color.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if session.messages.isEmpty {
                        Text("在下面输入任务，Codex 会直接在这个项目中工作。")
                            .foregroundStyle(.secondary).padding(.vertical)
                    }
                }.padding(20).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
            }
            Divider()
            composer(session)
        }
    }

    private func composer(_ session: CodexSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.hasUncertainSend {
                Text("有一条发送结果待确认。点击重试将使用同一个操作 ID，不会再次启动已接收的任务。")
                    .font(.caption).foregroundStyle(.orange)
                Button("已检查会话，清除本机重试记录") { clearPending = true }.font(.caption)
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("给 Codex 一个任务…", text: $model.draft, axis: .vertical)
                    .lineLimit(2...8).padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    .disabled(model.hasUncertainSend)
                Button(model.hasUncertainSend ? "重试" : "发送") { Task { await model.send() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || !model.isPrepared ||
                              (!model.hasUncertainSend && (session.isRunning || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)))
            }
            Text("按服务器现有 Codex 账号和模型计费。命令审批由你处理。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding()
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

private struct MessageCard: View {
    let message: CodexMessage
    private var isTool: Bool { !["userMessage", "agentMessage", "plan"].contains(message.kind) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.kind == "userMessage" ? "你" : message.kind == "agentMessage" ? "Codex" : message.kind)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if isTool {
                DisclosureGroup(message.text.split(separator: "\n").first.map(String.init) ?? "执行详情") {
                    Text(message.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(LocalizedStringKey(message.text)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(message.kind == "userMessage" ? Color.indigo.opacity(0.08) : Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
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
                Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
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
