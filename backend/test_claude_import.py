"""Importing Claude Code sessions that were started outside this app."""
import json
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from bridge import Bridge
from claude_runtime import parse_transcript
from test_bridge import FakeRPC

SESSION = "11111111-2222-3333-4444-555555555555"


def line(**fields):
    return json.dumps(fields)


def transcript(cwd, extra=()):
    return "\n".join([
        line(type="custom-title", customTitle="Fix login bug", sessionId=SESSION),
        line(type="queue-operation", operation="enqueue"),
        line(type="user", uuid="u1", cwd=cwd, message={"role": "user", "content": "please fix login"}),
        line(type="assistant", uuid="a1", message={"role": "assistant", "content": [
            {"type": "thinking", "thinking": "hidden"},
            {"type": "text", "text": "Looking at it."},
            {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls"}}]}),
        line(type="user", uuid="u2", message={"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "t1", "content": "a.py\nb.py"}]}),
        line(type="user", uuid="u3", isMeta=True, message={"role": "user", "content": "meta noise"}),
        line(type="user", uuid="u4", isSidechain=True, message={"role": "user", "content": "subagent"}),
        line(type="user", uuid="u5", message={"role": "user", "content": "<command-name>/clear</command-name>"}),
        "not json at all",
        *extra, ""])


class ParseTests(unittest.TestCase):
    def test_parses_conversation_and_skips_plumbing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / (SESSION + ".jsonl")
            path.write_text(transcript("/work/app"))
            result = parse_transcript(path)
        self.assertEqual(result["cwd"], "/work/app")
        self.assertEqual(result["title"], "Fix login bug")
        self.assertTrue(result["customTitle"])
        self.assertEqual([m["kind"] for m in result["messages"]], ["userMessage", "agentMessage", "commandExecution"])
        self.assertEqual(result["messages"][0]["text"], "please fix login")
        self.assertIn("a.py", result["messages"][2]["text"])
        self.assertEqual(result["messages"][2]["status"], "completed")

    def test_title_falls_back_to_first_prompt(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / (SESSION + ".jsonl")
            path.write_text(line(type="user", uuid="u", cwd="/x", message={"role": "user", "content": "hello there"}))
            self.assertEqual(parse_transcript(path)["title"], "hello there")
            self.assertFalse(parse_transcript(path)["customTitle"])


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        (self.root / "state").mkdir()
        self.project = self.root / "project"
        self.project.mkdir()
        self.config = self.root / "claude-config"
        (self.config / "projects" / "-encoded").mkdir(parents=True)
        self.file = self.config / "projects" / "-encoded" / (SESSION + ".jsonl")
        patcher = patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": str(self.config)})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.bridge = Bridge(self.root / "state", self.root, rpc_factory=FakeRPC)

    def tearDown(self):
        self.bridge.claude.close()
        self.bridge.store.db.close()
        self.temp.cleanup()

    def write(self, cwd, age=3600):
        self.file.write_text(transcript(str(cwd)))
        stamp = time.time() - age
        os.utime(self.file, (stamp, stamp))

    def catalog(self):
        result = self.bridge.dispatch({"action": "claudeCatalog"})
        self.assertTrue(result["ok"], result)
        return result["result"]

    def test_imports_resumable_session_once(self):
        self.write(self.project)
        self.assertEqual(self.catalog()["imported"], 1)
        session = self.bridge.sessions["claude:" + SESSION]
        self.assertEqual((session["agent"], session["mode"], session["origin"]), ("claude", "chat", "claude"))
        self.assertEqual(session["remoteThreadId"], SESSION)
        self.assertTrue(session["claudeStarted"])  # drives --resume on the next turn
        self.assertEqual(session["title"], "Fix login bug")
        self.assertEqual(session["status"], "idle")
        self.assertFalse(session["readOnly"])
        self.assertEqual(self.catalog()["imported"], 0)
        reloaded = self.bridge.dispatch({"action": "historyPage", "sessionId": "claude:" + SESSION})
        self.assertTrue(reloaded["ok"], reloaded)
        self.assertEqual(len(reloaded["result"]["messages"]), 3)

    def test_skips_directories_outside_the_work_root(self):
        self.write("/etc")
        result = self.catalog()
        self.assertEqual((result["imported"], result["skipped"]), (0, 1))
        self.assertNotIn("claude:" + SESSION, self.bridge.sessions)

    def test_recently_written_transcript_is_read_only(self):
        self.write(self.project, age=1)
        self.catalog()
        session = self.bridge.sessions["claude:" + SESSION]
        self.assertEqual(session["status"], "externalActive")
        self.assertTrue(session["readOnly"])
        stamp = time.time() - 3600
        os.utime(self.file, (stamp, stamp))
        self.catalog()
        self.assertEqual(session["status"], "idle")
        self.assertFalse(session["readOnly"])

    def test_picks_up_desktop_progress_until_this_app_sends(self):
        self.write(self.project)
        self.catalog()
        extra = line(type="assistant", uuid="a9", message={"role": "assistant", "content": [{"type": "text", "text": "later"}]})
        self.file.write_text(transcript(str(self.project), [extra]))
        stamp = time.time() - 3000
        os.utime(self.file, (stamp, stamp))
        self.catalog()
        session = self.bridge.sessions["claude:" + SESSION]
        self.assertEqual(session["messages"][-1]["text"], "later")
        session["turnId"] = "local-turn"  # this app has now written to it
        self.file.write_text(transcript(str(self.project), [extra, extra.replace("a9", "b9")]))
        self.catalog()
        self.assertEqual(len(session["messages"]), 4)

    def test_sessions_created_by_this_app_are_never_overwritten(self):
        self.write(self.project)
        self.bridge.sessions["claude:" + SESSION] = {"id": "claude:" + SESSION, "origin": "app", "status": "idle",
            "messages": [{"id": "keep"}], "cwd": str(self.project), "agent": "claude", "mode": "chat"}
        self.assertEqual(self.catalog()["imported"], 0)
        self.assertEqual(self.bridge.sessions["claude:" + SESSION]["messages"], [{"id": "keep"}])

    def test_other_tools_hidden_workspaces_are_not_imported_or_reparsed(self):
        job = self.root / ".agent-ops" / "work" / "job-1"
        job.mkdir(parents=True)
        self.write(job)
        self.assertEqual(self.catalog(), {"nextCursor": None, "imported": 0, "skipped": 0})
        self.assertNotIn("claude:" + SESSION, self.bridge.sessions)
        with patch("claude_runtime.parse_transcript") as parse:
            self.catalog()
            parse.assert_not_called()  # remembered, so it cannot starve the import batch

    def test_status_advertises_import_capability(self):
        self.assertIn("claudeImport", self.bridge.status()["capabilities"])

    def test_missing_claude_directory_is_not_an_error(self):
        self.assertEqual(self.catalog(), {"nextCursor": None, "imported": 0, "skipped": 0})


if __name__ == "__main__":
    unittest.main()
