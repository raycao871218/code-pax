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
}
