import SwiftUI

struct ConnectionView: View {
    @ObservedObject var model: ConnectionModel
    @State private var showForgetConfirmation = false
    @State private var showDeleteServer = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    connectionForm
                    statusCard
                    Text("在外网使用前，请先让 iPad 和服务器加入同一个 ZeroTier 网络，并填写服务器的 ZeroTier 地址。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 680)
                .padding(28)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Codex iPad")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert(item: $model.trustRequest) { request in
            Alert(
                title: Text("确认服务器身份"),
                message: Text("\(request.profile.host):\(request.profile.port)\n\n\(request.fingerprint)\n\n请与服务器上的 SSH 主机指纹核对。确认后保存，下次连接会自动校验。"),
                primaryButton: .default(Text("信任并连接")) {
                    Task { await model.trustAndConnect(request) }
                },
                secondaryButton: .cancel(Text("取消")) { model.rejectHost() }
            )
        }
        .confirmationDialog("移除当前服务器的主机指纹？", isPresented: $showForgetConfirmation, titleVisibility: .visible) {
            Button("移除主机指纹", role: .destructive) { model.forgetHost() }
        } message: {
            Text("只在已核实服务器更换或重新安装时使用。下次连接会再次要求确认身份。")
        }
        .confirmationDialog("删除这台服务器？", isPresented: $showDeleteServer, titleVisibility: .visible) {
            Button("删除服务器及保存的密码", role: .destructive) { Task { await model.deleteServer() } }
        } message: { Text("只删除 iPad 上的连接设置和钥匙串密码，不删除服务器上的项目或会话。") }
        .onChange(of: model.profile.credentialAccount) { _, _ in
            if !model.isBusy, !model.isConnected, model.trustRequest == nil { model.restorePassword() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 36))
                .foregroundStyle(.indigo)
            Text("连接你的开发服务器")
                .font(.largeTitle.bold())
            Text("通过 SSH 登录，确认服务器已经准备好。")
                .foregroundStyle(.secondary)
        }
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("已保存的服务器", selection: Binding(get: { model.profile.id }, set: { id in
                Task { await model.selectServer(id) }
            })) {
                if !model.savedServers.contains(where: { $0.id == model.profile.id }) {
                    Text("未保存的服务器").tag(model.profile.id)
                }
                ForEach(model.savedServers) { server in
                    Text("\(server.displayName) · \(server.host)").tag(server.id)
                }
            }.disabled(model.isBusy)
            HStack {
                Button("添加服务器", systemImage: "plus") { Task { await model.addServer() } }
                Spacer()
                if model.savedServers.contains(where: { $0.id == model.profile.id }) {
                    Button("删除", role: .destructive) { showDeleteServer = true }
                }
            }.disabled(model.isBusy)
            field("服务器名称") { TextField("例如：开发服务器 / NAS", text: $model.profile.name) }
            field("服务器地址") {
                TextField("IP 或主机名", text: $model.profile.host)
                    .keyboardType(.URL)
                    .accessibilityIdentifier("serverHost")
            }
            HStack(alignment: .top, spacing: 16) {
                field("SSH 用户名") {
                    TextField("用户名", text: $model.profile.username)
                        .textContentType(.username)
                }
                field("端口") {
                    TextField("22", text: $model.profile.port)
                        .keyboardType(.numberPad)
                }
                .frame(width: 100)
            }
            field("SSH 密码") {
                SecureField("SSH 密码", text: $model.password)
                    .textContentType(.password)
                    .onSubmit { Task { await model.connect() } }
            }
            Toggle("记住这台服务器的密码", isOn: Binding(get: { model.profile.rememberPassword }, set: model.setRememberPassword))
                .disabled(model.isBusy || model.isConnected)
            Text(model.profile.rememberPassword ? "密码保存到本机钥匙串，不写入连接配置，也不通过 iCloud 同步。" : "密码只保留在内存中，不保存到设备存储。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("保存服务器设置") { model.saveServer() }
                .disabled(model.isBusy || model.isConnected)
            Button {
                Task {
                    if model.isConnected { await model.disconnect() }
                    else { await model.connect() }
                }
            } label: {
                HStack {
                    if model.isBusy { ProgressView().tint(.white) }
                    Text(model.isBusy ? "连接处理中…" : model.isConnected ? "断开连接" : "连接服务器")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isConnected ? .gray : .indigo)
            .disabled(model.isBusy)
            .accessibilityIdentifier("connectButton")
            Button("移除当前地址的主机指纹", role: .destructive) {
                showForgetConfirmation = true
            }
            .font(.footnote)
            .disabled(model.isBusy || model.isConnected)
        }
        .padding(24)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.status, systemImage: model.isConnected ? "checkmark.circle.fill" : "network")
                .font(.headline)
                .foregroundStyle(model.isConnected ? .green : .primary)
                .accessibilityIdentifier("connectionStatus")
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if !model.serverInfo.isEmpty {
                Text(model.serverInfo)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline.weight(.medium))
            content()
                .padding(12)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        }
        .disabled(model.isBusy || model.isConnected)
    }
}

#Preview { ConnectionView(model: ConnectionModel()) }
