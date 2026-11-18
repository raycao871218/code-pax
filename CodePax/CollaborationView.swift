import SwiftUI

@MainActor
struct CollaborationView: View {
    @ObservedObject private var workspace: WorkspaceModel
    @StateObject private var model: CollaborationModel
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var discardPending = false
    let openSession: (String) -> Void

    init(workspace: WorkspaceModel, openSession: @escaping (String) -> Void) {
        self.workspace = workspace
        self.openSession = openSession
        _model = StateObject(wrappedValue: CollaborationModel(workspace: workspace))
    }

    var body: some View {
        NavigationStack {
            List {
                if !workspace.supportsCollaboration {
                    Section {
                        Text("协作需要可用的 Codex 聊天后台。请确认服务器已安装并登录 Codex；若有后台更新，等待现有任务结束后重新准备。")
                        Button("重新准备后台") { Task { await workspace.prepare() } }
                            .disabled(workspace.isBusy || !workspace.connection.isConnected)
                    }
                }
                if let error = model.error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                if model.hasPendingOperation {
                    Section("一次操作的结果待确认") {
                        Text("先刷新查看任务状态。重试将复用原请求，避免重复启动或应用成果。")
                            .font(.caption)
                        Button("重试原操作") { Task { await model.perform() } }.disabled(model.isBusy || !model.isAvailable)
                        Button("已核实状态，清除本机记录") { discardPending = true }.font(.caption)
                    }
                }
                Section {
                    ForEach(model.runs) { run in
                        NavigationLink {
                            CollaborationRunView(model: model, runID: run.id, openSession: openSession)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(run.goal).lineLimit(2)
                                Text(collaborationStatus(run.status) + " · \(run.workers.count) 个 Worker · 并行上限 \(run.maxWorkers)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(run.cwd).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    if model.runs.isEmpty {
                        ContentUnavailableView("创建一组协作任务", systemImage: "person.3",
                            description: Text("拆分任务交给多个 Codex，在独立工作区执行，最后由主控汇总。"))
                    }
                }
            }
            .navigationTitle("多 Agent 协作")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("新建协作").disabled(!model.canAct)
                }
            }
            .refreshable { await model.refresh() }
            .sheet(isPresented: $creating) { CreateCollaborationView(model: model, workspace: workspace) }
            .confirmationDialog("已核实服务器状态，清除本机待确认记录？", isPresented: $discardPending, titleVisibility: .visible) {
                Button("清除本机记录", role: .destructive) { model.discardPending() }
            } message: { Text("这不会撤销已执行的服务器操作。重新创建可能启动另一组任务。") }
        }
        .task { await model.poll() }
    }
}

@MainActor
private struct CreateCollaborationView: View {
    @ObservedObject var model: CollaborationModel
    @ObservedObject var workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var cwd = ""
    @State private var goal = ""
    @State private var tasks = [CollaborationTaskDraft(title: "任务 1"), CollaborationTaskDraft(title: "任务 2")]
    @State private var maxWorkers = 2

    var body: some View {
        NavigationStack {
            Form {
                Section("项目与目标") {
                    if !workspace.projects.isEmpty {
                        Picker("项目", selection: $cwd) {
                            Text("选择项目").tag("")
                            ForEach(workspace.projects) { project in Text(project.title).tag(project.id) }
                        }
                    }
                    TextField("Git 仓库根目录", text: $cwd).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("这组任务要完成什么？", text: $goal, axis: .vertical).lineLimit(2...5)
                    Stepper("最多同时执行 \(maxWorkers) 个 Worker", value: $maxWorkers, in: 1...4)
                    Text("项目需要已有 Git 提交且没有未提交改动。各 Worker 独立执行，全部结束后主控会审阅并整合。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($tasks) { $task in
                    Section {
                        TextField("任务名称", text: $task.title)
                        TextField("负责范围、执行要求和验收标准", text: $task.prompt, axis: .vertical).lineLimit(3...10)
                        if tasks.count > 1 {
                            Button("移除任务", role: .destructive) { tasks.removeAll { $0.id == task.id } }
                        }
                    }
                }
                if tasks.count < 8 { Button("添加 Worker 任务") { tasks.append(CollaborationTaskDraft()) } }
                Section("执行设置") {
                    LabeledContent("CLI", value: "Codex")
                    LabeledContent("模型", value: workspace.selectedModel.isEmpty ? "服务器默认" : workspace.selectedModel)
                    LabeledContent("权限", value: workspace.accessMode == .fullAccess ? "Full Access" : "默认权限")
                    Text("使用当前聊天的模型和权限设置。需要审批或澄清时，可从成员卡片打开会话处理。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .navigationTitle("新建协作")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始") {
                        Task { if await model.create(cwd: cwd, goal: goal, tasks: tasks, maxWorkers: maxWorkers) { dismiss() } }
                    }.disabled(!model.canAct || cwd.isEmpty || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                               goal.count > 4000 || tasks.contains { !$0.isValid })
                }
            }
            .onAppear {
                cwd = workspace.selected?.collaborationRunId == nil ? workspace.selected?.cwd ?? workspace.projects.first?.id ?? "" : workspace.projects.first?.id ?? ""
            }
        }.interactiveDismissDisabled(model.isBusy)
    }
}

@MainActor
private struct CollaborationRunView: View {
    @ObservedObject var model: CollaborationModel
    let runID: String
    let openSession: (String) -> Void
    @State private var message = ""
    @State private var recipient = "all"
    @State private var reviewing: CollaborationTask?

    var body: some View {
        Group {
            if let run = model.runs.first(where: { $0.id == runID }) {
                contents(run)
            } else { ContentUnavailableView("找不到协作任务", systemImage: "person.3") }
        }
        .navigationTitle("协作详情").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $reviewing) { task in CollaborationDiffView(model: model, runID: runID, task: task) }
        .refreshable { await model.refresh() }
        .task(id: runID) { await model.focus(runID) }
        .onDisappear { model.unfocus(runID) }
    }

    private func contents(_ run: CollaborationRun) -> some View {
        List {
            overview(run)
            ForEach(run.tasks) { task in member(task, run: run) }
            results(run)
            inbox(run)
            if let error = model.error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
        }
    }

    private func overview(_ run: CollaborationRun) -> some View {
        Section {
            Text(run.goal).font(.headline).textSelection(.enabled)
            LabeledContent("状态", value: collaborationStatus(run.status))
            LabeledContent("项目分支", value: run.sourceBranch)
            if let error = run.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if run.isActive {
                Button("停止协作", role: .destructive) {
                    Task { await model.perform(["action": .string("teamCancel"), "runId": .string(runID)]) }
                }.disabled(!model.canAct || run.status == "cancelling")
            }
        }
    }

    private func member(_ task: CollaborationTask, run: CollaborationRun) -> some View {
        Section(task.role == "coordinator" ? "主控" : "Worker") {
            Text(task.title).font(.headline)
            Text(collaborationStatus(task.status) + (task.attempt > 1 ? " · 第 \(task.attempt) 次执行" : ""))
                .font(.subheadline).foregroundStyle(task.status == "waiting" ? Color.orange : Color.secondary)
            if let error = task.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !task.result.isEmpty { Text(task.result).font(.callout).textSelection(.enabled) }
            if let session = task.sessionId { Button("打开成员会话 / 处理审批") { openSession(session) } }
            if task.isRunning, task.status != "unknown", let session = task.sessionId {
                Button("停止此成员", role: .destructive) {
                    Task { await model.perform(["action": .string("stop"), "sessionId": .string(session)]) }
                }.disabled(!model.canAct)
            }
            if task.snapshotCommit != nil { Button("审阅成果差异") { reviewing = task } }
            if task.integrated { Label("已整合到主控工作区", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
            if run.canRetry(task) {
                Button("重试这个成员") {
                    Task { await model.perform(["action": .string("teamRetry"), "runId": .string(runID), "taskId": .string(task.id)]) }
                }.disabled(!model.canAct)
            }
            Text(task.branch).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func results(_ run: CollaborationRun) -> some View {
        if let coordinator = run.coordinator, coordinator.snapshotCommit != nil {
            Section("汇总成果") {
                Button("审阅汇总差异") { reviewing = coordinator }
                if let commit = run.appliedCommit {
                    Label("已应用到项目 · " + String(commit.prefix(8)), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("应用汇总成果到项目") {
                        Task { await model.perform(["action": .string("teamApply"), "runId": .string(runID)]) }
                    }.disabled(!model.canAct || !run.canApply)
                    Text("应用前会检查原项目仍在原分支、没有未提交修改且未产生新提交。成果不会自动覆盖项目。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func inbox(_ run: CollaborationRun) -> some View {
        Section("协作留言") {
            ForEach(run.messages.suffix(50)) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(run.memberTitle(item.from) + " → " + run.memberTitle(item.to)).font(.caption).foregroundStyle(.secondary)
                    Text(item.text).textSelection(.enabled)
                }
            }
            Picker("发给", selection: $recipient) {
                Text("所有成员").tag("all")
                ForEach(run.tasks) { task in Text(task.title).tag(task.id) }
            }
            TextField("留言内容", text: $message, axis: .vertical).lineLimit(2...5)
            Button("发送留言") {
                let text = message
                Task {
                    if await model.perform(["action": .string("teamMessage"), "runId": .string(runID), "to": .string(recipient), "text": .string(text)]), message == text { message = "" }
                }
            }.disabled(!model.canAct || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.count > 4000)
            Text("留言会保存在成员收件箱，不会自动打断正在执行的任务。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct CollaborationDiffView: View {
    @ObservedObject var model: CollaborationModel
    let runID: String
    let task: CollaborationTask
    @Environment(\.dismiss) private var dismiss
    @State private var diff: CollaborationDiff?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 12) {
                    if let error { Text(error).foregroundStyle(.red) }
                    else if let diff {
                        if diff.truncated { Text("差异过长，仅显示前 128 KiB。完整成果保留在服务器成果分支。").foregroundStyle(.orange) }
                        Text(diff.text.isEmpty ? "没有代码改动" : diff.text)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    } else { ProgressView("读取差异…") }
                }.padding()
            }.navigationTitle(task.title)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.task {
            do { diff = try await model.diff(runID: runID, taskID: task.id) }
            catch { self.error = error.localizedDescription }
        }
    }
}
