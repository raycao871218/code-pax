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


class CatalogRPC(FakeRPC):
    def __init__(self, callback):
        super().__init__(callback)
        self.owner = callback.__self__
        self.external_status = "completed"

    def request(self, method, params):
        if method in {"model/list", "thread/list", "thread/read", "thread/items/list", "thread/turns/list", "thread/resume"}:
            self.calls.append((method, params))
            if method == "model/list":
                name = "model-b" if params.get("cursor") else "model-a"
                return {"data": [{"model": name, "displayName": name.upper(), "defaultReasoningEffort": "low",
                    "supportedReasoningEfforts": [{"reasoningEffort": "low", "description": "Fast"},
                                                   {"reasoningEffort": "high", "description": "Thorough"}]}],
                        "nextCursor": None if params.get("cursor") else "next-models"}
            if method == "thread/list":
                return {"data": [{"id": "cli-history", "cwd": str(self.owner.root / "demo"),
                    "preview": "An existing CLI session", "updatedAt": 123},
                    {"id": "outside", "cwd": str(self.owner.root.parent), "preview": "Outside root"}], "nextCursor": "more-threads"}
            if method == "thread/read":
                return {"thread": {"id": params["threadId"], "name": "CLI title", "status": {"type": "notLoaded"}}}
            if method == "thread/turns/list":
                return {"data": [{"id": "external-turn", "status": self.external_status}], "nextCursor": None}
            if method == "thread/items/list":
                if params.get("cursor"):
                    return {"data": [{"turnId": "older", "item": {"id": "older-message", "type": "agentMessage", "text": "Older reply"}}], "nextCursor": None}
                return {"data": [{"turnId": "external-turn", "item": {"id": "cli-reply", "type": "agentMessage", "text": "Saved reply"}},
                                 {"turnId": "external-turn", "item": {"id": "cli-user", "type": "userMessage", "content": [{"type": "text", "text": "Saved prompt"}]}}],
                        "nextCursor": "older-items"}
            if method == "thread/resume":
                return {"model": "model-a", "reasoningEffort": "low"}
        return super().request(method, params)


class CatalogTests(unittest.TestCase):
    def setUp(self):
        BridgeTests.setUp(self)
        self.bridge.store.db.close()
        self.bridge = Bridge(self.data, self.root, rpc_factory=CatalogRPC)

    tearDown = BridgeTests.tearDown
    create = BridgeTests.create

    def import_history(self):
        return self.bridge.dispatch({"action": "catalog"})["result"]

    def test_cli_catalog_filters_outside_projects_and_keeps_pagination(self):
        result = self.import_history()
        self.assertEqual(result, {"imported": 1, "skipped": 1, "nextCursor": "more-threads"})
        self.assertEqual(self.bridge.sessions["cli-history"]["origin"], "codex")
        self.assertNotIn("outside", self.bridge.sessions)
        self.assertEqual(self.bridge.snapshot(None)["projects"][0]["id"], str(self.project))

    def test_reading_history_never_resumes_or_starts_a_turn(self):
        self.import_history()
        self.bridge.dispatch({"action": "open", "sessionId": "cli-history"})
        self.assertNotIn("cli-history", self.bridge.loaded)
        self.assertFalse(any(method in {"thread/resume", "turn/start"} for method, _ in self.bridge.rpc.calls))
        selected = self.bridge.snapshot("cli-history")["selected"]
        self.assertEqual([m["id"] for m in selected["messages"]], ["cli-user", "cli-reply"])
        self.assertTrue(selected["historyTruncated"])

    def test_older_history_page_uses_server_cursor(self):
        self.import_history()
        result = self.bridge.dispatch({"action": "historyPage", "sessionId": "cli-history", "cursor": "older-items"})
        self.assertEqual(result["result"]["messages"][0]["id"], "older-message")
        self.assertIsNone(result["result"]["nextCursor"])

    def test_live_external_cli_session_is_read_only(self):
        self.import_history()
        self.bridge.rpc.external_status = "inProgress"
        self.bridge.dispatch({"action": "open", "sessionId": "cli-history"})
        self.assertTrue(self.bridge.sessions["cli-history"]["readOnly"])
        result = self.bridge.dispatch({"action": "send", "sessionId": "cli-history", "text": "hello", "operationId": "external-running-send"})
        self.assertFalse(result["ok"])
        self.assertFalse(any(method == "turn/start" for method, _ in self.bridge.rpc.calls))

    def test_idle_cli_session_resumes_same_thread_without_forcing_model(self):
        self.import_history()
        result = self.bridge.dispatch({"action": "send", "sessionId": "cli-history", "text": "continue", "operationId": "external-idle-send"})
        self.assertTrue(result["ok"])
        resume = next(params for method, params in self.bridge.rpc.calls if method == "thread/resume")
        turn = next(params for method, params in self.bridge.rpc.calls if method == "turn/start")
        self.assertEqual(resume["threadId"], "cli-history")
        self.assertTrue(resume["excludeTurns"])
        self.assertNotIn("model", turn)
        self.assertNotIn("effort", turn)

    def test_model_pagination_and_supported_effort_are_enforced(self):
        catalog = self.bridge.dispatch({"action": "models"})["result"]["models"]
        self.assertEqual([m["model"] for m in catalog], ["model-a", "model-b"])
        result = self.bridge.dispatch({"action": "create", "cwd": str(self.project), "model": "model-b", "effort": "high", "operationId": "model-selected-create"})
        self.assertTrue(result["ok"])
        self.assertEqual(next(p for m, p in self.bridge.rpc.calls if m == "thread/start")["model"], "model-b")
        sent = self.bridge.dispatch({"action": "send", "sessionId": "thread-test", "text": "hello", "model": "model-b", "effort": "high", "operationId": "model-selected-send"})
        self.assertTrue(sent["ok"])
        self.assertEqual(next(p for m, p in self.bridge.rpc.calls if m == "turn/start")["effort"], "high")
        with self.assertRaises(BridgeError):
            self.bridge.model_settings({"model": "model-b", "effort": "unsupported"})
        with self.assertRaises(BridgeError):
            self.bridge.model_settings({"model": "invented-model"})

    def test_empty_project_persists_without_creating_codex_thread(self):
        result = self.bridge.dispatch({"action": "addProject", "cwd": str(self.project), "operationId": "register-empty-project"})
        self.assertTrue(result["ok"])
        self.assertEqual(self.bridge.rpc.calls, [])
        self.assertEqual(self.bridge.snapshot(None)["projects"], [{"id": str(self.project), "title": "demo"}])
        restarted = Bridge(self.data, self.root, rpc_factory=CatalogRPC)
        try:
            self.assertEqual(restarted.snapshot(None)["projects"][0]["id"], str(self.project))
        finally:
            restarted.store.db.close()


if __name__ == "__main__":
    unittest.main()
