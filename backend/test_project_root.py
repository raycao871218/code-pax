"""Agent worktrees and subfolders must not become separate sidebar projects."""
import tempfile
import unittest
from pathlib import Path

from bridge import Bridge
from test_bridge import FakeRPC


class ProjectRootTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        (self.root / "state").mkdir()
        self.repo = self.root / "app"
        (self.repo / ".git").mkdir(parents=True)
        (self.repo / "src" / "deep").mkdir(parents=True)
        self.bridge = Bridge(self.root / "state", self.root, rpc_factory=FakeRPC)

    def tearDown(self):
        self.bridge.store.db.close()
        self.temp.cleanup()

    def root_of(self, path):
        self.bridge._roots.clear()
        return self.bridge.project_root(str(path))

    def test_repository_root_and_plain_folders_are_unchanged(self):
        self.assertEqual(self.root_of(self.repo), str(self.repo))
        plain = self.root / "notes"
        plain.mkdir()
        self.assertEqual(self.root_of(plain), str(plain))

    def test_subfolder_collapses_to_repository(self):
        self.assertEqual(self.root_of(self.repo / "src" / "deep"), str(self.repo))

    def test_git_worktree_collapses_to_main_repository(self):
        tree = self.root / "elsewhere" / "feature"
        tree.mkdir(parents=True)
        (tree / ".git").write_text("gitdir: %s/.git/worktrees/feature\n" % self.repo)
        self.assertEqual(self.root_of(tree), str(self.repo))

    def test_agent_directory_collapses_even_when_worktree_was_deleted(self):
        gone = self.repo / ".claude" / "worktrees" / "gone"  # never created on disk
        self.assertEqual(self.root_of(gone), str(self.repo))
        self.assertEqual(self.root_of(self.repo / ".codex" / "tmp"), str(self.repo))

    def test_explicitly_added_project_always_wins(self):
        package = self.repo / "src"
        self.bridge.projects[str(package)] = "src"
        self.assertEqual(self.root_of(package), str(package))
        self.assertEqual(self.root_of(package / "deep"), str(package))

    def test_never_leaves_the_work_root(self):
        tree = self.root / "wt"
        tree.mkdir()
        (tree / ".git").write_text("gitdir: /outside/repo/.git/worktrees/wt\n")
        self.assertEqual(self.root_of(tree), str(tree))

    def test_snapshot_lists_one_project_for_many_agent_directories(self):
        for index, path in enumerate([self.repo, self.repo / "src", self.repo / ".claude" / "worktrees" / "a"]):
            identifier = "claude:%d" % index
            self.bridge.sessions[identifier] = {"id": identifier, "title": "t", "cwd": str(path), "status": "idle",
                "updatedAt": index, "origin": "claude", "messages": [], "approvals": [], "diff": ""}
        snapshot = self.bridge.snapshot(None)
        self.assertEqual([p["id"] for p in snapshot["projects"]], [str(self.repo)])
        self.assertEqual({s["cwd"] for s in snapshot["sessions"]}, {str(self.repo)})


if __name__ == "__main__":
    unittest.main()


class AgentWorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        (self.root / "state").mkdir()
        self.job = self.root / ".agent-ops" / "work" / "job-1"
        self.job.mkdir(parents=True)
        self.app = self.root / "app"
        self.app.mkdir()
        self.bridge = Bridge(self.root / "state", self.root, rpc_factory=FakeRPC)

    def tearDown(self):
        self.bridge.store.db.close()
        self.temp.cleanup()

    def add(self, identifier, cwd, origin):
        self.bridge.sessions[identifier] = {"id": identifier, "title": identifier, "cwd": str(cwd), "status": "idle",
            "updatedAt": 1, "origin": origin, "messages": [], "approvals": [], "diff": ""}

    def test_detects_hidden_folders_below_the_work_root_only(self):
        self.assertTrue(self.bridge.agent_workspace(str(self.job)))
        self.assertFalse(self.bridge.agent_workspace(str(self.app)))
        self.assertFalse(self.bridge.agent_workspace(str(self.root)))
        self.assertFalse(self.bridge.agent_workspace("/elsewhere/.hidden"))

    def test_imported_sessions_in_hidden_folders_are_not_listed(self):
        self.add("claude:job", self.job, "claude")
        self.add("codex-job", self.job, "codex")
        self.add("claude:app", self.app, "claude")
        snapshot = self.bridge.snapshot(None)
        self.assertEqual([s["id"] for s in snapshot["sessions"]], ["claude:app"])
        self.assertEqual([p["id"] for p in snapshot["projects"]], [str(self.app)])
        self.assertIn("claude:job", self.bridge.sessions)  # kept, only hidden from the list

    def test_chats_started_in_this_app_stay_visible_even_in_hidden_folders(self):
        self.add("claude:mine", self.job, "app")
        self.assertEqual([s["id"] for s in self.bridge.snapshot(None)["sessions"]], ["claude:mine"])
