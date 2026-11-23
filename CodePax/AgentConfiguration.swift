import Foundation

/// User intent is independent of server capabilities. A missing capability must
/// block an unsupported request, never silently substitute a provider or mode.
struct AgentSessionSelection: Equatable {
    let agent: String
    let mode: String

    static func hasChat(_ agent: String) -> Bool { ["codex", "claude"].contains(agent) }

    init(agent: String, mode: String, login: Bool = false) {
        self.agent = agent
        self.mode = login || !Self.hasChat(agent) || mode == "terminal" ? "terminal" : "chat"
    }

    var fields: [String: JSONValue] { ["agent": .string(agent), "mode": .string(mode)] }

    func matches(_ fields: [String: JSONValue]) -> Bool {
        agent == (fields["agent"]?.string ?? "codex") && mode == (fields["mode"]?.string ?? "chat")
    }
}

struct AgentConfiguration: Codable, Equatable {
    var executable = ""
    var arguments = ""
    var model = ""
    var modelArgument = "--model"
    var environment = ""
    var loginCommand = ""

    static func preset(_ agent: String) -> Self {
        Self(executable: agent == "custom" ? "" : agent)
    }

    func fields() throws -> JSONValue {
        for (name, value, limit) in [("可执行文件", executable, 4096), ("启动参数", arguments, 4096),
                                     ("模型", model, 256), ("模型参数名", modelArgument, 128), ("登录命令", loginCommand, 4096)] {
            guard value.count <= limit, !value.unicodeScalars.contains(where: { $0.value < 32 }) else {
                throw ConnectionError.message(name + "不能包含换行或控制字符，且不能过长。")
            }
        }
        var variables: [String: JSONValue] = [:]
        for line in environment.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let separator = line.firstIndex(of: "=") else {
                throw ConnectionError.message("环境变量请按每行 NAME=value 填写。")
            }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,127}$", options: .regularExpression) != nil else {
                throw ConnectionError.message("环境变量名称不正确：" + name)
            }
            guard variables[name] == nil else { throw ConnectionError.message("环境变量重复：" + name) }
            variables[name] = .string(String(line[line.index(after: separator)...]))
        }
        guard variables.count <= 64 else { throw ConnectionError.message("环境变量最多 64 项。") }
        return .object(["executable": .string(executable), "arguments": .string(arguments),
                        "model": .string(model), "modelArgument": .string(modelArgument),
                        "environment": .object(variables), "loginCommand": .string(loginCommand)])
    }
}
