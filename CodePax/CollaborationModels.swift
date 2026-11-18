import Foundation
import Security

struct CollaborationTask: Decodable, Identifiable {
    let id: String
    let title: String
    let role: String
    let status: String
    let worktree: String
    let branch: String
    let sessionId: String?
    let result: String
    let error: String?
    let snapshotCommit: String?
    let integrated: Bool
    let attempt: Int
    var isRunning: Bool { ["starting", "inProgress", "waiting", "unknown", "collecting"].contains(status) }
    var isRetryable: Bool { ["failed", "interrupted", "cancelled"].contains(status) }
}

struct CollaborationMessage: Decodable, Identifiable {
    let id: String
    let from: String
    let to: String
    let text: String
    let createdAt: Double
}

struct CollaborationRun: Decodable, Identifiable {
    let id: String
    let goal: String
    let cwd: String
    let sourceBranch: String
    let baseCommit: String
    let status: String
    let maxWorkers: Int
    let tasks: [CollaborationTask]
    let messages: [CollaborationMessage]
    let error: String?
    let createdAt: Double
    let updatedAt: Double
    let appliedCommit: String?
    var coordinator: CollaborationTask? { tasks.first { $0.role == "coordinator" } }
    var workers: [CollaborationTask] { tasks.filter { $0.role == "worker" } }
    var isActive: Bool { ["running", "cancelling"].contains(status) }
    var canApply: Bool { status == "completed" && coordinator?.snapshotCommit != nil && appliedCommit == nil }
    func memberTitle(_ id: String) -> String {
        if id == "all" { return "所有成员" }
        if id == "user" { return "你" }
        return tasks.first { $0.id == id }?.title ?? id
    }
    func canRetry(_ task: CollaborationTask) -> Bool {
        task.isRetryable && (task.role == "coordinator" || coordinator?.sessionId == nil)
    }
}

struct CollaborationCatalog: Decodable { let runs: [CollaborationRun] }
struct CollaborationDiff: Decodable { let text: String; let truncated: Bool }

struct CollaborationTaskDraft: Identifiable {
    let id = UUID()
    var title = ""
    var prompt = ""
    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 100 &&
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.count <= 8000
    }
}

func collaborationStatus(_ status: String) -> String {
    switch status {
    case "queued": return "排队中"
    case "running", "inProgress", "starting": return "执行中"
    case "waiting": return "等待审批或回答"
    case "collecting": return "保存成果中"
    case "unknown": return "结果待确认"
    case "cancelling": return "正在停止"
    case "cancelled": return "已取消"
    case "completed": return "已完成"
    case "interrupted": return "已中断"
    case "failed": return "执行失败"
    default: return status
    }
}

/// Pending team prompts and messages may contain private project information.
struct CollaborationPendingStore {
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "CodePax.CollaborationOperations",
         kSecAttrAccount as String: key]
    }
    func read(_ key: String) throws -> Data? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw ConnectionError.message("无法读取协作操作记录（\(status)），请解锁设备后重试。")
        }
        return data
    }
    func save(_ data: Data, key: String) throws {
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(key)
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(request as CFDictionary, nil)
            guard added == errSecSuccess else { throw ConnectionError.message("无法保存协作操作记录（\(added)）。") }
        } else if status != errSecSuccess {
            throw ConnectionError.message("无法更新协作操作记录（\(status)）。")
        }
    }
    func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConnectionError.message("无法清除协作操作记录（\(status)）。")
        }
    }
}
