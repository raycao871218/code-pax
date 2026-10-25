import Foundation
import SwiftUI
import Citadel

struct HostTrustRequest: Identifiable {
    let id = UUID()
    let profile: ServerProfile
    let fingerprint: String
}

@MainActor
final class ConnectionModel: ObservableObject {
    @Published var profile = ServerProfile.load()
    @Published var password = ""
    @Published private(set) var isBusy = false
    @Published private(set) var isConnected = false
    @Published private(set) var status = "尚未连接"
    @Published private(set) var serverInfo = ""
    @Published private(set) var errorMessage: String?
    @Published var trustRequest: HostTrustRequest?

    private var client: SSHClient?
    private var monitor: Task<Void, Never>?
    private let trustStore = HostTrustStore()

    func runCommand(_ command: String, limit: Int = 2_097_152) async throws -> String {
        guard isConnected, let client, client.isConnected else {
            throw ConnectionError.message("SSH 已断开，请重新连接服务器。")
        }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            try? await client.close()
        }
        defer { watchdog.cancel() }
        let output = try await client.executeCommand("bash -lc " + RemoteShell.quote(command), maxResponseSize: limit)
        return String(decoding: output.readableBytesView, as: UTF8.self)
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

    func connect() async {
        guard !isBusy, !isConnected else { return }
        errorMessage = nil
        serverInfo = ""
        do {
            let target = try profile.validated()
            guard !password.isEmpty else { throw ConnectionError.message("请输入 SSH 密码。") }
            profile = target
            profile.save()
            let expected = try trustStore.fingerprint(for: target.endpoint)
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
            status = "正在连接 \(target.host)…"
            defer { isBusy = false }
            await closeClient()
            do {
                let connected = try await SSHClient.connect(to: settings)
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
                guard connected.isConnected else {
                    throw ConnectionError.message("读取服务器信息超时或连接已断开，请重试。")
                }
                serverInfo = String(decoding: output.readableBytesView, as: UTF8.self)
                isConnected = true
                status = "已连接 · \(username)@\(target.host):\(target.portNumber!)"
                password = ""
                startMonitoring()
            } catch {
                await closeClient()
                if let observed = validator.observed, observed != expected {
                    if expected == nil {
                        status = "等待确认服务器身份"
                        trustRequest = HostTrustRequest(profile: target, fingerprint: observed)
                        return
                    }
                    throw ConnectionError.message("服务器主机指纹已改变，连接已阻止。请先核实服务器身份。\n已保存：\(expected!)\n本次：\(observed)")
                }
                throw error
            }
        } catch {
            status = "连接失败"
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
        trustRequest = nil
        status = "已取消连接"
    }

    func disconnect() async {
        guard !isBusy else { return }
        isBusy = true
        await closeClient()
        status = "已断开"
        isBusy = false
    }

    func forgetHost() {
        do {
            let target = try profile.validated()
            try trustStore.remove(for: target.endpoint)
            status = "已移除该地址的主机指纹，下次连接需重新确认"
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func closeClient() async {
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
                    self.status = "连接已断开，请重新连接"
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
