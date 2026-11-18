import XCTest
@testable import CodexIPad

final class CodexModelsTests: XCTestCase {
    func testShellQuotingCannotInjectCommands() {
        XCTAssertEqual(RemoteShell.quote("it's $(touch /tmp/example)"), "'it'\"'\"'s $(touch /tmp/example)'")
        XCTAssertEqual(RemoteShell.quote(""), "''")
    }

    func testJSONRoundTripPreservesMixedApprovalPayload() throws {
        let payload = """
        {"id":42,"method":"item/commandExecution/requestApproval","params":{"command":"echo test","availableDecisions":["accept","decline"],"optional":null}}
        """
        let original = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded["params"]["command"].string, "echo test")
    }

    func testFailedAndInterruptedAreNotRunning() throws {
        for state in ["failed", "completed", "interrupted"] {
            let json = """
            {"id":"thread-1","title":"Demo","cwd":"/tmp/demo","status":"\(state)","turnId":null,"messages":[],"approvals":[],"diff":"","error":null,"historyTruncated":false}
            """
            let session = try JSONDecoder().decode(CodexSession.self, from: Data(json.utf8))
            XCTAssertFalse(session.isRunning)
        }
    }

    func testOlderCodexSessionsRemainChatSessions() throws {
        let json = """
        {"id":"thread-1","title":"Demo","cwd":"/tmp/demo","status":"completed","messages":[],"approvals":[],"diff":"","historyTruncated":false}
        """
        let session = try JSONDecoder().decode(CodexSession.self, from: Data(json.utf8))
        XCTAssertFalse(session.isTerminal)
        XCTAssertEqual(session.agentTitle, "Codex")
    }

    func testTerminalSessionAndAgentCatalogDecodeWithoutCodex() throws {
        let json = """
        {"protocol":3,"ready":true,"root":"/home/me","authenticated":false,"accountType":"Codex 尚未登录","codexReady":false,"capabilities":["terminal","customCLI"],"agents":[{"id":"claude","title":"Claude Code","available":true,"command":"claude"}]}
        """
        let status = try JSONDecoder().decode(BridgeStatus.self, from: Data(json.utf8))
        XCTAssertTrue(status.ready)
        XCTAssertEqual(status.codexReady, false)
        XCTAssertEqual(status.agents?.first?.id, "claude")
        let sessionJSON = """
        {"id":"cli-1","title":"CLI","cwd":"/tmp/demo","status":"inProgress","messages":[],"approvals":[],"diff":"","historyTruncated":false,"agent":"claude","mode":"terminal"}
        """
        let session = try JSONDecoder().decode(CodexSession.self, from: Data(sessionJSON.utf8))
        XCTAssertTrue(session.isTerminal)
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(session.agentTitle, "Claude Code")
    }

    func testProtocolTwoStatusRemainsCompatible() throws {
        let json = """
        {"protocol":2,"ready":true,"root":"/home/me","authenticated":true,"accountType":"服务器已有登录"}
        """
        let status = try JSONDecoder().decode(BridgeStatus.self, from: Data(json.utf8))
        XCTAssertNil(status.agents)
        XCTAssertNil(status.capabilities)
        XCTAssertNil(status.codexReady)
    }
}
