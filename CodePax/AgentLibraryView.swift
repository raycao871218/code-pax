import SwiftUI

struct AgentPreferences: Codable, Equatable {
    var agent = "codex"
    var mode = "chat"
    var command = ""

    static func load(server: String, defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: server + ".agentPreferences"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    func save(server: String, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: server + ".agentPreferences") }
    }
}

struct AgentLibraryView: View {
    @Environment(\.interfaceTheme) private var theme
    @ObservedObject var model: WorkspaceModel
    let openTerminal: () -> Void
    let startSession: () -> Void
    @State private var configuring = false

    private let presets = [
        ("codex", "Codex", "codex"), ("claude", "Claude Code", "claude"),
        ("gemini", "Gemini CLI", "gemini"), ("opencode", "OpenCode", "opencode"),
        ("copilot", "GitHub Copilot", "copilot")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    Text("编程工具").font(.title2.weight(.semibold))
                    Spacer()
                    Button { Task { await model.prepare() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("重新检测可用 Agent")
                        .disabled(!model.connection.isConnected || model.isBusy)
                }
                VStack(spacing: 0) {
                    ForEach(presets, id: \.0) { id, title, command in
                        agentRow(id: id, title: title, command: command)
                        Divider().padding(.leading, 42)
                    }
                    agentRow(id: "custom", title: "自定义 CLI", command: "自己的启动命令")
                }
                Divider()
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        AppText(cliAgentTitle(model.newAgent)).font(.headline)
                        Spacer()
                        Button("配置", systemImage: "slider.horizontal.3") { configuring = true }
                            .accessibilityIdentifier("agent.configure")
                    }
                    if AgentSessionSelection.hasChat(model.newAgent) {
                        Picker("会话模式", selection: $model.newSessionMode) {
                            Text("聊天").tag("chat")
                            Text("终端").tag("terminal")
                        }.pickerStyle(.segmented)
                    }
                    if model.needsClaudeChatUpgrade {
                        Text("当前服务器后台尚未启用 Claude 聊天。请先完成运行中的任务，再更新后台；不会改用 Codex 或终端。")
                            .font(.callout).foregroundStyle(.orange)
                        Button("更新聊天后台") { Task { await model.prepare() } }
                            .disabled(!model.connection.isConnected || model.isBusy)
                    }
                    let configuration = model.configuration(for: model.newAgent)
                    if !configuration.model.isEmpty {
                        LabeledContent("模型", value: configuration.model).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if model.agentConfigurations[model.newAgent] != nil && !model.supportsAgentConfiguration {
                        Text("请刷新后台以使用已保存的配置。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    HStack(spacing: 16) {
                        Button { model.loginNextSession = false; startSession() } label: {
                            Label("新建会话", systemImage: "plus")
                        }.buttonStyle(.borderedProminent)
                            .disabled(!model.isPrepared || !model.canCreateSession || model.isBusy || model.hasUncertainCreate)
                        if !configuration.loginCommand.isEmpty {
                            Button("登录") { model.loginNextSession = true; startSession() }
                                .disabled(!model.isPrepared || !model.supportsAgentConfiguration || model.isBusy || model.hasUncertainCreate)
                        }
                    }
                }
                DisclosureGroup("安装与使用") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("在服务器安装 CLI，或在配置中填写完整路径。配置按服务器保存，新会话使用当前选择。")
                        Text("Codex 和 Claude Code 支持原生聊天与交互终端；其他工具在交互终端中运行。")
                        if !model.supportsClaudeChat { Text("Claude 聊天需要更新后台，请完成当前任务后重新准备工作区。") }
                        Button("打开服务器终端", systemImage: "terminal", action: openTerminal)
                            .disabled(!model.connection.isConnected)
                    }.font(.callout).foregroundStyle(.secondary).padding(.top, 12)
                }.font(.subheadline).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }.background(theme.canvas)
            .sheet(isPresented: $configuring) { AgentConfigurationView(model: model, agent: model.newAgent).appAppearance() }
            .onChange(of: model.newAgent) { _, _ in model.saveAgentPreferences() }
            .onChange(of: model.newSessionMode) { _, _ in model.saveAgentPreferences() }
            .onChange(of: model.customCommand) { _, _ in model.saveAgentPreferences() }
    }

    private func agentRow(id: String, title: String, command: String) -> some View {
        let available = id == "custom" ? model.supportsTerminal : model.agents.first(where: { $0.id == id })?.available == true
        let selected = model.newAgent == id
        return Button {
            model.chooseAgent(id)
        } label: {
            HStack(spacing: 12) {
                if id == "claude" {
                    ClaudeAvatar().frame(width: 28, height: 28)
                } else {
                    Image(systemName: id == "custom" ? "slider.horizontal.3" : "terminal")
                        .font(.body).foregroundStyle(.secondary).frame(width: 28)
                }
                VStack(alignment: .leading, spacing: 3) {
                    AppText(title).font(.body).foregroundStyle(.primary)
                    Text(model.agentConfigurations[id]?.executable ?? command)
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if model.agentConfigurations[id] != nil {
                    Text("已配置").font(.caption).foregroundStyle(.secondary)
                } else if id != "custom" {
                    AppText(!model.isPrepared ? "待检测" : available ? "可用" : "未安装")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark").font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.accent).opacity(selected ? 1 : 0).frame(width: 18)
            }.padding(.vertical, 12).padding(.horizontal, 10)
                .contentShape(Rectangle())
                .background(selected ? theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel(title + (selected ? "，已选择" : ""))
            .accessibilityIdentifier("agent." + id)
    }
}
