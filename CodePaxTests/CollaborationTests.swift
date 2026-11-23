import XCTest
@testable import CodePax

final class CollaborationTests: XCTestCase {
    private func makeRun(status: String = "running", coordinatorSession: String? = nil,
                     snapshot: String? = nil, applied: String? = nil) throws -> CollaborationRun {
        let worker: [String: Any] = ["id": "worker-1", "title": "API", "role": "worker", "status": "failed",
            "worktree": "/repo/.git/team/worker", "branch": "codex/team/worker", "result": "", "integrated": false, "attempt": 1]
        var coordinator: [String: Any] = ["id": "coordinator", "title": "主控", "role": "coordinator", "status": status == "completed" ? "completed" : "queued",
            "worktree": "/repo/.git/team/coordinator", "branch": "codex/team/coordinator", "result": "", "integrated": false, "attempt": 1]
        coordinator["sessionId"] = coordinatorSession
        coordinator["snapshotCommit"] = snapshot
        var json: [String: Any] = ["id": "run-1", "goal": "实现接口", "cwd": "/repo", "sourceBranch": "main", "baseCommit": "base",
            "status": status, "maxWorkers": 2, "tasks": [worker, coordinator], "messages": [], "createdAt": 1, "updatedAt": 2]
        json["appliedCommit"] = applied
        return try JSONDecoder().decode(CollaborationRun.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testApplyingRequiresCompletedCoordinatorSnapshotAndCannotApplyTwice() throws {
        XCTAssertFalse(try makeRun(snapshot: "snapshot").canApply)
        XCTAssertFalse(try makeRun(status: "completed").canApply)
        XCTAssertTrue(try makeRun(status: "completed", snapshot: "snapshot").canApply)
        XCTAssertFalse(try makeRun(status: "completed", snapshot: "snapshot", applied: "snapshot").canApply)
    }

    func testWorkerRetryIsDisabledAfterCoordinatorHasStarted() throws {
        let pending = try makeRun()
        XCTAssertTrue(pending.canRetry(pending.workers[0]))
        let collecting = try makeRun(coordinatorSession: "coordinator-thread")
        XCTAssertFalse(collecting.canRetry(collecting.workers[0]))
    }

    func testTeamMembershipIsOptionalForExistingCodexSessions() throws {
        let json = """
        {"id":"old","title":"Demo","cwd":"/repo","status":"completed","messages":[],"approvals":[],"diff":"","historyTruncated":false}
        """
        let session = try JSONDecoder().decode(CodexSession.self, from: Data(json.utf8))
        XCTAssertNil(session.collaborationRunId)
        XCTAssertNil(session.collaborationTaskId)
    }

    func testTeamMessagesResolveRecipientsAndKeepTasksSeparate() throws {
        let team = try makeRun()
        XCTAssertEqual(team.memberTitle("worker-1"), "API")
        XCTAssertEqual(team.memberTitle("all"), "所有成员")
        XCTAssertEqual(team.workers.count, 1)
        XCTAssertEqual(team.coordinator?.id, "coordinator")
    }
}
