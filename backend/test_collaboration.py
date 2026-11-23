import copy
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import uuid

from bridge import Bridge, BridgeError
from collaboration import Teams, tools_for


class TeamRPC:
    def __init__(self, callback):
        self.callback = callback
        self.ready = True
        self.calls, self.responses = [], []
        self.fail_send = False

    def request(self, method, params):
        self.calls.append((method, copy.deepcopy(params)))
        if method == "thread/start":
            return {"thread": {"id": str(uuid.uuid4())}}
        if method == "turn/start":
            if self.fail_send:
                raise BridgeError("transport timeout")
            turn = {"id": str(uuid.uuid4()), "status": "inProgress"}
            self.callback({"method": "turn/started", "params": {"threadId": params["threadId"], "turn": turn}})
            return {"turn": turn}
        if method == "turn/interrupt":
            self.callback({"method": "turn/completed", "params": {"threadId": params["threadId"],
                "turn": {"id": params["turnId"], "status": "interrupted"}}})
        return {}

    def write(self, value):
        self.responses.append(value)


class CollaborationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "projects"
        self.root.mkdir()
        self.repo = self.root / "demo with spaces"
        self.repo.mkdir()
        Teams.git(self.repo, "init", "-b", "main")
        Teams.git(self.repo, "config", "user.name", "Test")
        Teams.git(self.repo, "config", "user.email", "test@example.invalid")
        (self.repo / "original.txt").write_text("base\n")
        Teams.git(self.repo, "add", ".")
        Teams.git(self.repo, "commit", "-m", "initial")
        self.initial = Teams.git(self.repo, "rev-parse", "HEAD")
        self.state = self.base / "state"
        self.state.mkdir()
        self.bridge = Bridge(self.state, self.root, rpc_factory=TeamRPC)
        self.manager = self.bridge.teams
        self.scheduler = patch.object(self.manager, "start")
        self.scheduler.start()
        self.serial = 0

    def tearDown(self):
        self.scheduler.stop()
        self.manager.close()
        self.bridge.store.db.close()
        self.temporary.cleanup()

    def operation(self, action, **values):
        self.serial += 1
        return self.bridge.dispatch(dict(action=action, operationId="operation-%08d" % self.serial, **values))

    def create(self, count=2, limit=2):
        result = self.operation("teamCreate", cwd=str(self.repo), goal="完成独立任务并整合", maxWorkers=limit,
                                tasks=[{"title": "task-%d" % i, "prompt": "创建文件 file-%d.txt 并测试" % i} for i in range(count)])
        self.assertTrue(result["ok"], result)
        return self.manager.runs[result["result"]["id"]]

    def complete(self, task, text="完成并测试", status="completed"):
        session = self.bridge.sessions[task["sessionId"]]
        self.bridge.on_message({"method": "item/completed", "params": {"threadId": session["id"],
            "item": {"id": str(uuid.uuid4()), "type": "agentMessage", "text": text}}})
        self.bridge.on_message({"method": "turn/completed", "params": {"threadId": session["id"],
            "turn": {"id": session["turnId"], "status": status}}})

    def tool(self, task, name, arguments=None, call_id=None, rpc_id=None):
        session = self.bridge.sessions[task["sessionId"]]
        identifier = rpc_id or str(uuid.uuid4())
        self.bridge.on_message({"id": identifier, "method": "item/tool/call", "params": {
            "threadId": session["id"], "turnId": session["turnId"], "callId": call_id or str(uuid.uuid4()),
            "tool": "codepax_team_" + name, "arguments": arguments or {}}})
        deadline = time.monotonic() + 4
        while not any(response["id"] == identifier for response in self.bridge.rpc.responses):
            if time.monotonic() > deadline:
                self.fail("Dynamic tool did not respond")
            time.sleep(0.01)
        return next(response for response in self.bridge.rpc.responses if response["id"] == identifier)["result"]

    def ready_coordinator(self, count=2):
        run = self.create(count)
        self.manager.tick()
        for i, worker in enumerate(run["tasks"][:-1]):
            (Path(worker["worktree"]) / ("file-%d.txt" % i)).write_text("worker %d\n" % i)
            self.complete(worker)
        self.manager.tick()
        self.manager.tick()
        self.assertIsNotNone(run["tasks"][-1]["sessionId"])
        return run

    def finish(self, run):
        coordinator = run["tasks"][-1]
        for worker in run["tasks"][:-1]:
            self.manager.integrate(run["id"], worker["id"])
        self.complete(coordinator, "已整合并验证")
        self.manager.tick()
        self.manager.tick()
        self.assertEqual(run["status"], "completed")
        return coordinator

    def test_real_git_worktrees_limit_concurrency_and_preserve_original(self):
        run = self.create(3, 2)
        self.manager.tick()
        workers = run["tasks"][:-1]
        self.assertEqual(sum(bool(task["sessionId"]) for task in workers), 2)
        self.assertEqual(workers[2]["status"], "queued")
        self.assertNotEqual(workers[0]["worktree"], workers[1]["worktree"])
        (Path(workers[0]["worktree"]) / "only-first.txt").write_text("isolated")
        self.assertFalse((Path(workers[1]["worktree"]) / "only-first.txt").exists())
        self.assertFalse((self.repo / "only-first.txt").exists())
        self.assertEqual(Teams.git(self.repo, "status", "--porcelain"), "")
        self.complete(workers[0])
        self.manager.tick()
        self.manager.tick()
        self.assertIsNotNone(workers[2]["sessionId"])
        self.assertIsNone(run["tasks"][-1]["sessionId"])
        self.assertEqual(Teams.git(self.repo, "rev-parse", "HEAD"), self.initial)

    def test_completed_results_include_untracked_files_and_native_approvals(self):
        run = self.create(1)
        self.manager.tick()
        task = run["tasks"][0]
        identifier = task["sessionId"]
        session = self.bridge.sessions[identifier]
        self.bridge.on_message({"id": 95, "method": "item/commandExecution/requestApproval", "params": {
            "threadId": identifier, "turnId": session["turnId"], "command": "test"}})
        self.manager.tick()
        self.assertEqual(task["status"], "waiting")
        approval = session["approvals"][0]
        self.assertTrue(self.operation("answer", sessionId=identifier, requestId=approval["id"], decision="accept")["ok"])
        (Path(task["worktree"]) / "new.txt").write_text("new file")
        self.complete(task)
        self.manager.tick()
        self.assertEqual(Teams.git(self.repo, "show", task["snapshotCommit"] + ":new.txt"), "new file")
        self.assertEqual(self.bridge.snapshot(None)["projects"], [{"id": str(self.repo), "title": self.repo.name}])
        self.assertIn("new.txt", self.manager.diff(dict(runId=run["id"], taskId=task["id"]))["text"])

    def test_coordinator_integrates_then_user_applies_once(self):
        run = self.ready_coordinator()
        self.finish(run)
        self.assertFalse((self.repo / "file-0.txt").exists())
        request = dict(action="teamApply", runId=run["id"], operationId="apply-same-operation")
        result = self.bridge.dispatch(request)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result, self.bridge.dispatch(request))
        self.assertEqual((self.repo / "file-0.txt").read_text(), "worker 0\n")
        self.assertEqual((self.repo / "file-1.txt").read_text(), "worker 1\n")
        self.assertEqual(Teams.git(self.repo, "status", "--porcelain"), "")
        self.assertEqual(Teams.git(self.repo, "rev-parse", "HEAD"), run["appliedCommit"])

    def test_dirty_or_advanced_original_is_never_overwritten(self):
        run = self.ready_coordinator(1)
        self.finish(run)
        (self.repo / "user.txt").write_text("keep")
        self.assertFalse(self.operation("teamApply", runId=run["id"])["ok"])
        self.assertEqual((self.repo / "user.txt").read_text(), "keep")
        Teams.git(self.repo, "add", "user.txt")
        Teams.git(self.repo, "commit", "-m", "user changed project")
        user_head = Teams.git(self.repo, "rev-parse", "HEAD")
        self.assertFalse(self.operation("teamApply", runId=run["id"])["ok"])
        self.assertEqual(Teams.git(self.repo, "rev-parse", "HEAD"), user_head)

    def test_worker_messages_are_scoped_deduplicated_and_cannot_integrate(self):
        run = self.create()
        self.manager.tick()
        first, second = run["tasks"][:2]
        result = self.tool(first, "message", {"to": second["id"], "text": "接口定为 v1"}, call_id="same-call")
        self.assertTrue(result["success"])
        self.assertTrue(self.tool(first, "message", {"to": second["id"], "text": "接口定为 v1"}, call_id="same-call")["success"])
        self.assertEqual(len(run["messages"]), 1)
        inbox = self.tool(second, "inbox")
        self.assertIn("接口定为 v1", inbox["contentItems"][0]["text"])
        self.assertNotIn("接口定为 v1", self.tool(first, "inbox")["contentItems"][0]["text"])
        self.assertFalse(self.tool(first, "integrate", {"taskId": second["id"]})["success"])
        self.assertFalse(self.tool(first, "message", {"to": "outside-team", "text": "no"})["success"])
        advertised = [call[1]["dynamicTools"] for call in self.bridge.rpc.calls if call[0] == "thread/start"]
        self.assertTrue(all(all(tool["name"] != "codepax_team_integrate" for tool in tools) for tools in advertised))

    def test_spoofed_turn_or_session_membership_cannot_call_team_tools(self):
        run = self.create(1)
        self.manager.tick()
        task = run["tasks"][0]
        self.bridge.sessions[task["sessionId"]]["collaborationTaskId"] = "coordinator"
        self.assertFalse(self.tool(task, "message", {"to": "all", "text": "spoof"})["success"])
        self.assertEqual(run["messages"], [])

    def test_coordinator_conflicts_are_aborted_without_touching_source(self):
        run = self.create()
        self.manager.tick()
        for i, worker in enumerate(run["tasks"][:-1]):
            (Path(worker["worktree"]) / "original.txt").write_text("different %d\n" % i)
            self.complete(worker)
        self.manager.tick()
        self.manager.tick()
        first, second, coordinator = run["tasks"]
        self.manager.integrate(run["id"], first["id"])
        head = Teams.git(coordinator["worktree"], "rev-parse", "HEAD")
        with self.assertRaisesRegex(ValueError, "冲突"):
            self.manager.integrate(run["id"], second["id"])
        self.assertEqual(Teams.git(coordinator["worktree"], "rev-parse", "HEAD"), head)
        self.assertEqual(Teams.git(coordinator["worktree"], "status", "--porcelain"), "")
        self.assertEqual((self.repo / "original.txt").read_text(), "base\n")

    def test_queued_team_protects_shutdown_and_cancel_does_not_launch(self):
        run = self.create()
        with self.assertRaises(BridgeError):
            self.bridge.begin_shutdown()
        self.assertTrue(self.operation("teamCancel", runId=run["id"])["ok"])
        self.manager.tick()
        self.assertEqual(run["status"], "cancelled")
        self.assertFalse(self.bridge.rpc.calls)
        self.assertTrue(all(task["status"] == "cancelled" for task in run["tasks"]))

    def test_cancellation_stops_live_workers_and_does_not_start_coordinator(self):
        run = self.create(3, 1)
        self.manager.tick()
        self.assertTrue(self.operation("teamCancel", runId=run["id"])["ok"])
        self.manager.tick()
        self.assertEqual(run["status"], "cancelled")
        self.assertIsNone(run["tasks"][-1]["sessionId"])
        self.assertEqual(sum(call[0] == "turn/interrupt" for call in self.bridge.rpc.calls), 1)

    def test_uncertain_send_occupies_slot_and_is_not_automatically_retried(self):
        run = self.create(2, 1)
        self.bridge.rpc.fail_send = True
        self.manager.tick()
        self.manager.tick()
        self.assertEqual(run["tasks"][0]["status"], "unknown")
        self.assertIsNone(run["tasks"][1]["sessionId"])
        self.assertFalse(self.operation("teamRetry", runId=run["id"], taskId=run["tasks"][0]["id"])["ok"])
        self.assertEqual(sum(call[0] == "turn/start" for call in self.bridge.rpc.calls), 1)

    def test_restart_preserves_results_and_interrupts_without_auto_execution(self):
        run = self.create(2, 1)
        self.manager.tick()
        self.complete(run["tasks"][0])
        self.manager.tick()
        self.manager.message(dict(runId=run["id"], to="all", text="persist me"))
        restored = Bridge(self.state, self.root, rpc_factory=TeamRPC)
        try:
            copy_run = restored.teams.runs[run["id"]]
            self.assertEqual(copy_run["status"], "interrupted")
            self.assertEqual(copy_run["tasks"][0]["status"], "completed")
            self.assertIsNotNone(copy_run["tasks"][0]["snapshotCommit"])
            self.assertEqual(copy_run["messages"][0]["text"], "persist me")
            self.assertIsNone(restored.teams.thread)
            self.assertEqual(restored.rpc.calls, [])
        finally:
            restored.teams.close()
            restored.store.db.close()

    def test_explicit_retry_reuses_worktree_but_creates_new_session(self):
        run = self.create(2, 1)
        self.manager.tick()
        task = run["tasks"][0]
        before = task["sessionId"]
        (Path(task["worktree"]) / "preserved.txt").write_text("keep")
        self.complete(task, status="failed")
        self.manager.tick()
        self.assertTrue(self.operation("teamRetry", runId=run["id"], taskId=task["id"])["ok"])
        self.manager.tick()
        self.assertNotEqual(task["sessionId"], before)
        self.assertEqual((Path(task["worktree"]) / "preserved.txt").read_text(), "keep")
        self.assertEqual(task["attempt"], 2)

    def test_invalid_specs_and_dirty_repository_do_not_dispatch_agents(self):
        for specs in [[], [{"title": "", "prompt": "x"}], [{"title": "x", "prompt": ""}], [{}] * 9]:
            self.assertFalse(self.operation("teamCreate", cwd=str(self.repo), goal="goal", tasks=specs)["ok"])
        (self.repo / "dirty.txt").write_text("keep")
        result = self.operation("teamCreate", cwd=str(self.repo), goal="goal", tasks=[{"title": "x", "prompt": "y"}])
        self.assertFalse(result["ok"])
        self.assertEqual(self.bridge.rpc.calls, [])

    def test_creation_is_idempotent_and_tools_have_strict_schemas(self):
        request = dict(action="teamCreate", operationId="same-team-create", cwd=str(self.repo), goal="goal",
                       tasks=[{"title": "task", "prompt": "work"}])
        self.assertEqual(self.bridge.dispatch(request), self.bridge.dispatch(request))
        self.assertEqual(len(self.manager.runs), 1)
        self.assertEqual(len(tools_for("coordinator")), 4)
        self.assertTrue(all(tool["inputSchema"]["additionalProperties"] is False for tool in tools_for("worker")))

    def test_cancel_waits_for_inflight_launch_then_interrupts_it(self):
        run = self.create(2, 1)
        entering, release = threading.Event(), threading.Event()
        original = self.bridge.rpc.request
        def request(method, params):
            if method == "thread/start":
                entering.set()
                self.assertTrue(release.wait(3))
            return original(method, params)
        with patch.object(self.bridge.rpc, "request", side_effect=request):
            launching = threading.Thread(target=self.manager.tick)
            launching.start()
            self.assertTrue(entering.wait(3))
            cancelling = threading.Thread(target=lambda: self.manager.cancel({"runId": run["id"]}))
            cancelling.start()
            release.set()
            launching.join(5)
            cancelling.join(5)
            self.assertFalse(launching.is_alive())
            self.assertFalse(cancelling.is_alive())
        self.manager.tick()
        self.assertEqual(run["status"], "cancelled")
        self.assertIsNone(run["tasks"][1]["sessionId"])

    def test_cancel_catches_a_late_turn_started_after_unknown_send(self):
        run = self.create(1)
        self.bridge.rpc.fail_send = True
        self.manager.tick()
        task = run["tasks"][0]
        self.manager.cancel({"runId": run["id"]})
        self.bridge.on_message({"method": "turn/started", "params": {"threadId": task["sessionId"],
            "turn": {"id": "late-turn", "status": "inProgress"}}})
        self.manager.tick()
        self.manager.tick()
        self.assertEqual(run["status"], "cancelled")
        self.assertIn(("turn/interrupt", {"threadId": task["sessionId"], "turnId": "late-turn"}), self.bridge.rpc.calls)

    def test_completed_member_cannot_be_manually_sent_a_new_turn(self):
        run = self.create(1)
        self.manager.tick()
        task = run["tasks"][0]
        self.complete(task)
        before = len(self.bridge.rpc.calls)
        self.assertFalse(self.operation("send", sessionId=task["sessionId"], text="run again")["ok"])
        self.assertEqual(len(self.bridge.rpc.calls), before)

    def test_stale_dynamic_tool_turn_is_rejected(self):
        run = self.create(1)
        self.manager.tick()
        task = run["tasks"][0]
        session = copy.deepcopy(self.bridge.sessions[task["sessionId"]])
        self.manager.handle_tool({"id": "stale-tool", "params": {"turnId": "wrong-turn", "callId": "stale-call",
            "tool": "codepax_team_message", "arguments": {"to": "all", "text": "must not send"}}}, session)
        deadline = time.monotonic() + 3
        while not self.bridge.rpc.responses and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertFalse(self.bridge.rpc.responses[-1]["result"]["success"])
        self.assertEqual(run["messages"], [])

    def test_list_and_detail_stay_below_wire_limit_with_large_history(self):
        run = self.create(8)
        run["goal"] = "目" * 4000
        for task in run["tasks"]:
            task.update(prompt="需" * 8000, result="果" * 12000, error="错" * 4000)
        run["messages"] = [{"id": str(i), "from": "user", "to": "all", "text": "信" * 4000, "createdAt": 0} for i in range(200)]
        for i in range(100):
            self.manager.runs["history-" + str(i)] = copy.deepcopy(run)
        summaries = self.bridge.dispatch({"action": "teamList"})["result"]
        detail = self.bridge.dispatch({"action": "teamRead", "runId": run["id"]})["result"]
        self.assertLess(len(json.dumps(summaries, ensure_ascii=False).encode()), 2 * 1024 * 1024)
        self.assertLess(len(json.dumps(detail, ensure_ascii=False).encode()), 2 * 1024 * 1024)
        self.assertEqual(len(detail["messages"]), 50)
        self.assertEqual(detail["tasks"][0]["result"], "果" * 12000)
        self.assertEqual(summaries["runs"][0]["tasks"][0]["result"], "")


if __name__ == "__main__":
    unittest.main()
