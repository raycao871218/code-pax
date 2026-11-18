import Foundation
import SwiftUI
import Citadel
import NIOCore
import NIOSSH
import Network
import CryptoKit

struct HostTrustRequest: Identifiable {
    let id = UUID()
    let profile: ServerProfile
    let fingerprint: String
}

@MainActor
final class ConnectionModel: ObservableObject, TerminalConnection {
    @Published var profile = ServerProfile.load()
    @Published private(set) var savedServers: [ServerProfile] = []
    @Published var password = ""
    @Published private(set) var isBusy = false
    @Published private(set) var isConnected = false
    @Published private(set) var status = "尚未连接"
    @Published private(set) var serverInfo = ""
    @Published private(set) var errorMessage: String?
    @Published var trustRequest: HostTrustRequest?

    @Published private(set) var willReconnect = false
    private var reconnectAccount: String?
    private var sessionPassword: String?
    private var foreground = true
    private var workspaceVisible = false
    var allowsAutomaticReconnect: Bool { foreground && workspaceVisible }
    private var networkAvailable = true
    private var reconnectSchedule = ReconnectSchedule()
    private let pathMonitor = NWPathMonitor()
    private var checkingConnection = false
    private var connectionAttemptID = UUID()
    private var client: SSHClient?
    private var terminalStorage: RemoteTerminalModel?
    private var terminalAccount: String?
    var terminal: RemoteTerminalModel {
        if terminalStorage == nil || terminalAccount != profile.credentialAccount {
            terminalStorage?.stop(disconnected: true)
            terminalStorage = RemoteTerminalModel(connection: self)
            terminalAccount = profile.credentialAccount
        }
        return terminalStorage!
    }

    func withTerminal(dimensions: TerminalDimensions,
                      perform: @MainActor (TTYOutput, TTYStdinWriter) async throws -> Void) async throws {
        guard isConnected, let client, client.isConnected else { throw ConnectionError.message("SSH 已断开，请重新连接服务器。") }
        try await client.withPTY(TerminalPolicy.request(dimensions)) { inbound, outbound in
                try await perform(inbound, outbound)
            }
    }

    private var monitor: Task<Void, Never>?
    private let trustStore = HostTrustStore()
    private let passwordStore = PasswordStore()
    private var connectionGeneration = UUID()

    init() {
        savedServers = ServerProfile.loadServers()
        let selectedID = UserDefaults.standard.string(forKey: "selectedServerID")
        profile = savedServers.first(where: { $0.id == selectedID }) ?? savedServers.first ?? ServerProfile()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-connections") || ProcessInfo.processInfo.arguments.contains("--preview-terminal") {
            var development = ServerProfile(); development.id = "preview-dev"; development.name = "开发服务器"
            var nas = ServerProfile(); nas.id = "preview-nas"; nas.name = "NAS 工作空间"
            savedServers = [development, nas]; profile = development
            return
        }
        #endif
        restorePassword()
        let lastConnected = UserDefaults.standard.string(forKey: "lastConnectedServerID")
        let reconnectEnabled = UserDefaults.standard.object(forKey: "automaticReconnectEnabled") as? Bool ?? true
        if reconnectEnabled, (lastConnected == profile.id || (lastConnected == nil && selectedID == profile.id)),
           profile.rememberPassword, !password.isEmpty, (try? trustStore.fingerprint(for: profile.endpoint)) != nil {
            willReconnect = true
            reconnectAccount = profile.credentialAccount
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                if available && !self.networkAvailable { self.reconnectSchedule.retryNow() }
                self.networkAvailable = available
                if !available, self.willReconnect, !self.isConnected { self.status = "等待网络恢复后自动重连…" }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "codex-ipad.reachability"))
    }

    deinit { pathMonitor.cancel() }

    func maintainConnection() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-workspace") || ProcessInfo.processInfo.arguments.contains("--preview-connections") { return }
        #endif
        defer { pathMonitor.cancel() }
        while !Task.isCancelled {
            if allowsAutomaticReconnect, networkAvailable, willReconnect, reconnectAccount == profile.credentialAccount,
               !isBusy, !isConnected, trustRequest == nil, reconnectSchedule.isDue() {
                await connect(automatically: true)
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    func foregroundChanged(_ active: Bool, workspaceVisible: Bool) {
        foreground = active
        self.workspaceVisible = workspaceVisible
        guard allowsAutomaticReconnect else { return }
        reconnectSchedule.retryNow()
        if isConnected { Task { await self.checkConnection() } }
    }

    private func checkConnection() async {
        guard !checkingConnection, !isBusy, let current = client else { return }
        checkingConnection = true
        defer { checkingConnection = false }
        let generation = connectionGeneration
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            try? await current.close()
        }
        defer { watchdog.cancel() }
        do { _ = try await current.executeCommand(":", maxResponseSize: 1024) }
        catch {
            guard connectionGeneration == generation else { return }
            await closeClient()
            reconnectSchedule.retryNow()
            status = willReconnect ? "连接已失效，正在自动重连…" : "连接已断开"
        }
    }

    private func stopAutomaticReconnect() {
        willReconnect = false; reconnectAccount = nil; sessionPassword = nil
        UserDefaults.standard.set(false, forKey: "automaticReconnectEnabled")
        UserDefaults.standard.removeObject(forKey: "lastConnectedServerID")
    }

    func restorePassword() {
        password = ""
        guard profile.rememberPassword else { return }
        do { password = try passwordStore.read(profile) ?? "" }
        catch { errorMessage = error.localizedDescription }
    }

    private func persistServer(_ target: ServerProfile, secret: String) throws {
        if let previous = savedServers.first(where: { $0.id == target.id }), previous.credentialAccount != target.credentialAccount {
            try passwordStore.remove(previous)
        }
        if target.rememberPassword, !secret.isEmpty { try passwordStore.save(secret, for: target) }
        else if !target.rememberPassword { try passwordStore.remove(target) }
        if let index = savedServers.firstIndex(where: { $0.id == target.id }) { savedServers[index] = target }
        else { savedServers.append(target) }
        ServerProfile.saveServers(savedServers, selectedID: target.id)
    }

    func saveServer() {
        guard !isBusy else { return }
        do {
            let target = try profile.validated()
            try persistServer(target, secret: password)
            profile = target
            errorMessage = nil
            status = "服务器设置已保存"
        } catch { errorMessage = error.localizedDescription }
    }

    func setRememberPassword(_ remember: Bool) {
        profile.rememberPassword = remember
        guard !remember else { return }
        do {
            try passwordStore.remove(profile)
            if var saved = savedServers.first(where: { $0.id == profile.id }) {
                try passwordStore.remove(saved)
                saved.rememberPassword = false
                savedServers[savedServers.firstIndex(where: { $0.id == saved.id })!] = saved
                ServerProfile.saveServers(savedServers, selectedID: profile.id)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func selectServer(_ id: String) async {
        guard !isBusy, let saved = savedServers.first(where: { $0.id == id }) else { return }
        let enteredPassword = profile.credentialAccount == saved.credentialAccount ? password : ""
        await disconnect()
        profile = saved
        ServerProfile.saveServers(savedServers, selectedID: id)
        errorMessage = nil
        serverInfo = ""
        status = "已选择 \(saved.displayName)"
        restorePassword()
        if password.isEmpty { password = enteredPassword }
    }

    func addServer() async {
        guard !isBusy else { return }
        await disconnect()
        var blank = ServerProfile()
        blank.name = ""
        blank.host = ""
        blank.username = ""
        profile = blank
        password = ""
        serverInfo = ""
        errorMessage = nil
        status = "填写新服务器后保存，再点击卡片连接"
    }

    func deleteServer() async {
        guard !isBusy else { return }
        await disconnect()
        do {
            if let saved = savedServers.first(where: { $0.id == profile.id }) { try passwordStore.remove(saved) }
            savedServers.removeAll(where: { $0.id == profile.id })
            ServerProfile.saveServers(savedServers, selectedID: savedServers.first?.id ?? "")
            if let first = savedServers.first { profile = first; restorePassword() }
            else { await addServer() }
            status = "已删除服务器及保存的密码"
        } catch { errorMessage = error.localizedDescription }
    }

    func runCommand(_ command: String, limit: Int = 2_097_152) async throws -> String {
        guard isConnected, let client, client.isConnected else {
            throw ConnectionError.message("SSH 已断开，请重新连接服务器。")
        }
        let generation = connectionGeneration
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            try? await client.close()
        }
        defer { watchdog.cancel() }
        let output = try await client.executeCommand("bash -lc " + RemoteShell.quote(command), maxResponseSize: limit)
        try Task.checkCancellation()
        guard generation == connectionGeneration else { throw ConnectionError.message("服务器连接已切换，请在当前服务器重新操作。") }
        return String(decoding: output.readableBytesView, as: UTF8.self)
    }

    func uploadAttachment(_ data: Data, to path: String,
                          progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        guard isConnected, let client, client.isConnected else { throw ConnectionError.message("SSH 已断开，请重新连接。") }
        let generation = connectionGeneration
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            try? await client.close()
        }
        defer { watchdog.cancel() }
        try await client.withSFTP { sftp in
            try await sftp.withFile(filePath: path, flags: [.write, .create, .forceCreate]) { file in
                let chunkSize = 64 * 1024
                for offset in stride(from: 0, to: data.count, by: chunkSize) {
                    try Task.checkCancellation()
                    let end = min(offset + chunkSize, data.count)
                    try await file.write(ByteBuffer(bytes: data[offset..<end]), at: UInt64(offset))
                    await progress(Double(end) / Double(data.count))
                }
            }
        }
        guard generation == connectionGeneration else { throw ConnectionError.message("服务器已切换，请重新添加附件。") }
    }

    func downloadFile(_ info: RemoteFileInfo, to destination: URL,
                      progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        guard isConnected, let client, client.isConnected else { throw ConnectionError.message("SSH 已断开，请重新连接。") }
        guard (0...100 * 1024 * 1024).contains(info.size) else { throw ConnectionError.message("单个下载文件不能超过 100 MB。") }
        let generation = connectionGeneration
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            try? await client.close()
        }
        defer { watchdog.cancel() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        do {
            let digest: String = try await client.withSFTP { sftp in
                try await sftp.withFile(filePath: info.path, flags: .read) { file in
                    var offset = 0
                    var hash = SHA256()
                    while offset < info.size {
                        try Task.checkCancellation()
                        let buffer = try await file.read(from: UInt64(offset), length: UInt32(min(64 * 1024, info.size - offset)))
                        let data = Data(buffer.readableBytesView)
                        guard !data.isEmpty else { throw ConnectionError.message("下载中断，文件内容不完整。") }
                        try output.write(contentsOf: data)
                        hash.update(data: data)
                        offset += data.count
                        await progress(Double(offset) / Double(max(1, info.size)))
                    }
                    return hash.finalize().map { String(format: "%02x", $0) }.joined()
                }
            }
            guard generation == connectionGeneration else { throw CancellationError() }
            guard digest == info.sha256 else { throw ConnectionError.message("文件在下载时发生变化，请重新打开。") }
            try output.synchronize()
            progress(1)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func runBridge<Value: Decodable>(mode: String, fields: [String: JSONValue] = [:], proxy: String? = nil) async throws -> Value {
        guard ["ensure", "call"].contains(mode) else { throw ConnectionError.message("无效的后台请求。") }
        var command = "python3 \"$HOME/.local/share/codex-ipad/bridge.py\" " + mode
        if mode == "call" {
            command += " " + RemoteShell.quote(try JSONEncoder().encode(fields).base64EncodedString())
        }
        if let proxy, !proxy.isEmpty {
            guard let url = URLComponents(string: proxy), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw ConnectionError.message("代理必须是 http:// 或 https:// 地址，第一版不支持带账号密码的代理。")
            }
            command = "HTTP_PROXY=" + RemoteShell.quote(proxy) + " HTTPS_PROXY=" + RemoteShell.quote(proxy) + " " + command
        }
        let output = try await runCommand(command)
        guard let data = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            throw ConnectionError.message("服务器返回了无效数据。")
        }
        let envelope: BridgeEnvelope<Value>
        do { envelope = try JSONDecoder().decode(BridgeEnvelope<Value>.self, from: data) }
        catch { throw ConnectionError.message("后台返回格式不正确，请检查服务器 shell 启动脚本是否输出了额外内容。") }
        guard envelope.ok, let result = envelope.result else {
            throw ConnectionError.message(envelope.error ?? "后台请求失败。")
        }
        return result
    }

    func connect(automatically: Bool = false) async {
        guard !automatically || allowsAutomaticReconnect else { return }
        guard !isBusy, !isConnected else { return }
        let attempt = UUID()
        connectionAttemptID = attempt
        errorMessage = nil
        serverInfo = ""
        do {
            let target = try profile.validated()
            if password.isEmpty, target.rememberPassword { password = try passwordStore.read(target) ?? "" }
            if password.isEmpty, reconnectAccount == target.credentialAccount { password = sessionPassword ?? "" }
            if automatically, password.isEmpty { stopAutomaticReconnect() }
            guard !password.isEmpty else { throw ConnectionError.message("请输入 SSH 密码。") }
            profile = target
            let expected = try trustStore.fingerprint(for: target.endpoint)
            if automatically, expected == nil {
                stopAutomaticReconnect()
                throw ConnectionError.message("请手动连接并确认服务器身份。")
            }
            let validator = PinnedHostValidator(expected: expected)
            let username = target.username
            let secret = password
            var settings = SSHClientSettings(
                host: target.host,
                port: target.portNumber!,
                authenticationMethod: { .passwordBased(username: username, password: secret) },
                hostKeyValidator: .custom(validator)
            )
            settings.connectTimeout = .seconds(12)
            isBusy = true
            status = automatically ? "正在自动重连 \(target.displayName)…" : "正在连接 \(target.host)…"
            defer { if connectionAttemptID == attempt { isBusy = false } }
            await closeClient()
            guard connectionAttemptID == attempt else { return }
            do {
                let connected = try await SSHClient.connect(to: settings)
                guard connectionAttemptID == attempt else { try? await connected.close(); return }
                client = connected
                status = "登录成功，正在读取系统信息…"
                // Closing the channel bounds the command even if the server never returns EOF.
                let watchdog = Task {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    try? await connected.close()
                }
                defer { watchdog.cancel() }
                let output = try await connected.executeCommand(
                    "printf 'Host: '; hostname; printf 'User: '; id -un; printf 'System: '; uname -sr; printf 'Home: %s\\n' \"$HOME\"",
                    maxResponseSize: 16_384
                )
                guard connectionAttemptID == attempt else { return }
                guard connected.isConnected else {
                    throw ConnectionError.message("读取服务器信息超时或连接已断开，请重试。")
                }
                serverInfo = String(decoding: output.readableBytesView, as: UTF8.self)
                try Task.checkCancellation()
                try persistServer(target, secret: secret)
                reconnectAccount = target.credentialAccount
                sessionPassword = secret
                willReconnect = true
                reconnectSchedule.reset()
                UserDefaults.standard.set(true, forKey: "automaticReconnectEnabled")
                UserDefaults.standard.set(target.id, forKey: "lastConnectedServerID")
                isConnected = true
                status = "已连接 · \(username)@\(target.host):\(target.portNumber!)"
                password = ""
                startMonitoring()
            } catch {
                guard connectionAttemptID == attempt else { return }
                await closeClient()
                if let observed = validator.observed, observed != expected {
                    if expected == nil {
                        status = "等待确认服务器身份"
                        trustRequest = HostTrustRequest(profile: target, fingerprint: observed)
                        return
                    }
                    stopAutomaticReconnect()
                    throw ConnectionError.message("服务器主机指纹已改变，连接已阻止。请先核实服务器身份。\n已保存：\(expected!)\n本次：\(observed)")
                }
                if let authentication = error as? SSHClientError {
                    switch authentication {
                    case .allAuthenticationOptionsFailed, .unsupportedPasswordAuthentication: stopAutomaticReconnect()
                    default: break
                    }
                }
                throw error
            }
        } catch is CancellationError {
            return
        } catch {
            guard connectionAttemptID == attempt else { return }
            if automatically, willReconnect {
                reconnectSchedule.failed()
                status = "连接中断，将自动重试…"
            } else { status = "连接失败" }
            errorMessage = Self.describe(error)
        }
    }

    func trustAndConnect(_ request: HostTrustRequest) async {
        trustRequest = nil
        do {
            try trustStore.save(request.fingerprint, for: request.profile.endpoint)
            profile = request.profile
            await connect()
        } catch { errorMessage = error.localizedDescription }
    }

    func rejectHost() {
        stopAutomaticReconnect()
        trustRequest = nil
        status = "已取消连接"
    }

    func disconnect() async {
        connectionAttemptID = UUID()
        stopAutomaticReconnect()
        isBusy = true
        await closeClient()
        status = "已断开"
        isBusy = false
    }

    func forgetHost() {
        stopAutomaticReconnect()
        do {
            let target = try profile.validated()
            try trustStore.remove(for: target.endpoint)
            status = "已移除该地址的主机指纹，下次连接需重新确认"
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func closeClient() async {
        terminalStorage?.stop(disconnected: true)
        connectionGeneration = UUID()
        monitor?.cancel()
        monitor = nil
        let oldClient = client
        client = nil
        isConnected = false
        try? await oldClient?.close()
    }

    private func startMonitoring() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                if self.client?.isConnected != true {
                    await self.closeClient()
                    self.reconnectSchedule.retryNow()
                    self.status = self.willReconnect ? "连接已断开，等待自动重连…" : "连接已断开，请重新连接"
                    return
                }
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let known = error as? ConnectionError { return known.localizedDescription }
        if let sshError = error as? SSHClientError {
            switch sshError {
            case .unsupportedPasswordAuthentication:
                return "服务器未启用密码登录。第一版仅支持 SSH 密码认证，不支持私钥或交互式认证。"
            case .allAuthenticationOptionsFailed:
                return "SSH 认证失败，请检查用户名和密码。"
            default: break
            }
        }
        return "无法完成 SSH 连接。请检查地址、端口、密码及 ZeroTier 网络。\n\(String(describing: error))"
    }
}
