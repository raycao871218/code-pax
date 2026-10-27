import json
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock

from bridge import Bridge, BridgeError, ensure, BRIDGE_VERSION, PROTOCOL


class EnsureUpgradeTests(unittest.TestCase):
    def status(self, current=False):
        return {"ok": True, "result": {"ready": True, "protocol": PROTOCOL if current else 1,
                "version": BRIDGE_VERSION if current else None, "root": "/home/example"}}

    def test_matching_daemon_is_reused(self):
        with patch("bridge.call", return_value=self.status(True)) as rpc, patch("bridge.subprocess.Popen") as spawn:
            self.assertTrue(ensure(Path("/unused"), None)["ok"])
            self.assertEqual(rpc.call_count, 1)
            spawn.assert_not_called()

    def test_old_daemon_with_active_or_uncertain_tasks_is_preserved(self):
        for state in ["inProgress", "waiting", "starting", "unknown"]:
            with self.subTest(state=state), patch("bridge.call", side_effect=[self.status(),
                    {"ok": True, "result": {"sessions": [{"status": state}]}}]) as rpc, patch("bridge.subprocess.Popen") as spawn:
                self.assertTrue(ensure(Path("/unused"), None)["result"]["upgradePending"])
                self.assertEqual(rpc.call_count, 2)
                spawn.assert_not_called()

    def test_idle_old_daemon_upgrades_and_preserves_root(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch("bridge.call", side_effect=[self.status(), {"ok": True, "result": {"sessions": []}},
                    {"ok": True, "result": {}}, self.status(True)]) as rpc, \
                    patch("bridge.shutil.which", return_value="/usr/local/bin/codex"), \
                    patch("bridge.subprocess.Popen", return_value=Mock()) as spawn:
                self.assertEqual(ensure(Path(directory), None)["result"]["version"], BRIDGE_VERSION)
                self.assertEqual(rpc.call_args_list[2].args[1], {"action": "shutdown"})
                self.assertEqual(spawn.call_args.args[0][-2:], ["--root", "/home/example"])

    def test_task_starting_during_upgrade_cannot_be_killed(self):
        with patch("bridge.call", side_effect=[self.status(), {"ok": True, "result": {"sessions": []}},
                {"ok": False, "error": "task started"}]), patch("bridge.subprocess.Popen") as spawn:
            self.assertTrue(ensure(Path("/unused"), None)["result"]["upgradePending"])
            spawn.assert_not_called()

    def test_unknown_snapshot_fails_without_shutdown(self):
        with patch("bridge.call", side_effect=[self.status(), {"ok": False, "error": "unavailable"}]) as rpc:
            with self.assertRaises(BridgeError):
                ensure(Path("/unused"), None)
            self.assertEqual(rpc.call_count, 2)


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
        self.base = Path(self.temporary.name).resolve()
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

    def test_session_metadata_is_persisted_and_does_not_execute_tasks(self):
        identifier = self.create()
        self.bridge.rpc.calls.clear()
        result = self.bridge.dispatch({"action": "sessionMetadata", "sessionId": identifier, "title": "  自定义标题  ",
            "pinned": True, "archived": True, "operationId": "metadata-edit"})
        self.assertTrue(result["ok"], result)
        summary = self.bridge.snapshot(None)["sessions"][0]
        self.assertEqual(summary["title"], "自定义标题")
        self.assertTrue(summary["pinned"])
        self.assertTrue(summary["archived"])
        self.assertEqual(self.bridge.rpc.calls, [])
        restarted = Bridge(self.data, self.root, rpc_factory=FakeRPC)
        try:
            self.assertTrue(restarted.sessions[identifier]["archived"])
            restarted.session_metadata({"sessionId": identifier, "archived": False})
            self.assertFalse(restarted.sessions[identifier]["archived"])
        finally: restarted.store.db.close()

    def test_metadata_validation_and_active_archive_do_not_partially_change_title(self):
        identifier = self.create()
        before = self.bridge.sessions[identifier]["title"]
        for change in [{"title": " "}, {"title": "x" * 101}, {"pinned": "yes"}, {"archived": 1}]:
            with self.assertRaises(BridgeError): self.bridge.session_metadata({"sessionId": identifier, **change})
        self.bridge.sessions[identifier]["status"] = "inProgress"
        with self.assertRaises(BridgeError): self.bridge.session_metadata({"sessionId": identifier, "title": "changed", "archived": True})
        self.assertEqual(self.bridge.sessions[identifier]["title"], before)
        self.assertEqual(self.bridge.sessions[identifier]["status"], "inProgress")

    def test_file_info_returns_verified_project_file_and_rejects_escape(self):
        identifier = self.create()
        content = "中文文件\n".encode() * 10000
        target = self.project / "result.txt"; target.write_bytes(content)
        info = self.bridge.file_info({"sessionId": identifier, "path": "result.txt"})
        self.assertEqual(info["sha256"], hashlib.sha256(content).hexdigest())
        self.assertEqual(info["size"], len(content))
        outside = self.root / "private.txt"; outside.write_text("private")
        link = self.project / "escape.txt"; link.symlink_to(outside)
        for path in ["../private.txt", str(outside), "escape.txt", "missing.txt", "."]:
            with self.subTest(path=path), self.assertRaises(BridgeError): self.bridge.file_info({"sessionId": identifier, "path": path})
        with target.open("wb") as handle: handle.truncate(100 * 1024 * 1024 + 1)
        with self.assertRaises(BridgeError): self.bridge.file_info({"sessionId": identifier, "path": str(target)})

    def test_older_attachment_prompt_metadata_is_recovered_on_restart(self):
        identifier, ready = self.upload_attachment()
        self.bridge.sessions[identifier]["messages"] = [{"id": "legacy-user", "kind": "userMessage", "text": "📎 notes.txt",
            "sourceText": "Look at files\n" + json.dumps({"name": ready["name"], "path": ready["path"]}), "status": "accepted"}]
        self.bridge.store.save(self.bridge.sessions[identifier])
        restarted = Bridge(self.data, self.root, rpc_factory=FakeRPC)
        try:
            self.assertEqual(restarted.sessions[identifier]["messages"][0]["attachments"][0]["id"], ready["id"])
        finally: restarted.store.db.close()

    def test_attachment_metadata_is_available_in_echoes_and_older_history(self):
        identifier, ready = self.upload_attachment()
        self.bridge.dispatch({"action": "send", "sessionId": identifier, "text": "read", "attachments": [ready["id"]], "operationId": "meta-send"})
        inputs = next(p["input"] for m,p in self.bridge.rpc.calls if m == "turn/start")
        self.bridge.on_message({"method": "item/completed", "params": {"threadId": identifier,
            "item": {"id": "remote-user", "type": "userMessage", "content": inputs}}})
        message = self.bridge.sessions[identifier]["messages"][0]
        self.assertEqual(message["attachments"][0]["path"], ready["path"])
        page = self.bridge.decorate_history(identifier, {"messages": [{"id": "remote-user", "text": "server", "kind": "userMessage", "status": "completed"}]})
        self.assertEqual(page["messages"][0]["attachments"][0]["name"], "notes.txt")
        self.assertEqual(self.bridge.store.attachments_for("different-session", "remote-user"), [])

    def test_long_streamed_answer_is_saved_completely_and_paged_without_wire_overflow(self):
        identifier = self.create()
        self.bridge.on_message({"method": "item/started", "params": {"threadId": identifier,
            "item": {"id": "long", "type": "agentMessage", "text": ""}}})
        chunks = ["开头\n" + "中文😀" * 20000, "\n中间\n" + "abc" * 20000, "\n末尾-END"]
        for chunk in chunks:
            self.bridge.on_message({"method": "item/agentMessage/delta", "params": {"threadId": identifier, "itemId": "long", "delta": chunk}})
        original = "".join(chunks)
        self.assertEqual(self.bridge.sessions[identifier]["messages"][0]["text"], original)
        snapshot = self.bridge.snapshot(identifier)
        preview = snapshot["selected"]["messages"][0]
        self.assertTrue(preview["textTruncated"])
        self.assertEqual(preview["contentLength"], len(original))
        self.assertLess(len(json.dumps(snapshot, ensure_ascii=False).encode()), 2 * 1024 * 1024)
        result = ""; offset = 0; revision = None
        while offset is not None:
            page = self.bridge.message_body({"sessionId": identifier, "messageId": "long", "offset": offset, "revision": revision})
            result += page["text"]; offset = page["nextOffset"]; revision = page["revision"]
        self.assertEqual(result, original)
        restarted = Bridge(self.data, self.root, rpc_factory=FakeRPC)
        try: self.assertEqual(restarted.store.body(identifier, "long"), original)
        finally: restarted.store.db.close()

    def test_full_body_revision_detects_updates_and_rejects_invalid_offsets(self):
        identifier = self.create()
        message = {"id": "a", "kind": "agentMessage", "text": "first", "status": "inProgress"}
        self.bridge.sessions[identifier]["messages"] = [message]
        first = self.bridge.message_body({"sessionId": identifier, "messageId": "a"})
        message["text"] += " updated"
        with self.assertRaises(BridgeError):
            self.bridge.message_body({"sessionId": identifier, "messageId": "a", "revision": first["revision"]})
        for offset in [-1, 1000, 1.5, True]:
            with self.subTest(offset=offset), self.assertRaises(BridgeError):
                self.bridge.message_body({"sessionId": identifier, "messageId": "a", "offset": offset})

    def test_old_history_body_is_cached_before_preview_and_remains_accessible(self):
        identifier = self.create()
        message = {"id": "old", "kind": "agentMessage", "text": "history" * 20000, "status": "completed"}
        self.bridge.history_page = Mock(return_value={"messages": [message], "nextCursor": None})
        page = self.bridge.dispatch({"action": "historyPage", "sessionId": identifier})["result"]
        self.assertTrue(page["messages"][0]["textTruncated"])
        self.assertEqual(self.bridge.store.body(identifier, "old"), message["text"])
        body = self.bridge.message_body({"sessionId": identifier, "messageId": "old"})
        self.assertEqual(body["text"], message["text"][:24000])
        self.bridge.sessions["another"] = {**self.bridge.sessions[identifier], "id": "another"}
        with self.assertRaises(BridgeError): self.bridge.message_body({"sessionId": "another", "messageId": "old"})

    def test_long_command_and_diff_are_preserved(self):
        identifier = self.create()
        content = "output😀\n" * 30000
        self.bridge.on_message({"method": "item/completed", "params": {"threadId": identifier,
            "item": {"id": "cmd", "type": "commandExecution", "command": "test", "aggregatedOutput": content}}})
        self.bridge.on_message({"method": "turn/diff/updated", "params": {"threadId": identifier, "diff": content}})
        snapshot = self.bridge.snapshot(identifier)["selected"]
        self.assertTrue(snapshot["diffTruncated"])
        self.assertEqual(self.bridge.sessions[identifier]["diff"], content)
        self.assertTrue(self.bridge.sessions[identifier]["messages"][0]["text"].endswith(content))
        self.assertEqual(self.bridge.message_body({"sessionId": identifier, "messageId": "__diff__"})["text"], content[:24000])

    def upload_attachment(self, name="notes.txt", data=b"hello"):
        identifier = self.create()
        begin = self.bridge.attachment({"action": "attachmentBegin", "sessionId": identifier, "name": name, "size": len(data)})
        Path(begin["uploadPath"]).write_bytes(data)
        ready = self.bridge.attachment({"action": "attachmentFinish", "sessionId": identifier, "id": begin["id"]})
        return identifier, ready

    def test_attachments_send_native_images_and_project_file_references(self):
        identifier, image = self.upload_attachment("screen.png", b"pngdata")
        begin = self.bridge.attachment({"action": "attachmentBegin", "sessionId": identifier, "name": "notes.txt", "size": 5})
        Path(begin["uploadPath"]).write_bytes(b"hello")
        document = self.bridge.attachment({"action": "attachmentFinish", "sessionId": identifier, "id": begin["id"]})
        result = self.bridge.dispatch({"action": "send", "sessionId": identifier, "text": "", "attachments": [image["id"], document["id"]], "operationId": "attach-send"})
        self.assertTrue(result["ok"], result)
        inputs = next(p["input"] for m, p in self.bridge.rpc.calls if m == "turn/start")
        self.assertEqual(inputs[1], {"type": "localImage", "path": image["path"]})
        self.assertIn(document["path"], inputs[0]["text"])
        self.assertEqual(Path(image["path"]).read_bytes(), b"pngdata")
        message = self.bridge.snapshot(identifier)["selected"]["messages"][0]
        self.assertIn("📎 screen.png", message["text"])
        self.assertNotIn(image["path"], message["text"])
        self.bridge.on_message({"method": "item/completed", "params": {"threadId": identifier,
            "item": {"id": "attached-user", "type": "userMessage", "content": inputs}}})
        messages = self.bridge.snapshot(identifier)["selected"]["messages"]
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]["text"], message["text"])
        self.assertEqual(messages[0]["id"], "local:attach-send")

    def test_missing_attachment_rejection_is_safe_to_edit_and_retry(self):
        identifier, ready = self.upload_attachment()
        Path(ready["path"]).unlink()
        request = {"action": "send", "sessionId": identifier, "text": "read", "attachments": [ready["id"]], "operationId": "missing-file"}
        result = self.bridge.dispatch(request)
        self.assertFalse(result["ok"])
        self.assertEqual(self.bridge.store.operation_status(request)["state"], "rejected")
        self.assertFalse(any(m == "turn/start" for m, _ in self.bridge.rpc.calls))

    def test_attachment_limits_and_paths_are_validated(self):
        identifier = self.create()
        for name, size in [("../escape", 1), ("bad\nname", 1), ("..", 1), ("x", 0), ("x", 20 * 1024 * 1024 + 1)]:
            with self.subTest(name=name, size=size), self.assertRaises(BridgeError):
                self.bridge.attachment({"action": "attachmentBegin", "sessionId": identifier, "name": name, "size": size})
        with self.assertRaises(BridgeError):
            self.bridge.attachment({"action": "attachmentFinish", "sessionId": identifier, "id": "../escape"})

    def test_attachment_incomplete_cross_session_and_symlink_are_rejected(self):
        identifier = self.create()
        begin = self.bridge.attachment({"action": "attachmentBegin", "sessionId": identifier, "name": "a.txt", "size": 5})
        Path(begin["uploadPath"]).write_bytes(b"no")
        with self.assertRaises(BridgeError):
            self.bridge.attachment({"action": "attachmentFinish", "sessionId": identifier, "id": begin["id"]})
        Path(begin["uploadPath"]).unlink()
        Path(begin["uploadPath"]).symlink_to(self.root / "other")
        with self.assertRaises(BridgeError):
            self.bridge.attachment({"action": "attachmentFinish", "sessionId": identifier, "id": begin["id"]})
        other = {**self.bridge.sessions[identifier], "id": "other"}
        with self.assertRaises(BridgeError): self.bridge.read_attachment(begin["id"], other)

    def test_completed_attachment_survives_daemon_restart_and_deleted_file_is_rejected(self):
        identifier, ready = self.upload_attachment()
        restarted = Bridge(self.data, self.root, rpc_factory=FakeRPC)
        try:
            self.assertEqual(restarted.read_attachment(ready["id"], restarted.session(identifier))["name"], "notes.txt")
            Path(ready["path"]).unlink()
            with self.assertRaises(BridgeError): restarted.read_attachment(ready["id"], restarted.session(identifier))
        finally: restarted.store.db.close()

    def test_successful_completion_marker_survives_polling_new_turns_and_restart(self):
        identifier = self.create()
        for method, status, turn in [("turn/started", "inProgress", "first"),
                                     ("turn/completed", "completed", "first"),
                                     ("turn/started", "inProgress", "second"),
                                     ("turn/completed", "failed", "second")]:
            self.bridge.on_message({"method": method, "params": {"threadId": identifier,
                                    "turn": {"id": turn, "status": status}}})
        snapshot = self.bridge.snapshot(identifier)
        self.assertEqual(snapshot["selected"]["completedTurnId"], "first")
        self.assertEqual(next(s for s in snapshot["sessions"] if s["id"] == identifier)["completedTurnId"], "first")
        restarted = Bridge(self.data, self.root, rpc_factory=FakeRPC)
        try:
            self.assertEqual(restarted.snapshot(identifier)["selected"]["completedTurnId"], "first")
        finally:
            restarted.store.db.close()

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

    def test_token_usage_event_is_persisted_and_survives_restart(self):
        identifier = self.create()
        counts = {"totalTokens": 1200, "inputTokens": 1000, "cachedInputTokens": 600,
                  "outputTokens": 200, "reasoningOutputTokens": 80}
        usage = {"total": counts, "last": counts, "modelContextWindow": 200000}
        self.bridge.on_message({"method": "thread/tokenUsage/updated", "params": {
            "threadId": identifier, "turnId": "usage-turn", "tokenUsage": usage}})
        self.assertEqual(self.bridge.snapshot(identifier)["selected"]["tokenUsage"], usage)
        restarted = Bridge(self.data, self.root, rpc_factory=FakeRPC)
        try:
            self.assertEqual(restarted.snapshot(identifier)["selected"]["tokenUsage"], usage)
        finally:
            restarted.store.db.close()

    def test_usage_keeps_multiple_buckets_and_refetches_sparse_updates(self):
        limits = {"rateLimits": {"limitId": "codex"}, "rateLimitsByLimitId": {
            "codex": {"primary": {"usedPercent": 25, "windowDurationMins": 300}},
            "other": {"secondary": {"usedPercent": 40}}}}
        self.bridge.rpc.request = Mock(return_value=limits)
        first = self.bridge.dispatch({"action": "usage"})["result"]
        self.assertEqual(set(first["rateLimitsByLimitId"]), {"codex", "other"})
        self.assertIsNone(first["threadUsage"])
        self.bridge.dispatch({"action": "usage"})
        self.assertEqual(self.bridge.rpc.request.call_count, 1)
        self.bridge.on_message({"method": "account/rateLimits/updated", "params": {"rateLimits": {"limitId": "codex"}}})
        self.bridge.dispatch({"action": "usage"})
        self.assertEqual(self.bridge.rpc.request.call_count, 2)

    def test_usage_error_preserves_previous_values_and_never_implies_zero(self):
        self.bridge.rpc.request = Mock(side_effect=BridgeError("not available"))
        unavailable = self.bridge.usage({})
        self.assertIsNone(unavailable.get("rateLimits"))
        self.assertIsNone(unavailable["updatedAt"])
        self.assertEqual(unavailable["error"], "not available")
        limits = {"rateLimits": {"primary": {"usedPercent": 50}}}
        self.bridge.rpc.request = Mock(return_value=limits)
        fresh = self.bridge.usage({})
        self.bridge.rpc.request = Mock(side_effect=BridgeError("offline"))
        stale = self.bridge.usage({"refresh": True})
        self.assertEqual(stale["rateLimits"], fresh["rateLimits"])
        self.assertEqual(stale["updatedAt"], fresh["updatedAt"])
        self.assertEqual(stale["error"], "offline")

    def test_full_access_applies_to_new_threads_and_loaded_turns(self):
        result = self.bridge.dispatch({"action": "create", "cwd": str(self.project), "accessMode": "fullAccess", "operationId": "full-create"})
        self.assertTrue(result["ok"], result)
        start = next(p for m, p in self.bridge.rpc.calls if m == "thread/start")
        self.assertEqual(start["sandbox"], "danger-full-access")
        self.assertEqual(start["approvalPolicy"], "never")
        request = {"action": "send", "sessionId": result["result"]["id"], "text": "hello", "accessMode": "fullAccess", "operationId": "full-send"}
        self.assertTrue(self.bridge.dispatch(request)["ok"])
        turn = next(p for m, p in self.bridge.rpc.calls if m == "turn/start")
        self.assertEqual(turn["sandboxPolicy"], {"type": "dangerFullAccess"})
        self.assertEqual(turn["approvalPolicy"], "never")
        self.assertEqual(self.bridge.snapshot(request["sessionId"])["selected"]["accessMode"], "fullAccess")

        self.bridge.sessions[request["sessionId"]]["status"] = "completed"
        self.assertTrue(self.bridge.dispatch(dict(request, accessMode="default", operationId="back-to-default"))["ok"])
        turn = [p for m, p in self.bridge.rpc.calls if m == "turn/start"][-1]
        self.assertEqual(turn["approvalPolicy"], "untrusted")
        self.assertEqual(turn["sandboxPolicy"], {"type": "workspaceWrite", "writableRoots": [str(self.project)], "networkAccess": False})

    def test_invalid_access_mode_does_not_start_a_thread(self):
        result = self.bridge.dispatch({"action": "create", "cwd": str(self.project), "accessMode": "typo", "operationId": "invalid-access"})
        self.assertFalse(result["ok"])
        self.assertEqual(self.bridge.rpc.calls, [])

    def test_status_reconciles_accepted_send_without_executing_again(self):
        _, request = self.send()
        calls = list(self.bridge.rpc.calls)
        result = self.bridge.dispatch({"action": "operationStatus", "operation": request})
        self.assertEqual(result["result"]["state"], "accepted")
        self.assertEqual(self.bridge.rpc.calls, calls)
        with self.assertRaises(BridgeError):
            self.bridge.dispatch({"action": "operationStatus", "operation": dict(request, text="different")})

    def test_status_only_releases_explicit_rejections(self):
        identifier = self.create()
        request = {"action": "send", "sessionId": identifier, "text": "hello", "operationId": "status-rejection"}
        self.assertEqual(self.bridge.store.operation_status(request)["state"], "missing")
        self.bridge.rpc.request = Mock(side_effect=BridgeError("thread not loaded: " + identifier))
        self.assertFalse(self.bridge.dispatch(request)["ok"])
        self.assertEqual(self.bridge.store.operation_status(request)["state"], "rejected")

        self.bridge.sessions[identifier]["status"] = "idle"
        request = dict(request, operationId="status-timeout")
        self.bridge.rpc.request = Mock(side_effect=BridgeError("Codex 请求超时，操作可能已经执行"))
        self.assertFalse(self.bridge.dispatch(request)["ok"])
        self.assertEqual(self.bridge.store.operation_status(request)["state"], "unknown")
        self.bridge.store.db.execute("UPDATE operations SET value=NULL WHERE id=?", (request["operationId"],))
        self.bridge.store.db.commit()
        self.assertEqual(self.bridge.store.operation_status(request)["state"], "unknown")

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
        messages = self.bridge.snapshot(identifier)["selected"]["messages"]
        self.assertEqual(next(m for m in messages if m["id"] == "msg-1")["text"], "authoritative")

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
        self.assertFalse(any(m.get("fake") for m in self.bridge.sessions[identifier]["messages"]))

    def test_optimistic_user_message_is_accepted_and_deduplicated_by_operation(self):
        identifier, request = self.send()
        local_id = "local:" + request["operationId"]
        self.assertEqual(self.bridge.sessions[identifier]["messages"][0]["id"], local_id)
        self.assertEqual(self.bridge.sessions[identifier]["messages"][0]["status"], "accepted")
        for method in ["item/started", "item/completed"]:
            self.bridge.on_message({"method": method, "params": {"threadId": identifier,
                "item": {"id": "server-user", "type": "userMessage", "content": [{"type": "text", "text": "hello"}]}}})
        self.assertEqual(len(self.bridge.sessions[identifier]["messages"]), 1)

        self.assertEqual(self.bridge.sessions[identifier]["messages"][0]["id"], local_id)
        self.assertEqual(self.bridge.sessions[identifier]["messages"][0]["sourceItemId"], "server-user")
        self.assertTrue(self.bridge.dispatch(request)["ok"])
        self.assertEqual(len(self.bridge.sessions[identifier]["messages"]), 1)

    def test_user_message_exists_while_waiting_for_turn_acknowledgement(self):
        identifier = self.create()
        original = self.bridge.rpc.request
        observed = []

        def delayed(method, params):
            if method == "turn/start":
                messages = self.bridge.snapshot(identifier)["selected"]["messages"]
                observed.append((messages[0]["text"], messages[0]["status"]))
            return original(method, params)

        self.bridge.rpc.request = delayed
        result = self.bridge.dispatch({"action": "send", "sessionId": identifier, "text": "Immediate", "operationId": "immediate-before-ack"})
        self.assertTrue(result["ok"])
        self.assertEqual(observed, [("Immediate", "sending")])

    def test_identical_prompts_in_distinct_turns_stay_distinct(self):
        identifier, request = self.send()
        self.bridge.sessions[identifier]["status"] = "completed"
        second = dict(request, operationId="second-identical-send")
        self.assertTrue(self.bridge.dispatch(second)["ok"])
        self.bridge.on_message({"method": "item/completed", "params": {"threadId": identifier,
            "item": {"id": "second-server-user", "type": "userMessage", "content": [{"type": "text", "text": "hello"}]}}})
        messages = self.bridge.sessions[identifier]["messages"]
        self.assertEqual([m["id"] for m in messages], ["local:send-operation", "local:second-identical-send"])

    def test_user_message_remains_pending_when_turn_request_times_out(self):
        identifier = self.create()
        self.bridge.rpc.request = Mock(side_effect=BridgeError("timeout"))
        request = {"action": "send", "sessionId": identifier, "text": "hello", "operationId": "pending-timeout"}
        self.assertFalse(self.bridge.dispatch(request)["ok"])
        self.assertEqual(self.bridge.sessions[identifier]["messages"][0]["status"], "unknown")
        self.assertFalse(self.bridge.dispatch(request)["ok"])
        self.assertEqual(self.bridge.rpc.request.call_count, 1)

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

    def test_custom_title_survives_catalog_and_open(self):
        self.import_history()
        self.bridge.session_metadata({"sessionId": "cli-history", "title": "My title", "pinned": True})
        self.bridge.catalog({})
        self.bridge.open_session({"sessionId": "cli-history"})
        self.assertEqual(self.bridge.sessions["cli-history"]["title"], "My title")
        self.assertTrue(self.bridge.sessions["cli-history"]["pinned"])

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

    def test_full_access_is_applied_when_resuming_cli_history(self):
        self.import_history()
        result = self.bridge.dispatch({"action": "send", "sessionId": "cli-history", "text": "continue", "accessMode": "fullAccess", "operationId": "full-resume"})
        self.assertTrue(result["ok"], result)
        resume = next(p for m, p in self.bridge.rpc.calls if m == "thread/resume")
        self.assertEqual(resume["approvalPolicy"], "never")
        self.assertEqual(resume["sandbox"], "danger-full-access")
        turn = next(p for m, p in self.bridge.rpc.calls if m == "turn/start")
        self.assertEqual(turn["sandboxPolicy"], {"type": "dangerFullAccess"})

    def test_legacy_item_history_pages_without_resuming(self):
        self.import_history()
        original = self.bridge.rpc.request

        def legacy(method, params):
            if method == "thread/items/list":
                raise BridgeError("thread/items/list is not supported yet")
            if method == "thread/read" and params.get("includeTurns"):
                return {"thread": {"turns": [{"items": [
                    {"id": str(i), "type": "agentMessage", "text": "reply"} for i in range(85)]}]}}
            return original(method, params)

        self.bridge.rpc.request = legacy
        self.bridge.open_session({"sessionId": "cli-history"})
        selected = self.bridge.snapshot("cli-history")["selected"]
        self.assertEqual([m["id"] for m in selected["messages"]], [str(i) for i in range(45, 85)])
        page = self.bridge.history_page({"sessionId": "cli-history", "cursor": selected["historyCursor"]})
        self.assertEqual([m["id"] for m in page["messages"]], [str(i) for i in range(5, 45)])
        page = self.bridge.history_page({"sessionId": "cli-history", "cursor": page["nextCursor"]})
        self.assertEqual([m["id"] for m in page["messages"]], [str(i) for i in range(5)])
        self.assertIsNone(page["nextCursor"])
        self.assertNotIn("cli-history", self.bridge.loaded)

    def test_missing_empty_app_thread_is_recreated_only_on_send(self):
        identifier = self.create()
        self.bridge.loaded.clear()
        self.bridge.sessions[identifier].pop("origin", None)  # Original 0.2 session format.
        original = self.bridge.rpc.request

        def missing(method, params):
            if method == "thread/read" and params["threadId"] == identifier:
                raise BridgeError("thread not loaded: " + identifier)
            if method == "thread/start":
                return {"thread": {"id": "replacement-thread"}}
            return original(method, params)

        self.bridge.rpc.request = missing
        self.bridge.open_session({"sessionId": identifier})
        self.assertTrue(self.bridge.sessions[identifier]["needsRecreation"])
        self.assertFalse(any(m == "turn/start" for m, _ in self.bridge.rpc.calls))
        result = self.bridge.dispatch({"action": "send", "sessionId": identifier, "text": "hello", "operationId": "recover-empty"})
        self.assertTrue(result["ok"], result)
        self.assertEqual(self.bridge.sessions[identifier]["remoteThreadId"], "replacement-thread")
        self.assertEqual(self.bridge.sessions[identifier]["status"], "inProgress")
        self.assertEqual(next(p for m, p in self.bridge.rpc.calls if m == "turn/start")["threadId"], "replacement-thread")
        self.bridge.stop({"sessionId": identifier})
        self.assertEqual(self.bridge.rpc.calls[-1][1]["threadId"], "replacement-thread")

    def test_missing_imported_thread_never_silently_loses_history(self):
        self.import_history()
        self.bridge.rpc.request = Mock(side_effect=BridgeError("thread not loaded: cli-history"))
        result = self.bridge.dispatch({"action": "send", "sessionId": "cli-history", "text": "continue", "operationId": "missing-imported"})
        self.assertFalse(result["ok"])
        self.bridge.rpc.request.assert_called_once_with("thread/read", {"threadId": "cli-history"})

    def test_unsupported_turn_pagination_keeps_external_task_read_only(self):
        self.import_history()
        original = self.bridge.rpc.request

        def legacy(method, params):
            if method in {"thread/turns/list", "thread/items/list"}:
                raise BridgeError(method + " is not supported yet")
            if method == "thread/read" and params.get("includeTurns"):
                return {"thread": {"turns": [{"id": "running", "status": "inProgress", "items": []}]}}
            return original(method, params)

        self.bridge.rpc.request = legacy
        self.bridge.open_session({"sessionId": "cli-history"})
        self.assertTrue(self.bridge.sessions["cli-history"]["readOnly"])
        self.assertNotIn("cli-history", self.bridge.loaded)

    def test_closed_thread_is_resumed_before_next_send(self):
        self.import_history()
        self.bridge.loaded.add("cli-history")
        self.bridge.on_message({"method": "thread/closed", "params": {"threadId": "cli-history"}})
        self.assertNotIn("cli-history", self.bridge.loaded)
        result = self.bridge.dispatch({"action": "send", "sessionId": "cli-history", "text": "continue", "operationId": "send-after-close"})
        self.assertTrue(result["ok"], result)
        self.assertTrue(any(m == "thread/resume" for m, _ in self.bridge.rpc.calls))

    def test_cached_not_loaded_rejection_can_retry_but_timeout_cannot(self):
        self.import_history()
        original = self.bridge.rpc.request
        request = {"action": "send", "sessionId": "cli-history", "text": "continue", "operationId": "preflight-retry"}
        self.bridge.rpc.request = Mock(side_effect=BridgeError("thread not loaded: cli-history"))
        self.assertFalse(self.bridge.dispatch(request)["ok"])
        self.bridge.rpc.request = original
        self.assertTrue(self.bridge.dispatch(request)["ok"])
        self.assertTrue(self.bridge.dispatch(request)["ok"])
        self.assertEqual(sum(m == "turn/start" for m, _ in self.bridge.rpc.calls), 1)

        self.bridge.sessions["cli-history"]["status"] = "completed"
        request = dict(request, operationId="timeout-cannot-retry")
        self.bridge.rpc.request = Mock(side_effect=BridgeError("Codex 请求超时"))
        self.assertFalse(self.bridge.dispatch(request)["ok"])
        self.assertFalse(self.bridge.dispatch(request)["ok"])
        self.assertEqual(self.bridge.rpc.request.call_count, 1)

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
