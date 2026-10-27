import SwiftUI

struct ConnectionView: View {
    @Environment(\.interfaceTheme) private var theme
    @ObservedObject var model: ConnectionModel
    @State private var showForgetConfirmation = false
    @State private var showDeleteServer = false
    @State private var deleteServerID: String?

    var onOpenWorkspace: () -> Void = {}
    @State private var showCustomization = false
    @State private var showEditor = false
    @State private var showPasswordPrompt = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 16) {
                        BrandMark().frame(width: theme.isCompanion ? 112 : 88, height: theme.isCompanion ? 112 : 88)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Code Pax").font(.largeTitle.bold()).fontDesign(theme.isCompanion ? .rounded : .default)
                            Text("选择一台服务器，继续工作。").foregroundStyle(.secondary)
                        }
                    }.padding(theme.isCompanion ? 20 : 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.isCompanion ? theme.card : .clear, in: RoundedRectangle(cornerRadius: 28))
                        .overlay(RoundedRectangle(cornerRadius: 28).stroke(theme.isCompanion ? theme.border : .clear, lineWidth: 1))
                        .padding(.bottom, 12)
                    if model.savedServers.isEmpty {
                        connectionForm
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                            ForEach(model.savedServers) { server in serverCard(server) }
                        }
                        Button { Task { await model.addServer(); showEditor = true } } label: {
                            Label("添加服务器", systemImage: "plus").frame(maxWidth: .infinity).padding(18)
                        }.buttonStyle(.bordered).disabled(model.isBusy)
                    }
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).textSelection(.enabled)
                    }
                    if model.isBusy { ProgressView(model.status).frame(maxWidth: .infinity) }
                }.frame(maxWidth: 760).padding(28).frame(maxWidth: .infinity)
            }.background(theme.isCompanion ? theme.canvas : Color(.systemGroupedBackground))
                .navigationTitle("连接").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu { SkinPicker(); PalettePicker(); Divider(); AppearancePicker(); Divider(); Button("配色与自定义头像", systemImage: "paintpalette") { showCustomization = true } } label: { Image(systemName: "circle.lefthalf.filled") }
                            .accessibilityLabel("外观与皮肤")
                    }
                    if model.isConnected {
                        ToolbarItem(placement: .topBarTrailing) { Button("返回工作区", action: onOpenWorkspace) }
                    }
                }
        }
        .appAppearance()
        .sheet(isPresented: $showCustomization) {
            NavigationStack {
                AppearanceCustomizationView().toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { showCustomization = false } }
                }
            }.appAppearance()
        }
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 20) { connectionForm; statusCard }.padding(24)
                }.background(theme.isCompanion ? theme.canvas : Color(.systemGroupedBackground))
                    .navigationTitle("服务器设置").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showEditor = false } } }
            }.appAppearance()
        }
        .sheet(isPresented: $showPasswordPrompt) {
            NavigationStack {
                Form {
                    Section(model.profile.displayName) {
                        SecureField("SSH 密码", text: $model.password).textContentType(.password)
                        Toggle("记住密码", isOn: Binding(get: { model.profile.rememberPassword }, set: model.setRememberPassword))
                        Button("连接") {
                            showPasswordPrompt = false
                            Task { await model.connect() }
                        }.disabled(model.password.isEmpty || model.isBusy)
                    }
                }.navigationTitle("输入密码").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showPasswordPrompt = false } } }
            }.appAppearance().presentationDetents([.medium])
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
            Button("删除服务器及保存的密码", role: .destructive) {
                Task {
                    if let id = deleteServerID { await model.selectServer(id) }
                    await model.deleteServer()
                }
            }
        } message: { Text("只删除 iPad 上的连接设置和钥匙串密码，不删除服务器上的项目或会话。") }
        .onChange(of: model.profile.credentialAccount) { _, _ in
            if !model.isBusy, !model.isConnected, model.trustRequest == nil { model.restorePassword() }
        }
    }

    private func serverCard(_ server: ServerProfile) -> some View {
        let active = model.isConnected && model.profile.id == server.id
        return HStack(spacing: 12) {
            Button {
                Task {
                    if active { onOpenWorkspace(); return }
                    await model.selectServer(server.id)
                    if model.password.isEmpty { showPasswordPrompt = true }
                    else { await model.connect() }
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "server.rack").font(.title2).frame(width: 44, height: 48)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(server.displayName).font(.headline).foregroundStyle(.primary).lineLimit(1)
                        Label(active ? "已连接 · 继续工作" : "点击连接", systemImage: active ? "circle.fill" : "arrow.up.right")
                            .font(.caption).foregroundStyle(active ? Color.green : Color.secondary)
                    }
                    Spacer(minLength: 4)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.isBusy)
            Menu {
                Button("编辑连接", systemImage: "pencil") {
                    Task { await model.selectServer(server.id); showEditor = true }
                }
                Button("删除", systemImage: "trash", role: .destructive) {
                    deleteServerID = server.id; showDeleteServer = true
                }
                if active { Button("断开连接") { Task { await model.disconnect() } } }
            } label: { Image(systemName: "ellipsis").frame(width: 30, height: 40) }.disabled(model.isBusy)
        }.padding(20).background(theme.isCompanion ? theme.card : Color(.systemBackground), in: RoundedRectangle(cornerRadius: theme.isCompanion ? 24 : 20))
            .overlay(RoundedRectangle(cornerRadius: theme.isCompanion ? 24 : 20).stroke(theme.isCompanion ? theme.border : .clear, lineWidth: 1))
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 18) {
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
            Button("保存服务器设置") { model.saveServer(); if model.errorMessage == nil { showEditor = false } }
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
            .tint(model.isConnected ? .gray : theme.actionFill)
            .disabled(model.isBusy)
            .accessibilityIdentifier("connectButton")
            Button("移除当前地址的主机指纹", role: .destructive) {
                showForgetConfirmation = true
            }
            .font(.footnote)
            .disabled(model.isBusy || model.isConnected)
        }
        .padding(24)
        .background(theme.isCompanion ? theme.card : Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20))
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
                .background(theme.isCompanion ? theme.input : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        }
        .disabled(model.isBusy || model.isConnected)
    }
}

#Preview { ConnectionView(model: ConnectionModel()) }
