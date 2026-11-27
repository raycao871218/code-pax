import base64
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from bridge import Bridge, BridgeError, UnavailableCodex, call
from terminal_runtime import MAX_SCROLLBACK, agent_catalog, dimensions, launch_command, launch_configuration


def missing_codex(_callback):
    raise FileNotFoundError("codex")


class AgentCatalogTests(unittest.TestCase):
    def test_custom_argv_preserves_quotes_without_shell_interpolation(self):
        with patch("terminal_runtime.shutil.which", side_effect=lambda name: "/bin/" + name):
            self.assertEqual(launch_command("custom", "tool 'two words' '$(touch /tmp/no)'"),
                             ["/bin/tool", "two words", "$(touch /tmp/no)"])
            self.assertEqual(launch_command("claude"), ["/bin/claude"])
            self.assertEqual(launch_command("gemini"), ["/bin/gemini"])
            self.assertEqual(launch_command("opencode"), ["/bin/opencode"])

    def test_configuration_preserves_path_arguments_model_and_environment_without_shell(self):
        config = dict(executable="/opt/my tool/claude", arguments="--flag 'two words' '$(touch /tmp/no)'",
                      model="model name", modelArgument="-m", environment={"API_KEY": "private"})
        with patch("terminal_runtime.shutil.which", side_effect=lambda exe, **kw: exe):
            argv, env = launch_configuration("claude", config)
        self.assertEqual(argv, ["/opt/my tool/claude", "--flag", "two words", "$(touch /tmp/no)", "-m", "model name"])
        self.assertEqual(env, {"API_KEY": "private"})
        self.assertNotIn("API_KEY", os.environ)
        config["loginCommand"] = "auth-tool login --interactive"
        with patch("terminal_runtime.shutil.which", side_effect=lambda exe, **kw: "/bin/" + exe):
            argv, env = launch_configuration("claude", config, login=True)
        self.assertEqual(argv, ["/bin/auth-tool", "login", "--interactive"])

    def test_invalid_configuration_is_rejected_before_start(self):
        for config in [None, {"environment": []}, {"environment": {"BAD NAME": "a"}},
                       {"environment": {"KEY": "bad\x00value"}}, {"arguments": "bad\narg"},
                       {"model": "test", "modelArgument": "--model --unsafe"}]:
            with self.subTest(config=config), self.assertRaises(ValueError):
                launch_configuration("claude", config)
        with self.assertRaises(ValueError):
            launch_configuration("claude", {}, login=True)

    def test_absent_cli_and_invalid_configuration_are_rejected(self):
        for agent, command in [("unknown", None), ("custom", ""), ("custom", "echo\nhello"),
                               ("custom", "tool 'unclosed")]:
            with self.subTest(agent=agent, command=command), self.assertRaises(ValueError):
                launch_command(agent, command)
        with patch("terminal_runtime.shutil.which", return_value=None), self.assertRaises(ValueError):
            launch_command("claude")

    def test_availability_and_terminal_size_validation(self):
        with patch("terminal_runtime.shutil.which", side_effect=lambda exe: "/bin/claude" if exe == "claude" else None):
            self.assertEqual([a["id"] for a in agent_catalog() if a["available"]], ["claude"])
        for cols, rows in [(True, 30), (19, 30), (4000, 30), (80, 0), ("80", 30)]:
            with self.subTest(cols=cols, rows=rows), self.assertRaises(ValueError):
                dimensions(cols, rows)


@unittest.skipUnless(os.name == "posix", "Real PTY integration requires Linux/macOS")
class TerminalIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.project = self.base / "project with spaces"
        self.project.mkdir()
        self.state = self.base / "state"
        self.state.mkdir(mode=0o700)
        self.bridge = Bridge(self.state, self.project, rpc_factory=missing_codex)
        self.handles = []
        self.serial = 0

    def tearDown(self):
        for terminal in self.handles:
            terminal.stop()
            self.assertTrue(terminal.closed.wait(7), "PTY must exit before closing its store")
        self.bridge.store.db.close()
        self.temporary.cleanup()

    def operation(self, action, **fields):
        self.serial += 1
        return self.bridge.dispatch(dict(action=action, operationId="operation-%08d" % self.serial, **fields))

    def create(self, code):
        command = shlex.join([sys.executable, "-u", "-c", code])
        result = self.operation("create", cwd=str(self.project), agent="custom", mode="terminal", command=command)
        self.assertTrue(result["ok"], result)
        identifier = result["result"]["id"]
        with self.bridge.lock:
            terminal = self.bridge.terminals.get(identifier)
        if terminal:
            self.handles.append(terminal)
        return identifier

    def read(self, identifier, offset=0, epoch=None):
        return self.bridge.terminal_read(dict(sessionId=identifier, offset=offset, epoch=epoch or self.bridge.epoch))

    def output(self, identifier):
        data = bytearray()
        offset = 0
        for _ in range(100):
            chunk = self.read(identifier, offset)
            data.extend(base64.b64decode(chunk["data"]))
            offset = chunk["nextOffset"]
            if not chunk["hasMore"]:
                break
        return bytes(data)

    def wait_for(self, predicate):
        deadline = time.monotonic() + 7
        while not predicate():
            if time.monotonic() > deadline:
                self.fail("Timed out waiting for PTY state")
            time.sleep(0.02)

    def test_backend_and_projects_work_without_codex(self):
        self.assertIsInstance(self.bridge.rpc, UnavailableCodex)
        status = self.bridge.status()
        self.assertTrue(status["ready"])
        self.assertFalse(status["codexReady"])
        self.assertIn("terminal", status["capabilities"])
        self.assertNotIn("catalog", status["capabilities"])
        self.assertTrue(self.operation("addProject", cwd=str(self.project))["ok"])
        self.assertTrue(self.bridge.snapshot(None)["ready"])
        with self.assertRaises(BridgeError):
            self.bridge.models()

    def test_terminal_snapshot_preserves_metadata_and_skips_codex_writer_locks(self):
        identifier = self.create("import time; print('READY'); time.sleep(30)")
        result = self.operation("sessionMetadata", sessionId=identifier, title="My CLI", pinned=True)
        self.assertTrue(result["ok"], result)
        with patch("bridge.thread_writer_occupied", return_value=True) as writer:
            snapshot = self.bridge.snapshot(identifier)
        writer.assert_not_called()
        self.assertEqual(snapshot["selected"]["status"], "inProgress")
        self.assertFalse(snapshot["selected"]["readOnly"])
        summary = next(s for s in snapshot["sessions"] if s["id"] == identifier)
        self.assertEqual(summary["mode"], "terminal")
        self.assertEqual(summary["agent"], "custom")
        self.assertEqual(summary["title"], "My CLI")
        self.assertTrue(summary["pinned"])
        self.assertEqual(self.bridge.open_session(dict(sessionId=identifier)), {"id": identifier})
        self.assertEqual(self.bridge.history_page(dict(sessionId=identifier)), {"messages": [], "nextCursor": None})

    def test_preset_configuration_reaches_real_process_and_secrets_are_not_in_session(self):
        config = dict(executable=sys.executable, arguments=shlex.join(["-u", "-c",
            "import os,sys; print(os.environ.get('CONFIG_TEST_SECRET')); print(repr(sys.argv[1:]))"]),
            model="test model", modelArgument="--model", environment={"CONFIG_TEST_SECRET": "configured-secret"})
        result = self.operation("create", cwd=str(self.project), agent="claude", mode="terminal", agentConfiguration=config)
        self.assertTrue(result["ok"], result)
        identifier = result["result"]["id"]
        terminal = self.bridge.terminals.get(identifier)
        if terminal: self.handles.append(terminal)
        self.wait_for(lambda: self.bridge.sessions[identifier]["status"] == "completed")
        output = self.output(identifier).decode()
        self.assertIn("configured-secret", output)
        self.assertIn("['--model', 'test model']", output)
        self.assertEqual(self.bridge.sessions[identifier]["agent"], "claude")
        self.assertNotIn("configured-secret", json.dumps(self.bridge.sessions))
        self.assertNotIn("configured-secret", str(self.bridge.store.db.execute("SELECT * FROM operations").fetchall()))

    def test_login_uses_saved_command_and_environment_in_real_terminal(self):
        config = dict(executable="unavailable-agent", loginCommand=shlex.join([sys.executable, "-c",
                      "import os; print('LOGIN:'+os.environ['LOGIN_TEST'])"]), environment={"LOGIN_TEST": "ready"}, model="unused")
        result = self.operation("create", cwd=str(self.project), agent="claude", mode="terminal", login=True, agentConfiguration=config)
        self.assertTrue(result["ok"], result)
        identifier = result["result"]["id"]
        terminal = self.bridge.terminals.get(identifier)
        if terminal: self.handles.append(terminal)
        self.wait_for(lambda: self.bridge.sessions[identifier]["status"] == "completed")
        self.assertIn(b"LOGIN:ready", self.output(identifier))

    def test_controlling_tty_cwd_unicode_and_successful_exit(self):
        identifier = self.create("import os; print(os.getcwd()); print(os.isatty(0), os.isatty(1)); print(os.ttyname(0)); print('你好')")
        self.wait_for(lambda: self.bridge.sessions[identifier]["status"] == "completed")
        output = self.output(identifier).decode()
        self.assertIn(str(self.project), output)
        self.assertIn("True True", output)
        self.assertIn("/dev/", output)
        self.assertIn("你好", output)
        self.assertEqual(self.bridge.sessions[identifier]["exitCode"], 0)
        self.assertEqual((self.state / (identifier + ".terminal")).stat().st_mode & 0o777, 0o600)

    def test_live_input_dedupe_resize_and_no_codex_dependency(self):
        identifier = self.create("import os,sys; print('READY'); a=input(); print('FIRST:'+a); print('SIZE:'+str(os.get_terminal_size())); b=input(); print('SECOND:'+b)")
        self.wait_for(lambda: b"READY" in self.output(identifier))
        self.bridge.terminal_resize(dict(sessionId=identifier, cols=90, rows=24))
        request = dict(action="terminalInput", sessionId=identifier, operationId="same-input-operation",
                       dataBase64=base64.b64encode("你好\n".encode()).decode())
        first = self.bridge.dispatch(request)
        self.assertEqual(first, self.bridge.dispatch(request))
        self.assertEqual(first["result"]["written"], len("你好\n".encode()))
        self.wait_for(lambda: b"FIRST:" in self.output(identifier))
        time.sleep(0.1)
        self.assertNotIn(b"SECOND:", self.output(identifier))
        self.assertIn(b"columns=90, lines=24", self.output(identifier))
        self.assertTrue(self.operation("terminalInput", sessionId=identifier,
            dataBase64=base64.b64encode(b"next\n").decode())["ok"])
        self.wait_for(lambda: self.bridge.sessions[identifier]["status"] == "completed")
        self.assertIn(b"SECOND:next", self.output(identifier))

    def test_disconnect_replay_and_output_cursor(self):
        identifier = self.create("import time; print('BEFORE'); time.sleep(0.3); print('AFTER'); time.sleep(5)")
        self.wait_for(lambda: b"BEFORE" in self.output(identifier))
        first = self.read(identifier)
        self.read(identifier, first["nextOffset"])
        replay = self.read(identifier)
        self.assertTrue(replay["replay"])
        self.assertIn(b"BEFORE", base64.b64decode(replay["data"]))
        self.wait_for(lambda: b"AFTER" in self.output(identifier))
        later = self.read(identifier, first["nextOffset"])
        self.assertIn(b"AFTER", base64.b64decode(later["data"]))
        reset = self.read(identifier, 999999, epoch="old-daemon")
        self.assertTrue(reset["reset"])
        self.assertEqual(reset["offset"], 0)
        self.assertEqual(self.bridge.sessions[identifier]["status"], "inProgress")

    def test_terminal_survives_codex_failure_and_cannot_be_sent_a_chat_turn(self):
        identifier = self.create("import time; print('ALIVE'); time.sleep(30)")
        self.bridge.on_message({"method": "bridge/disconnected"})
        self.assertEqual(self.bridge.sessions[identifier]["status"], "inProgress")
        result = self.operation("send", sessionId=identifier, text="hello")
        self.assertFalse(result["ok"])
        with self.assertRaises(BridgeError):
            self.bridge.begin_shutdown()

    def test_stop_terminates_process_and_marks_interrupted(self):
        identifier = self.create("import time; print('READY'); time.sleep(30)")
        self.wait_for(lambda: b"READY" in self.output(identifier))
        self.assertTrue(self.operation("stop", sessionId=identifier)["ok"])
        self.wait_for(lambda: self.bridge.sessions[identifier]["status"] == "interrupted")
        self.assertIsNotNone(self.handles[-1].process.poll())

    def test_failed_exit_and_completed_output_survive_daemon_restart(self):
        identifier = self.create("print('SAVED'); raise SystemExit(7)")
        # Read under the bridge lock: the exit handler sets the status before it records the
        # exit code and saves, so an unlocked read can restart before the row is written.
        def persisted():
            with self.bridge.lock:
                return self.bridge.sessions[identifier]["status"] == "failed"
        self.wait_for(persisted)
        restarted = Bridge(self.state, self.project, rpc_factory=missing_codex)
        try:
            session = restarted.snapshot(identifier)["selected"]
            self.assertEqual(session["mode"], "terminal")
            self.assertEqual(session["exitCode"], 7)
            chunk = restarted.terminal_read(dict(sessionId=identifier, offset=100000, epoch=self.bridge.epoch))
            self.assertTrue(chunk["reset"])
            self.assertIn(b"SAVED", base64.b64decode(chunk["data"]))
            self.assertFalse(restarted.dispatch(dict(action="terminalInput", sessionId=identifier,
                dataBase64="eA==", operationId="finished-input-operation"))["ok"])
            self.assertEqual(restarted.open_session(dict(sessionId=identifier)), {"id": identifier})
        finally:
            restarted.store.db.close()

    def test_large_output_is_bounded_and_archived_cursor_is_consistent(self):
        identifier = self.create("import sys; sys.stdout.write('x'*2500000); sys.stdout.flush()")
        self.wait_for(lambda: self.bridge.sessions[identifier]["status"] == "completed")
        self.assertLessEqual((self.state / (identifier + ".terminal")).stat().st_size, MAX_SCROLLBACK)
        first = self.read(identifier)
        self.assertTrue(first["reset"])
        self.assertGreater(first["offset"], 0)
        second = self.read(identifier, first["nextOffset"])
        self.assertFalse(second["reset"])
        self.assertEqual(second["offset"], first["nextOffset"])

    def test_missing_preset_and_invalid_terminal_input_never_launch(self):
        with patch("terminal_runtime.shutil.which", return_value=None):
            result = self.operation("create", cwd=str(self.project), agent="claude", mode="terminal")
        self.assertFalse(result["ok"])
        self.assertEqual(self.bridge.sessions, {})
        for value in ["%%%", "", base64.b64encode(b"x" * 16385).decode()]:
            with self.subTest(value=value[:10]):
                result = self.operation("terminalInput", sessionId="missing", dataBase64=value)
                self.assertFalse(result["ok"])
        with self.assertRaises(BridgeError):
            self.bridge.terminal_read(dict(sessionId="missing", offset=-1))

    def test_repeated_create_receipt_never_launches_a_second_process(self):
        request = dict(action="create", cwd=str(self.project), mode="terminal", agent="custom",
                       command=shlex.join([sys.executable, "-c", "import time; time.sleep(30)"]),
                       operationId="same-create-operation")
        first = self.bridge.dispatch(request)
        self.assertTrue(first["ok"])
        self.handles.append(self.bridge.terminals[first["result"]["id"]])
        self.assertEqual(first, self.bridge.dispatch(request))
        self.assertEqual(len(self.bridge.sessions), 1)
        self.assertEqual(len(self.bridge.terminals), 1)

    def test_read_only_reopen_does_not_launch_and_terminal_modes_are_explicit(self):
        identifier = self.create("print('DONE')")
        self.wait_for(lambda: self.bridge.sessions[identifier]["status"] == "completed")
        with patch("bridge.Terminal") as spawn:
            self.bridge.open_session(dict(sessionId=identifier))
            self.bridge.terminal_read(dict(sessionId=identifier))
            spawn.assert_not_called()
        for agent, mode in [("gemini", "chat"), ("codex", "invalid")]:
            self.assertFalse(self.operation("create", cwd=str(self.project), agent=agent, mode=mode)["ok"])

    def test_standalone_daemon_multiple_cli_clients_shutdown_and_reopen(self):
        state = self.base / "daemon-state"
        state.mkdir(mode=0o700)
        tools = self.base / "bin"
        tools.mkdir()
        fixture = "#!" + sys.executable + "\nimport sys\nprint('READY', flush=True)\nprint('REPLY:'+input(), flush=True)\n"
        for name in ["claude", "gemini", "opencode", "copilot"]:
            executable = tools / name
            executable.write_text(fixture)
            executable.chmod(0o700)
        env = dict(os.environ, CODEX_IPAD_HOME=str(state), CODEX_HOME=str(self.base / "isolated-codex"),
                   PATH=str(tools))
        script = str(Path(__file__).with_name("bridge.py").resolve())

        def start():
            process = subprocess.Popen([sys.executable, script, "serve", "--root", str(self.project)],
                                       env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.wait_for(lambda: (state / "bridge.sock").exists() or process.poll() is not None)
            self.assertIsNone(process.poll(), "Daemon must boot without Codex installed")
            return process

        def client(request):
            payload = base64.b64encode(json.dumps(request).encode()).decode()
            response = subprocess.run([sys.executable, script, "call", payload], env=env,
                                      capture_output=True, text=True, timeout=10, check=True)
            return json.loads(response.stdout)

        process = start()
        try:
            status = call(state, {"action": "status"})["result"]
            self.assertFalse(status["codexReady"])
            self.assertEqual([a["id"] for a in status["agents"] if a["available"]],
                             ["claude", "gemini", "opencode", "copilot"])
            identifiers = []
            for agent in ["claude", "gemini", "opencode", "copilot"]:
                created = client(dict(action="create", agent=agent, mode="terminal", cwd=str(self.project),
                                      operationId="create-daemon-" + agent))
                self.assertTrue(created["ok"], created)
                identifiers.append(created["result"]["id"])
            self.assertFalse(call(state, {"action": "shutdown"})["ok"], "Active CLIs protect the daemon")
            for identifier in identifiers:
                self.wait_for(lambda: b"READY" in base64.b64decode(client(dict(action="terminalRead", sessionId=identifier))["result"]["data"]))
                self.assertTrue(client(dict(action="terminalInput", sessionId=identifier, dataBase64="aGVsbG8K",
                    operationId="input-daemon-" + identifier))["ok"])
            self.wait_for(lambda: all(s["status"] == "completed" for s in call(state, {"action": "snapshot"})["result"]["sessions"]))
            self.assertTrue(call(state, {"action": "shutdown"})["ok"])
            process.wait(timeout=7)
            process = start()
            for identifier in identifiers:
                chunk = client(dict(action="terminalRead", sessionId=identifier))["result"]
                self.assertIn(b"REPLY:hello", base64.b64decode(chunk["data"]))
                self.assertEqual(chunk["status"], "completed")
            self.assertTrue(call(state, {"action": "shutdown"})["ok"])
            process.wait(timeout=7)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=7)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
