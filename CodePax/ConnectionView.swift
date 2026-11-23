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
    @State private var showHelp = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    homeHeader
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 30) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("选择服务器").font(.largeTitle.weight(.semibold))
                                Text("连接开发环境，继续工作。").foregroundStyle(.secondary)
                            }
                            HStack {
                                Text("已保存的服务器").font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                                Button { addServer() } label: { Label("添加服务器", systemImage: "plus") }
                                    .font(.subheadline).disabled(model.isBusy)
                                    .accessibilityIdentifier("addServerButton")
                            }.padding(.top, 8)
                            if model.savedServers.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("还没有服务器").font(.headline)
                                    Text("添加 SSH 连接，开始你的第一个工作空间。")
                                        .font(.callout).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 30)
                            } else {
                                LazyVStack(spacing: 0) {
                                    ForEach(model.savedServers) { server in
                                        serverRow(server)
                                        if server.id != model.savedServers.last?.id { Divider() }
                                    }
                                }
                            }
                            if let error = model.errorMessage {
                                AppLabel(error, systemImage: "exclamationmark.circle").font(.callout)
                                    .foregroundStyle(.red).textSelection(.enabled)
                            }
                            if model.isBusy { ProgressView { AppText(model.status) }.font(.callout) }
                            Button { showHelp = true } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "terminal")
                                    Text("如何连接服务器")
                                    Image(systemName: "chevron.right").font(.caption)
                                }.font(.subheadline)
                            }.tint(.secondary)
                        }.frame(maxWidth: 800, alignment: .leading).padding(.horizontal, 28)
                            .padding(.top, min(92, max(40, geometry.size.height * 0.12))).padding(.bottom, 32)
                            .frame(maxWidth: .infinity)
                    }
                    Text("Code Pax · SSH 工作空间").font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 18)
                }.background(theme.canvas)
            }.toolbar(.hidden, for: .navigationBar)
        }
        .appAppearance()
        .sheet(isPresented: $showHelp) { connectionHelp }
        .sheet(isPresented: $showCustomization) {
            NavigationStack {
                AppearanceCustomizationView().toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { showCustomization = false } }
                }
            }.toolbar(.visible, for: .navigationBar).appAppearance()
        }
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 20) { connectionForm; statusCard }.padding(24)
                }.background(theme.isCompanion ? theme.canvas : Color(.systemGroupedBackground))
                    .navigationTitle("服务器设置").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showEditor = false } } }
            }.toolbar(.visible, for: .navigationBar).appAppearance()
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

    private var homeHeader: some View {
        HStack(spacing: 18) {
            Text("Code Pax").font(.title3.weight(.semibold))
            Spacer()
            if model.isConnected { Button("返回工作区", action: onOpenWorkspace).font(.subheadline) }
            Menu {
                LanguagePicker(); SkinPicker(); PalettePicker(); AppearancePicker()
                Divider()
                Button("配色与自定义头像", systemImage: "paintpalette") { showCustomization = true }
            } label: {
                Image(systemName: "gearshape").font(.title3).frame(width: 36, height: 36)
            }.tint(.primary).accessibilityLabel("外观与设置")
        }.padding(.horizontal, 28).frame(minHeight: 68)
    }

    private func addServer() {
        Task { await model.addServer(); showEditor = true }
    }

    private func connect(_ server: ServerProfile) {
        Task {
            if model.isConnected && model.profile.id == server.id { onOpenWorkspace(); return }
            await model.selectServer(server.id)
            if model.password.isEmpty { showPasswordPrompt = true }
            else { await model.connect() }
        }
    }

    private func serverRow(_ server: ServerProfile) -> some View {
        let active = model.isConnected && model.profile.id == server.id
        let selected = model.profile.id == server.id
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                serverIdentity(server)
                Spacer(minLength: 12)
                serverStatus(active: active, selected: selected)
                connectButton(server, active: active, prominent: selected)
                serverMenu(server, active: active)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack { serverIdentity(server); Spacer(minLength: 0); serverMenu(server, active: active) }
                HStack {
                    serverStatus(active: active, selected: selected)
                    Spacer()
                    connectButton(server, active: active, prominent: selected)
                }.padding(.leading, 42)
            }
        }.padding(.horizontal, 16).padding(.vertical, 18)
            .background(selected ? Color.primary.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 10))
    }

    private func serverIdentity(_ server: ServerProfile) -> some View {
        Button { connect(server) } label: {
            HStack(spacing: 14) {
                Image(systemName: "server.rack").font(.title2).frame(width: 28).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(server.displayName).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Text(server.username + "@" + server.host + " · " + server.port)
                        .font(.system(.subheadline, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.isBusy)
    }

    private func serverStatus(active: Bool, selected: Bool) -> some View {
        HStack(spacing: 7) {
            Circle().fill(active ? Color.green : Color.secondary.opacity(0.6)).frame(width: 7, height: 7)
            AppText(active ? "已连接" : selected && model.isBusy ? "连接中" : "未连接")
        }.font(.subheadline).foregroundStyle(.secondary).fixedSize()
    }

    @ViewBuilder
    private func connectButton(_ server: ServerProfile, active: Bool, prominent: Bool) -> some View {
        if prominent {
            Button(active ? "继续" : "连接") { connect(server) }
                .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 6)).tint(theme.actionFill)
                .disabled(model.isBusy).accessibilityIdentifier("connectServer." + server.id)
        } else {
            Button(active ? "继续" : "连接") { connect(server) }
                .buttonStyle(.plain).tint(.primary).padding(.horizontal, 16).padding(.vertical, 6)
                .background(theme.canvas, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.border, lineWidth: 1))
                .disabled(model.isBusy).accessibilityIdentifier("connectServer." + server.id)
        }
    }

    private func serverMenu(_ server: ServerProfile, active: Bool) -> some View {
        Menu {
            Button("编辑连接", systemImage: "pencil") { Task { await model.selectServer(server.id); showEditor = true } }
            Button("删除", systemImage: "trash", role: .destructive) {
                deleteServerID = server.id; showDeleteServer = true
            }
            if active { Button("断开连接") { Task { await model.disconnect() } } }
        } label: { Image(systemName: "ellipsis").frame(width: 32, height: 36) }
            .tint(.primary).disabled(model.isBusy).accessibilityLabel("管理 " + server.displayName)
    }

    private var connectionHelp: some View {
        NavigationStack {
            Form {
                Section("1 · 准备服务器") {
                    Text("开启服务器的 SSH 服务，确认 iPad 能访问该地址。准备 SSH 用户名、密码和端口，常见端口是 22。")
                }
                Section("2 · 保存连接") {
                    Text("点击“添加服务器”，填写名称、地址、用户名、端口和密码后保存。可选择将密码保存在本机钥匙串。")
                }
                Section("3 · 连接并确认身份") {
                    Text("点击服务器的“连接”按钮。首次连接时，请核对服务器的 SSH 主机指纹，再确认信任。连接成功后进入工作区。")
                }
                Section("工作区") {
                    Text("服务器上的 CLI 需要单独安装和登录。你可以在 Agents 页面管理启动配置。")
                }
            }.navigationTitle("如何连接服务器").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showHelp = false } } }
        }.toolbar(.visible, for: .navigationBar).appAppearance()
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
                    .onSubmit { saveServer() }
            }
            Toggle("记住这台服务器的密码", isOn: Binding(get: { model.profile.rememberPassword }, set: model.setRememberPassword))
                .disabled(model.isBusy || model.isConnected)
            AppText(model.profile.rememberPassword ? "密码保存到本机钥匙串，不写入连接配置，也不通过 iCloud 同步。" : "密码只保留在内存中，不保存到设备存储。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: saveServer) {
                Text("保存服务器设置").fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.actionFill)
            .disabled(model.isBusy || model.isConnected)
            .accessibilityIdentifier("saveServerButton")
            Text("保存后，点击服务器卡片连接。").font(.caption).foregroundStyle(.secondary)
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

    private func saveServer() {
        guard !model.isBusy, !model.isConnected else { return }
        model.saveServer()
        if model.errorMessage == nil { showEditor = false }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppLabel(model.status, systemImage: model.isConnected ? "checkmark.circle.fill" : "network")
                .font(.headline)
                .foregroundStyle(model.isConnected ? .green : .primary)
                .accessibilityIdentifier("connectionStatus")
            if let error = model.errorMessage {
                AppText(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
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
            AppText(label).font(.subheadline.weight(.medium))
            content()
                .padding(12)
                .background(theme.isCompanion ? theme.input : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        }
        .disabled(model.isBusy || model.isConnected)
    }
}

#Preview { ConnectionView(model: ConnectionModel()) }
