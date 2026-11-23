import SwiftUI

struct AgentConfigurationView: View {
    @ObservedObject var model: WorkspaceModel
    let agent: String
    @Environment(\.dismiss) private var dismiss
    @State private var configuration: AgentConfiguration
    @State private var error: String?

    init(model: WorkspaceModel, agent: String) {
        self.model = model; self.agent = agent
        _configuration = State(initialValue: model.configuration(for: agent))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("启动") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("命令或完整路径").font(.caption).foregroundStyle(.secondary)
                        TextField("例如 claude", text: $configuration.executable)
                            .accessibilityIdentifier("agentConfig.executable")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("启动参数").font(.caption).foregroundStyle(.secondary)
                        TextField("可选", text: $configuration.arguments, axis: .vertical)
                            .accessibilityIdentifier("agentConfig.arguments")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("默认模型").font(.caption).foregroundStyle(.secondary)
                        TextField("沿用工具默认值", text: $configuration.model)
                    }
                }
                Section("账号") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("登录命令").font(.caption).foregroundStyle(.secondary)
                        TextField("例如 claude auth login", text: $configuration.loginCommand, axis: .vertical)
                            .accessibilityIdentifier("agentConfig.login")
                    }
                    DisclosureGroup(configuration.environment.isEmpty ? "环境变量" : "环境变量 · 已设置") {
                        TextEditor(text: $configuration.environment).frame(minHeight: 130)
                            .font(.system(.body, design: .monospaced)).accessibilityIdentifier("agentConfig.environment")
                        Text("每行 NAME=value，值无需加引号。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    DisclosureGroup("高级与说明") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("模型参数名").font(.caption).foregroundStyle(.secondary)
                            TextField("--model", text: $configuration.modelArgument)
                        }
                        Text("参数支持引号，按参数列表执行。环境变量只传给对应进程。保存后，可从 Agent 页面启动登录终端。")
                            .font(.caption).foregroundStyle(.secondary)
                        if agent == "codex" {
                            Text("Codex 原生聊天仅应用默认模型，其余启动配置用于交互终端。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if agent == "claude" {
                            Text("Claude 聊天应用路径、环境变量和模型；会话恢复、消息格式与权限参数由 App 管理。模型可填写 sonnet、opus、haiku 或账号可用的完整模型 ID。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("按服务器保存到本机钥匙串，下次新建会话生效。")
                }
                if let error { Section { AppText(error).foregroundStyle(.red) } }
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
                .navigationTitle(L10n.text(cliAgentTitle(agent) + " 配置")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            do {
                                try model.saveConfiguration(configuration, for: agent)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }.disabled(configuration.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
