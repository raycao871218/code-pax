"""Linux PTY adapter for CLI agents. No shell interpolation or third-party dependencies."""
import base64
import errno
import json
import os
from pathlib import Path
import select
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time


AGENTS = (
    ("codex", "Codex", "codex"),
    ("claude", "Claude Code", "claude"),
    ("gemini", "Gemini CLI", "gemini"),
    ("opencode", "OpenCode", "opencode"),
    ("copilot", "GitHub Copilot", "copilot"),
)
MAX_SCROLLBACK = 2 * 1024 * 1024
READ_SIZE = 64 * 1024


def agent_catalog():
    return [{"id": key, "title": title, "available": bool(shutil.which(command)),
             "command": command} for key, title, command in AGENTS]


def launch_command(agent, command=None):
    import shlex
    if agent == "custom":
        if not isinstance(command, str) or not command.strip() or len(command) > 4096 or any(
                ord(char) < 32 for char in command):
            raise ValueError("请输入有效的 CLI 命令（不支持换行）。")
        argv = shlex.split(command)
    else:
        executable = next((exe for key, _, exe in AGENTS if key == agent), None)
        if executable is None:
            raise ValueError("不支持的 CLI 类型。")
        argv = [executable]
    if not argv:
        raise ValueError("CLI 命令不能为空。")
    executable = shutil.which(argv[0])
    if not executable:
        raise ValueError("服务器未找到 CLI：" + argv[0])
    argv[0] = executable
    return argv


def launch_configuration(agent, configuration=None, login=False):
    """Resolve per-session settings without shell interpolation or changing daemon env."""
    import re
    import shlex
    if not isinstance(configuration, dict):
        raise ValueError("Agent 配置必须为对象。")
    def field(name, limit=4096):
        value = configuration.get(name, "")
        if not isinstance(value, str) or len(value) > limit or any(ord(c) < 32 for c in value):
            raise ValueError("无效的 Agent 配置字段：" + name)
        return value.strip()
    if agent not in {key for key, _, _ in AGENTS} | {"custom"}:
        raise ValueError("不支持的 CLI 类型。")
    executable = field("executable") or (agent if agent != "custom" else "")
    if login:
        raw = field("loginCommand")
        if not raw:
            raise ValueError("请先配置登录命令。")
        argv = shlex.split(raw)
    else:
        argv = [executable] + shlex.split(field("arguments"))
        model = field("model", 256)
        if model:
            flag = field("modelArgument", 128) or "--model"
            if not flag.startswith("-") or any(c.isspace() for c in flag):
                raise ValueError("模型参数名必须是单个选项，例如 --model。")
            argv += [flag, model]
    environment = configuration.get("environment", {})
    if not isinstance(environment, dict) or len(environment) > 64:
        raise ValueError("环境变量格式不正确（最多 64 项）。")
    for key, value in environment.items():
        if not isinstance(key, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,127}", key):
            raise ValueError("环境变量名称不正确。")
        if not isinstance(value, str) or len(value) > 16384 or "\x00" in value:
            raise ValueError("环境变量值不正确。")
    path = environment.get("PATH", os.environ.get("PATH", ""))
    argv[0] = os.path.expanduser(argv[0]) if argv else ""
    resolved = shutil.which(argv[0], path=path) if argv and argv[0] else None
    if not resolved:
        raise ValueError("服务器未找到配置的 CLI，请检查可执行文件路径或 PATH。")
    argv[0] = resolved
    return argv, dict(environment)


def dimensions(cols, rows):
    if type(cols) is not int or type(rows) is not int or not 20 <= cols <= 400 or not 5 <= rows <= 200:
        raise ValueError("无效的终端尺寸。")
    return struct.pack("HHHH", rows, cols, 0, 0)


class Terminal:
    def __init__(self, directory, identifier, argv, cwd, on_exit, cols=100, rows=30, environment=None):
        import fcntl
        import pty
        import termios
        self.lock = threading.RLock()
        self.input_lock = threading.Lock()
        self.output = bytearray()
        self.base = 0
        self.acknowledged = 0
        self.path = Path(directory) / (identifier + ".terminal")
        self.on_exit = on_exit
        self.master = None
        self.process = None
        self.stopping = False
        self.closed = threading.Event()
        size = dimensions(cols, rows)
        master, slave = pty.openpty()
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, size)
            env = dict(os.environ, **(environment or {}))
            env.update(TERM="xterm-256color", COLORTERM="truecolor")
            # A separate exec helper acquires the controlling tty without preexec_fn in our threaded daemon.
            self.process = subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), "child", json.dumps(argv)],
                stdin=slave, stdout=slave, stderr=slave, cwd=str(cwd), env=env,
                start_new_session=True, close_fds=True)
            os.set_blocking(master, False)
            self.master = master
        except BaseException:
            os.close(master)
            raise
        finally:
            os.close(slave)

    def start(self):
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        code = -1
        try:
            exited_at = None
            while True:
                if select.select([self.master], [], [], 0.2)[0]:
                    try:
                        data = os.read(self.master, READ_SIZE)
                    except OSError as error:
                        if error.errno in (errno.EAGAIN, errno.EINTR):
                            continue
                        if error.errno == errno.EIO:
                            break
                        raise
                    if not data:
                        break
                    with self.lock:
                        self.output.extend(data)
                        if len(self.output) > MAX_SCROLLBACK:
                            drop = len(self.output) - MAX_SCROLLBACK
                            del self.output[:drop]
                            self.base += drop
                if self.process.poll() is not None:
                    exited_at = exited_at or time.monotonic()
                    if time.monotonic() - exited_at > 0.5:
                        break
            code = self.process.wait(timeout=2)
        except Exception:
            self.stop()
            try:
                code = self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                code = -1
        finally:
            with self.input_lock:
                if self.master is not None:
                    os.close(self.master)
                    self.master = None
            try:
                with self.lock:
                    # Private, bounded scrollback is retained for completed sessions and daemon restarts.
                    fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
                    with os.fdopen(fd, "wb") as log:
                        log.write(self.output)
            finally:
                try:
                    self.on_exit(code, self.stopping)
                finally:
                    self.closed.set()

    def read(self, offset):
        with self.lock:
            end = self.base + len(self.output)
            reset = offset < self.base or offset > end
            if offset <= end:
                self.acknowledged = max(self.acknowledged, offset)
            start = self.base if reset else offset
            replay = start < self.acknowledged
            size = min(READ_SIZE, self.acknowledged - start) if replay else READ_SIZE
            data = bytes(self.output[start - self.base:start - self.base + size])
            return {"data": base64.b64encode(data).decode(), "offset": start,
                    "nextOffset": start + len(data), "reset": reset, "hasMore": start + len(data) < end,
                    "replay": replay}

    def write(self, data):
        # Never retry a partial write: the operation receipt records how many bytes were accepted.
        with self.input_lock:
            if self.master is None or self.process.poll() is not None or self.stopping:
                raise ValueError("CLI 已退出，请新建终端会话。")
            if not select.select([], [self.master], [], 1)[1]:
                raise ValueError("终端输入暂不可用，请稍后重试。")
            return os.write(self.master, data)

    def resize(self, cols, rows):
        import fcntl
        import termios
        size = dimensions(cols, rows)
        with self.input_lock:
            if self.master is not None:
                fcntl.ioctl(self.master, termios.TIOCSWINSZ, size)

    def stop(self):
        with self.input_lock:
            if self.process.poll() is not None or self.stopping:
                return
            self.stopping = True
            self._signal(signal.SIGTERM)
        threading.Thread(target=self._kill_later, daemon=True).start()

    def _signal(self, sig):
        try:
            os.killpg(self.process.pid, sig)
        except ProcessLookupError:
            pass

    def _kill_later(self):
        if not self.closed.wait(3):
            self._signal(signal.SIGKILL)


def read_archive(directory, identifier, offset, base=0):
    path = Path(directory) / (identifier + ".terminal")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return {"data": "", "offset": 0, "nextOffset": 0, "reset": offset != 0, "hasMore": False, "replay": True}
    with os.fdopen(fd, "rb") as log:
        end = base + os.fstat(log.fileno()).st_size
        start = base if offset < base or offset > end else offset
        log.seek(start - base)
        data = log.read(READ_SIZE)
    return {"data": base64.b64encode(data).decode(), "offset": start,
            "nextOffset": start + len(data), "reset": offset < base or offset > end, "hasMore": start + len(data) < end,
            "replay": True}


if __name__ == "__main__":
    import fcntl
    import termios
    if len(sys.argv) != 3 or sys.argv[1] != "child":
        raise SystemExit(2)
    argv = json.loads(sys.argv[2])
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    os.execvpe(argv[0], argv, os.environ)
