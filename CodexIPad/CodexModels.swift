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
}

struct CodexMessage: Decodable, Identifiable {
    let id: String
    let kind: String
    let text: String
    let status: String
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
    let model: String?
    let effort: String?
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
    default: return "就绪"
    }
}
