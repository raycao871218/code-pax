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


def dimensions(cols, rows):
    if type(cols) is not int or type(rows) is not int or not 20 <= cols <= 400 or not 5 <= rows <= 200:
        raise ValueError("无效的终端尺寸。")
    return struct.pack("HHHH", rows, cols, 0, 0)


class Terminal:
    def __init__(self, directory, identifier, argv, cwd, on_exit, cols=100, rows=30):
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
            env = dict(os.environ, TERM="xterm-256color", COLORTERM="truecolor")
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
