import Foundation

struct ServerProfile: Codable, Equatable {
    var host = "10.10.0.172"
    var port = "22"
    var username = "caobowen"

    var endpoint: String { "[\(host.lowercased())]:\(portNumber ?? 22)" }
    var portNumber: Int? {
        guard let value = Int(port), (1...65535).contains(value) else { return nil }
        return value
    }

    func validated() throws -> ServerProfile {
        var profile = self
        profile.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.port = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.host.isEmpty,
              !profile.host.contains(where: { $0.isWhitespace }),
              !profile.host.contains("/"), !profile.host.contains("://") else {
            throw ConnectionError.message("请输入 IP 或主机名，不要带 ssh://、端口或路径。IPv6 地址不加方括号。")
        }
        guard profile.portNumber != nil else {
            throw ConnectionError.message("端口必须是 1～65535 之间的整数。")
        }
        guard !profile.username.isEmpty else {
            throw ConnectionError.message("请输入 SSH 用户名。")
        }
        return profile
    }

    static func load() -> ServerProfile {
        guard let data = UserDefaults.standard.data(forKey: "serverProfile"),
              let profile = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return profile
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "serverProfile")
        }
    }
}

enum ConnectionError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
