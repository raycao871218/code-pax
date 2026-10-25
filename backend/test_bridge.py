import json
from pathlib import Path
import tempfile
import unittest

from bridge import Bridge, BridgeError


class FakeRPC:
    def __init__(self, callback):
        self.callback = callback
        self.ready = True
        self.calls = []
        self.responses = []

    def request(self, method, params):
        self.calls.append((method, params))
        if method == "thread/start":
            return {"thread": {"id": "thread-test"}}
        if method == "turn/start":
            self.callback({"method": "turn/started", "params": {"threadId": params["threadId"],
                "turn": {"id": "turn-test", "status": "inProgress"}}})
            return {"turn": {"id": "turn-test", "status": "inProgress"}}
        if method == "account/read":
            return {"account": {"type": "chatgpt"}}
        return {}

    def write(self, frame):
        self.responses.append(frame)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.root = self.base / "projects"
        self.root.mkdir()
        self.project = self.root / "demo"
        self.project.mkdir()
        self.data = self.base / "state"
        self.data.mkdir()
        self.bridge = Bridge(self.data, self.root, rpc_factory=FakeRPC)

    def tearDown(self):
        self.bridge.store.db.close()
        self.temporary.cleanup()

    def create(self):
        result = self.bridge.dispatch({"action": "create", "cwd": str(self.project), "operationId": "create-operation"})
        self.assertTrue(result["ok"])
        return result["result"]["id"]

    def send(self):
        identifier = self.create()
        request = {"action": "send", "sessionId": identifier, "text": "hello", "operationId": "send-operation"}
        result = self.bridge.dispatch(request)
        self.assertTrue(result["ok"])
        return identifier, request

    def approval(self, identifier):
        self.bridge.on_message({"id": 42, "method": "item/commandExecution/requestApproval", "params": {
            "threadId": identifier, "turnId": "turn-test", "itemId": "cmd-1", "command": "touch file"}})
        return self.bridge.sessions[identifier]["approvals"][0]

    def test_duplicate_turn_request_does_not_execute_twice(self):
        _, request = self.send()
        self.assertTrue(self.bridge.dispatch(request)["ok"])
        self.assertEqual(sum(m == "turn/start" for m, _ in self.bridge.rpc.calls), 1)
        with self.assertRaises(BridgeError):
            self.bridge.dispatch(dict(request, text="different task"))

    def test_incomplete_operation_is_not_replayed(self):
        request = {"action": "create", "cwd": str(self.project), "operationId": "uncertain-operation"}
        import hashlib
        digest = hashlib.sha256(json.dumps(request, sort_keys=True).encode()).hexdigest()
        self.bridge.store.db.execute("INSERT INTO operations VALUES (?,?,NULL)", (request["operationId"], digest))
        self.bridge.store.db.commit()
        with self.assertRaises(BridgeError):
            self.bridge.dispatch(request)
        self.assertEqual(self.bridge.rpc.calls, [])

    def test_rejects_outside_root_and_symlink_escape(self):
        with self.assertRaises(BridgeError):
            self.bridge.project(str(self.root / ".."))
        try:
            (self.root / "escape").symlink_to(self.base, target_is_directory=True)
        except OSError:
            self.skipTest("Symlink creation unavailable on this host")
        with self.assertRaises(BridgeError):
            self.bridge.project(str(self.root / "escape"))

    def test_request_id_turn_and_session_scoping(self):
        identifier, _ = self.send()
        approval = self.approval(identifier)
        request = {"action": "answer", "sessionId": identifier, "requestId": approval["id"],
                   "decision": "accept", "operationId": "answer-operation"}
        self.bridge.sessions[identifier]["turnId"] = "different-turn"
        self.assertFalse(self.bridge.dispatch(request)["ok"])
        self.assertEqual(self.bridge.rpc.responses, [])

    def test_approval_response_is_once_only_and_not_session_wide(self):
        identifier, _ = self.send()
        approval = self.approval(identifier)
        request = {"action": "answer", "sessionId": identifier, "requestId": approval["id"],
                   "decision": "accept", "operationId": "answer-operation"}
        self.assertTrue(self.bridge.dispatch(request)["ok"])
        self.assertTrue(self.bridge.dispatch(request)["ok"])
        self.assertEqual(self.bridge.rpc.responses, [{"id": 42, "result": {"decision": "accept"}}])
        self.assertFalse(self.bridge.dispatch(dict(request, operationId="new-answer-operation"))["ok"])

    def test_failed_turn_is_not_reported_as_completed(self):
        identifier, _ = self.send()
        self.approval(identifier)
        self.bridge.on_message({"method": "turn/completed", "params": {"threadId": identifier,
            "turn": {"id": "turn-test", "status": "failed", "error": {"message": "Usage limit"}}}})
        selected = self.bridge.snapshot(identifier)["selected"]
        self.assertEqual(selected["status"], "failed")
        self.assertEqual(selected["error"], "Usage limit")
        self.assertEqual(selected["approvals"], [])

    def test_message_completion_overrides_streamed_deltas(self):
        identifier, _ = self.send()
        for method, params in [
            ("item/started", {"item": {"id": "msg-1", "type": "agentMessage", "text": ""}}),
            ("item/agentMessage/delta", {"itemId": "msg-1", "delta": "partial"}),
            ("item/completed", {"item": {"id": "msg-1", "type": "agentMessage", "text": "authoritative"}}),
        ]:
            self.bridge.on_message({"method": method, "params": dict(params, threadId=identifier)})
        self.assertEqual(self.bridge.snapshot(identifier)["selected"]["messages"][0]["text"], "authoritative")

    def test_restart_preserves_history_and_invalidates_old_approvals(self):
        identifier, _ = self.send()
        self.approval(identifier)
        restarted = Bridge(self.data, self.root, rpc_factory=FakeRPC)
        try:
            session = restarted.snapshot(identifier)["selected"]
            self.assertEqual(session["status"], "interrupted")
            self.assertEqual(session["approvals"], [])
            self.assertNotIn(identifier, restarted.loaded)
        finally:
            restarted.store.db.close()

    def test_snapshot_is_detached_from_live_state(self):
        identifier, _ = self.send()
        snapshot = self.bridge.snapshot(identifier)
        snapshot["selected"]["messages"].append({"fake": True})
        self.assertEqual(self.bridge.sessions[identifier]["messages"], [])

    def test_stale_selected_id_still_returns_session_list(self):
        identifier = self.create()
        snapshot = self.bridge.snapshot("deleted-or-old-thread")
        self.assertIsNone(snapshot["selected"])
        self.assertEqual(snapshot["sessions"][0]["id"], identifier)

    def test_stop_waits_for_actual_completion_event(self):
        identifier, _ = self.send()
        result = self.bridge.dispatch({"action": "stop", "sessionId": identifier, "operationId": "stop-operation"})
        self.assertTrue(result["ok"])
        self.assertEqual(self.bridge.sessions[identifier]["status"], "inProgress")
        self.assertIn(("turn/interrupt", {"threadId": identifier, "turnId": "turn-test"}), self.bridge.rpc.calls)

    def test_restart_cannot_kill_active_or_uncertain_tasks(self):
        identifier, _ = self.send()
        for state in ["inProgress", "waiting", "unknown"]:
            self.bridge.sessions[identifier]["status"] = state
            with self.assertRaises(BridgeError):
                self.bridge.begin_shutdown()
            self.assertFalse(self.bridge.stopping)
        self.bridge.sessions[identifier]["status"] = "completed"
        self.bridge.begin_shutdown()
        with self.assertRaises(BridgeError):
            self.bridge.dispatch({"action": "create", "cwd": str(self.project), "operationId": "racing-new-thread"})

    def test_permission_expansion_is_never_implicitly_granted(self):
        identifier, _ = self.send()
        self.bridge.on_message({"id": 44, "method": "item/permissions/requestApproval", "params": {
            "threadId": identifier, "turnId": "turn-test", "itemId": "permissions-1", "permissions": {"network": True}}})
        approval = self.bridge.sessions[identifier]["approvals"][0]
        request = {"action": "answer", "sessionId": identifier, "requestId": approval["id"],
                   "decision": "accept", "operationId": "permission-operation"}
        self.assertFalse(self.bridge.dispatch(request)["ok"])
        self.assertEqual(self.bridge.rpc.responses, [])

    def test_questions_use_question_ids_and_require_every_answer(self):
        identifier, _ = self.send()
        self.bridge.on_message({"id": "question-rpc", "method": "item/tool/requestUserInput", "params": {
            "threadId": identifier, "turnId": "turn-test", "itemId": "question-1", "questions": [
                {"id": "branch", "question": "Which branch?"}, {"id": "tests", "question": "Run tests?"}]}})
        approval = self.bridge.sessions[identifier]["approvals"][0]
        request = {"action": "answer", "sessionId": identifier, "requestId": approval["id"],
                   "answers": {"branch": "main"}, "operationId": "incomplete-answer"}
        self.assertFalse(self.bridge.dispatch(request)["ok"])
        request.update(answers={"branch": "main", "tests": "yes"}, operationId="complete-answer")
        self.assertTrue(self.bridge.dispatch(request)["ok"])
        self.assertEqual(self.bridge.rpc.responses[-1]["result"], {
            "answers": {"branch": {"answers": ["main"]}, "tests": {"answers": ["yes"]}}})


if __name__ == "__main__":
    unittest.main()
