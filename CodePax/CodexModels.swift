import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode([String: JSONValue].self) { self = .object(item) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }

    subscript(_ key: String) -> JSONValue {
        if case .object(let fields) = self { return fields[key] ?? .null }
        return .null
    }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var boolean: Bool { if case .bool(let value) = self { return value }; return false }
    var array: [JSONValue] { if case .array(let value) = self { return value }; return [] }
    var pretty: String {
        guard let data = try? JSONEncoder.pretty.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

struct BridgeEnvelope<Value: Decodable>: Decodable {
    let ok: Bool
    let result: Value?
    let error: String?
}

struct BridgeStatus: Decodable {
    let `protocol`: Int
    let ready: Bool
    let root: String
    let authenticated: Bool
    let accountType: String
    let version: String?
    let upgradePending: Bool?
    let capabilities: [String]?
}

struct PendingSendStatus: Decodable {
    let state: String
    var isResolved: Bool { state == "accepted" || state == "rejected" }
}

enum ComposerState: Equatable {
    case sending, running, completed, ready
    static func resolve(status: String, draft: String, sending: Bool, pending: Bool) -> Self {
        if sending { return .sending }
        if ["inProgress", "starting", "waiting"].contains(status) { return .running }
        if status == "completed", !pending, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .completed }
        return .ready
    }
}

struct TokenBreakdown: Decodable {
    let totalTokens: Int
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
}
struct ThreadTokenUsage: Decodable {
    let total: TokenBreakdown
    let last: TokenBreakdown
    let modelContextWindow: Int?
    var contextFraction: Double? {
        guard let size = modelContextWindow, size > 0 else { return nil }
        return min(1, max(0, Double(last.totalTokens) / Double(size)))
    }
}
enum UsageSeverity: Equatable { case normal, warning, critical }

struct RateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
    var severity: UsageSeverity {
        if remainingPercent < 10 { return .critical }
        if remainingPercent < 20 { return .warning }
        return .normal
    }
    var title: String {
        guard let minutes = windowDurationMins else { return "额度窗口" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天额度" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时额度" }
        return "\(minutes) 分钟额度"
    }
}
struct RateLimitBucket: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let planType: String?
}
struct AccountUsage: Decodable {
    let rateLimits: RateLimitBucket?
    let rateLimitsByLimitId: [String: RateLimitBucket]?
    let threadUsage: ThreadTokenUsage?
    let updatedAt: Double?
    let error: String?
    var buckets: [(id: String, value: RateLimitBucket)] {
        if let all = rateLimitsByLimitId, !all.isEmpty { return all.keys.sorted().map { ($0, all[$0]!) } }
        if let rateLimits { return [(rateLimits.limitId ?? "codex", rateLimits)] }
        return []
    }
    var severity: UsageSeverity? {
        buckets.flatMap { [$0.value.primary, $0.value.secondary].compactMap { $0 } }
            .min(by: { $0.remainingPercent < $1.remainingPercent })?.severity
    }
}

/// One cadence shared by automatic checks, opening the panel, and manual refresh.
struct UsageRefreshSchedule {
    private(set) var lastAttempt: Date?
    func isDue(at now: Date) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= 60
    }
    mutating func recordAttempt(at now: Date) { lastAttempt = now }
}

struct DirectoryEntry: Decodable, Identifiable { let id: String; let name: String }
struct DirectoryListing: Decodable {
    let path: String
    let root: String
    let parent: String?
    let directories: [DirectoryEntry]
}

struct CodexSessionSummary: Decodable, Identifiable {
    let id: String
    let title: String
    let cwd: String
    let status: String
    let updatedAt: Double
    let origin: String?
    let model: String?
    var completedTurnId: String? = nil
    var pinned: Bool? = nil
    var archived: Bool? = nil
}

struct CodexMessage: Decodable, Identifiable {
    let id: String
    let kind: String
    let text: String
    let status: String
    var attachments: [UploadedAttachment]? = nil
    var contentLength: Int? = nil
    var textTruncated: Bool? = nil
    var userMessageText: String {
        guard kind == "userMessage", let attachments, !attachments.isEmpty else { return text }
        for separator in ["\n\n", "\n"] {
            let suffix = attachments.map { "📎 " + $0.name }.joined(separator: separator)
            if text.hasSuffix(suffix) { return String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return text
    }
    var isActivity: Bool { !["userMessage", "agentMessage", "plan"].contains(kind) }
    var activityTitle: String {
        switch kind {
        case "commandExecution": return text.components(separatedBy: .newlines).first ?? "运行命令"
        case "fileChange": return "更新文件"
        case "webSearch": return "搜索网页"
        case "mcpToolCall", "dynamicToolCall": return "调用工具"
        default: return "执行操作"
        }
    }
}

struct LocalSubmission: Codable, Identifiable {
    let operationID: String
    let sessionID: String
    let text: String
    var state: String
    var attachments: [UploadedAttachment]? = nil
    var request: [String: JSONValue]? = nil
    var id: String { "local:" + operationID }
    var message: CodexMessage { CodexMessage(id: id, kind: "userMessage", text: text, status: state, attachments: attachments) }
}

enum MessageTimeline {
    static func merge(remote: [CodexMessage], local: [LocalSubmission], sessionID: String) -> [CodexMessage] {
        let known = Set(remote.map(\.id))
        return remote + local.filter { $0.sessionID == sessionID && !known.contains($0.id) }.map(\.message)
    }
}

struct ConversationEntry: Identifiable {
    var messages: [CodexMessage]
    var id: String { messages[0].id }
    var isActivity: Bool { messages[0].isActivity }
    var isRunning: Bool { messages.contains { ["inProgress", "starting"].contains($0.status) } }
    var summary: String {
        let commands = messages.filter { $0.kind == "commandExecution" }.count
        let files = messages.filter { $0.kind == "fileChange" }.count
        var parts: [String] = []
        if commands > 0 { parts.append("\(commands) 条命令") }
        if files > 0 { parts.append("\(files) 次文件更新") }
        let other = messages.count - commands - files
        if other > 0 { parts.append("\(other) 项工具操作") }
        return (isRunning ? "正在执行 · " : "已执行 · ") + parts.joined(separator: " · ")
    }
    static func group(_ messages: [CodexMessage]) -> [Self] {
        var result: [Self] = []
        for message in messages {
            if message.isActivity, result.last?.isActivity == true {
                result[result.count - 1].messages.append(message)
            } else { result.append(Self(messages: [message])) }
        }
        return result
    }
}

enum AccessMode: String, CaseIterable, Identifiable {
    case standard = "default", fullAccess
    var id: String { rawValue }
    var title: String { self == .fullAccess ? "Full Access" : "默认权限" }
    var symbol: String { self == .fullAccess ? "lock.open" : "lock.shield" }
}

struct CodexApproval: Decodable, Identifiable {
    let id: String
    let method: String
    let params: JSONValue
    var questions: [JSONValue] { params["questions"].array }
    var isQuestion: Bool { method == "item/tool/requestUserInput" }
    var isPermission: Bool { method == "item/permissions/requestApproval" }
    var decisions: [String] {
        let available = params["availableDecisions"].array.compactMap(\.string)
        return available.isEmpty ? ["accept", "decline", "cancel"] : available
    }
}

struct CodexSession: Decodable, Identifiable {
    let id: String
    let title: String
    let cwd: String
    let status: String
    let turnId: String?
    let messages: [CodexMessage]
    let approvals: [CodexApproval]
    let diff: String
    let error: String?
    let historyTruncated: Bool
    let readOnly: Bool?
    var writerOccupied: Bool? = nil
    let model: String?
    let effort: String?
    let accessMode: String?
    var completedTurnId: String? = nil
    var diffLength: Int? = nil
    var diffTruncated: Bool? = nil
    var tokenUsage: ThreadTokenUsage? = nil
    var isRunning: Bool { ["inProgress", "waiting", "starting"].contains(status) }
}

struct CodexSnapshot: Decodable {
    let sessions: [CodexSessionSummary]
    let selected: CodexSession?
    let ready: Bool
    let projects: [CodexProject]?
}

struct CodexProject: Decodable, Identifiable { let id: String; let title: String }
struct CodexCatalogPage: Decodable { let nextCursor: String?; let imported: Int; let skipped: Int }
struct CodexHistoryPage: Decodable { let messages: [CodexMessage]; let nextCursor: String? }
struct CodexEffort: Decodable, Identifiable {
    let reasoningEffort: String
    let description: String?
    var id: String { reasoningEffort }
}
struct CodexModel: Decodable, Identifiable {
    let model: String
    let displayName: String
    let defaultReasoningEffort: String?
    let supportedReasoningEfforts: [CodexEffort]
    let isDefault: Bool
    var id: String { model }
}
struct CodexModelCatalog: Decodable { let models: [CodexModel] }

enum RemoteShell {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

func sessionStatus(_ value: String) -> String {
    switch value {
    case "inProgress", "starting": return "运行中"
    case "waiting": return "等待你处理"
    case "completed": return "已完成"
    case "failed": return "执行失败"
    case "interrupted": return "已中断"
    case "unknown": return "结果待确认"
    case "externalActive": return "CLI 中运行 · 仅查看"
    case "externalOccupied": return "其他客户端占用 · 仅查看"
    default: return "就绪"
    }
}

/// Persist completion receipts by turn, so metadata updates cannot create unread badges.
struct CompletionReads: Codable {
    struct Receipt: Codable {
        var latest: String?
        var read: String?
    }
    private var receipts: [String: Receipt] = [:]

    func isUnread(_ id: String) -> Bool {
        guard let receipt = receipts[id], let latest = receipt.latest else { return false }
        return latest != receipt.read
    }

    mutating func observe(id: String, completedTurnID: String?) {
        guard var receipt = receipts[id] else {
            // Existing history is the baseline on this device's first observation.
            receipts[id] = Receipt(latest: completedTurnID, read: completedTurnID)
            return
        }
        if let completedTurnID { receipt.latest = completedTurnID }
        receipts[id] = receipt
    }

    mutating func markRead(id: String, completedTurnID: String?) {
        guard let completedTurnID, var receipt = receipts[id], receipt.latest == completedTurnID else { return }
        receipt.read = completedTurnID
        receipts[id] = receipt
    }
}

struct MessageBodyPage: Decodable {
    let text: String
    let nextOffset: Int?
    let contentLength: Int
    let revision: String
}

enum SessionListPolicy {
    static func visible(_ sessions: [CodexSessionSummary]) -> [CodexSessionSummary] {
        sessions.filter { $0.archived != true }.sorted {
            if ($0.pinned == true) != ($1.pinned == true) { return $0.pinned == true }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }
}
