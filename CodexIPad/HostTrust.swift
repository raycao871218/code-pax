import Foundation
import CryptoKit
import Security
import NIOCore
import NIOSSH

enum HostFingerprint {
    static func make(openSSHKey: String) throws -> String {
        let parts = openSSHKey.split(separator: " ")
        guard parts.count >= 2, let bytes = Data(base64Encoded: String(parts[1])) else {
            throw ConnectionError.message("无法读取服务器主机公钥。")
        }
        let digest = Data(SHA256.hash(data: bytes)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }
}

// NIO invokes validation on its event loop. The lock protects the value read by the UI task.
final class PinnedHostValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let expected: String?
    private let lock = NSLock()
    private var observedValue: String?

    init(expected: String?) { self.expected = expected }

    var observed: String? {
        lock.lock()
        defer { lock.unlock() }
        return observedValue
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            let fingerprint = try HostFingerprint.make(openSSHKey: String(openSSHPublicKey: hostKey))
            lock.lock()
            observedValue = fingerprint
            lock.unlock()
            guard expected == fingerprint else {
                validationCompletePromise.fail(ConnectionError.message("服务器指纹尚未确认或已经改变。"))
                return
            }
            validationCompletePromise.succeed(())
        } catch {
            validationCompletePromise.fail(error)
        }
    }
}

struct HostTrustStore {
    private let service = "CodexIPad.SSHHostTrust"

    private func query(_ endpoint: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: endpoint]
    }

    func fingerprint(for endpoint: String) throws -> String? {
        var request = query(endpoint)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let fingerprint = String(data: data, encoding: .utf8) else {
            throw ConnectionError.message("无法读取钥匙串中的服务器指纹（\(status)）。")
        }
        return fingerprint
    }

    func save(_ fingerprint: String, for endpoint: String) throws {
        let data = Data(fingerprint.utf8)
        let status = SecItemUpdate(query(endpoint) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(endpoint)
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(request as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ConnectionError.message("无法保存服务器指纹（\(addStatus)）。")
            }
        } else if status != errSecSuccess {
            throw ConnectionError.message("无法更新服务器指纹（\(status)）。")
        }
    }

    func remove(for endpoint: String) throws {
        let status = SecItemDelete(query(endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConnectionError.message("无法移除服务器指纹（\(status)）。")
        }
    }
}
