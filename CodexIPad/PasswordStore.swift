import Foundation
import Security

struct PasswordStore {
    private func query(_ profile: ServerProfile) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "CodexIPad.SSHPasswords",
         kSecAttrAccount as String: profile.credentialAccount]
    }

    func read(_ profile: ServerProfile) throws -> String? {
        var request = query(profile)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw ConnectionError.message("无法读取已保存密码（\(status)），请手动输入。")
        }
        return password
    }

    func save(_ password: String, for profile: ServerProfile) throws {
        let attributes = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query(profile) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(profile)
            request[kSecValueData as String] = Data(password.utf8)
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let result = SecItemAdd(request as CFDictionary, nil)
            guard result == errSecSuccess else { throw ConnectionError.message("无法将密码保存到钥匙串（\(result)）。") }
        } else if status != errSecSuccess {
            throw ConnectionError.message("无法更新钥匙串密码（\(status)）。")
        }
    }

    func remove(_ profile: ServerProfile) throws {
        let status = SecItemDelete(query(profile) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConnectionError.message("无法删除钥匙串密码（\(status)）。")
        }
    }
}

// Terminal input may contain login secrets. Keep unacknowledged operations in the device keychain.
struct PendingOperationStore {
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "CodexIPad.PendingOperations", kSecAttrAccount as String: key]
    }

    func read(_ key: String) throws -> Data? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ConnectionError.message("无法读取待确认操作（\(status)），请解锁设备后重试。")
        }
        return data
    }

    func save(_ data: Data, for key: String) throws {
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(key)
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let result = SecItemAdd(request as CFDictionary, nil)
            guard result == errSecSuccess else { throw ConnectionError.message("无法保存待确认操作（\(result)）。") }
        } else if status != errSecSuccess {
            throw ConnectionError.message("无法更新待确认操作（\(status)）。")
        }
    }

    func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConnectionError.message("无法清除待确认操作（\(status)）。")
        }
    }
}
