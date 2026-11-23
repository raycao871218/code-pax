"""Claude Code stream-json/control-protocol transport, using only the stdlib.

The protocol follows anthropics/claude-agent-sdk-python's subprocess transport.
One process owns one turn; later turns resume its persisted Claude session.
No CLI transcript or credentials are copied into another provider's store.
"""
import json
import os
import signal
import subprocess
import threading
import time
import uuid
import hashlib
import re
from pathlib import Path

from terminal_runtime import launch_configuration

MAX_LINE = 8 * 1024 * 1024


IMPORT_BATCH = 20          # transcripts parsed per sync; the rest arrive on later syncs
IMPORT_MAX_BYTES = 20 * 1024 * 1024
IMPORT_MAX_MESSAGES = 300
IMPORT_ACTIVE_SECONDS = 20  # a transcript written this recently is probably in use elsewhere
_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def claude_projects_directory():
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "projects"


def _text_blocks(content):
    if isinstance(content, str):
        return content
    return "\n".join(b.get("text", "") for b in content
                     if isinstance(b, dict) and b.get("type") == "text")


def parse_transcript(path):
    """Read one Claude Code JSONL transcript.

    Returns ``{"cwd", "title", "customTitle", "messages"}``; ``cwd`` is None when the
    file records no working directory. Entries written by subagents, meta/system
    injections and unreadable lines are skipped, never fatal.
    """
    cwd = title = custom = None
    messages, tools = [], {}
    with open(path, "rb") as handle:
        for raw in handle:
            if len(raw) > MAX_LINE:
                continue
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(entry, dict):
                continue
            kind = entry.get("type")
            if kind == "custom-title" and entry.get("customTitle"):
                custom = str(entry["customTitle"])
                continue
            if entry.get("isSidechain") or entry.get("isMeta"):
                continue
            if not cwd and isinstance(entry.get("cwd"), str):
                cwd = entry["cwd"]
            message = entry.get("message")
            if kind not in {"user", "assistant"} or not isinstance(message, dict):
                continue
            key = str(entry.get("uuid") or len(messages))
            content = message.get("content")
            if kind == "user":
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "tool_result":
                            item = tools.get(block.get("tool_use_id"))
                            if item:
                                value = block.get("content", "")
                                output = value if isinstance(value, str) else "\n".join(
                                    b.get("text", "") for b in value
                                    if isinstance(b, dict) and b.get("type") == "text")
                                item.update(text=item["text"] + "\n" + output,
                                            status="failed" if block.get("is_error") else "completed")
                text = _text_blocks(content).strip()
                # Slash-command echoes and hook output are CLI plumbing, not conversation.
                if text and not text.startswith(("<command-", "<local-command", "<system-reminder")):
                    messages.append({"id": key, "kind": "userMessage", "text": text, "status": "completed"})
                    title = title or text
            else:
                for index, block in enumerate(content if isinstance(content, list) else []):
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") == "text" and block.get("text", "").strip():
                        messages.append({"id": key + ":" + str(index), "kind": "agentMessage",
                                         "text": block["text"], "status": "completed"})
                    elif block.get("type") == "tool_use":
                        name, value = block.get("name", "Tool"), block.get("input", {})
                        item = {"id": str(block.get("id") or key + ":" + str(index)),
                                "kind": "commandExecution" if name == "Bash" else "toolCall",
                                "text": name + "\n" + json.dumps(value, ensure_ascii=False, indent=2),
                                "status": "completed"}
                        tools[block.get("id")] = item
                        messages.append(item)
    return {"cwd": cwd, "title": (custom or title or "").strip(), "customTitle": bool(custom),
            "messages": messages[-IMPORT_MAX_MESSAGES:]}


def configuration(raw=None, model=None):
    value = dict(raw or {})
    value.setdefault("executable", "claude")
    value["model"] = model or value.get("model", "")
    if value["model"].startswith("-"):
        raise ValueError("无效的 Claude 模型名称。")
    if value.get("modelArgument", "--model") != "--model":
        raise ValueError("Claude 聊天的模型参数必须为 --model。")
    argv, environment = launch_configuration("claude", value)
    # These flags belong to the adapter, not a terminal's saved launch options.
    reserved = {"-p", "--print", "-r", "--resume", "-c", "--continue", "--session-id",
                "--fork-session", "--no-session-persistence", "--input-format", "--output-format",
                "--permission-prompt-tool", "--permission-mode", "--dangerously-skip-permissions",
                "--allow-dangerously-skip-permissions", "--replay-user-messages", "--effort"}
    if any(arg.split("=", 1)[0] in reserved for arg in argv[1:]):
        raise ValueError("Claude 聊天的会话、协议与权限参数由 App 管理，请移除冲突的启动参数。")
    return argv, environment


class ClaudeTurn:
    def __init__(self, argv, environment, cwd, session_id, resume, access_mode, content, callback, effort=None):
        self.callback = callback
        self.content = content
        self.lock = threading.RLock()
        self.cleanup_lock = threading.Lock()
        self.pending = {}
        self.initialized = False
        self.server_info = None
        self.finished = False
        self.stopping = False
        self.stderr = ""
        self.ready = threading.Event()
        self.closed = threading.Event()
        self.stderr_closed = threading.Event()
        self.init_id = uuid.uuid4().hex
        args = argv + ["--print", "--verbose", "--input-format", "stream-json",
                       "--output-format", "stream-json", "--include-partial-messages",
                       "--permission-prompt-tool", "stdio", "--permission-mode",
                       "bypassPermissions" if access_mode == "fullAccess" else "default",
                       "--resume" if resume else "--session-id", session_id]
        if effort:
            args += ["--effort", effort]
        env = dict(os.environ, **environment)
        env.pop("CLAUDECODE", None)
        self.process = subprocess.Popen(args, cwd=cwd, env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        start_new_session=True)

    def start(self):
        threading.Thread(target=self._stderr, daemon=True).start()
        threading.Thread(target=self._read, daemon=True).start()
        try:
            self.write({"type": "control_request", "request_id": self.init_id,
                        "request": {"subtype": "initialize", "hooks": None}})
        except Exception:
            self.close()
            raise
        threading.Thread(target=self._startup_timeout, daemon=True).start()

    def write(self, message):
        with self.lock:
            if self.process.poll() is not None:
                raise RuntimeError("Claude 进程已退出，请查看会话错误后重新发送。")
            self.process.stdin.write((json.dumps(message, ensure_ascii=False) + "\n").encode())
            self.process.stdin.flush()

    def _startup_timeout(self):
        if not self.ready.wait(60) and not self.closed.is_set():
            self.callback({"type": "transport_error", "error": "Claude 初始化超时，请检查 CLI 版本和服务器登录状态。"})
            self.close()

    def _stderr(self):
        try:
            while True:
                data = self.process.stderr.read(1024)
                if not data:
                    return
                self.stderr = (self.stderr + data.decode("utf-8", errors="replace"))[-8000:]
        finally:
            self.process.stderr.close()
            self.stderr_closed.set()

    def _read(self):
        try:
            while True:
                line = self.process.stdout.readline(MAX_LINE + 1)
                if not line:
                    break
                if len(line) > MAX_LINE:
                    raise RuntimeError("Claude 返回的单条消息过大。")
                message = json.loads(line)
                if message.get("type") == "control_response":
                    response = message.get("response", {})
                    if response.get("request_id") == self.init_id:
                        if response.get("subtype") != "success":
                            raise RuntimeError(str(response.get("error") or "Claude 初始化失败。"))
                        self.initialized = True
                        self.server_info = response.get("response", {})
                        self.ready.set()
                        if not self.stopping and self.content is not None:
                            self.write({"type": "user", "session_id": "", "parent_tool_use_id": None,
                                        "message": {"role": "user", "content": self.content}})
                    continue
                if message.get("type") == "control_request":
                    request = message.get("request", {})
                    identifier = message["request_id"]
                    if request.get("subtype") != "can_use_tool":
                        self.write({"type": "control_response", "response": {"subtype": "error",
                            "request_id": identifier, "error": "Unsupported control request"}})
                        continue
                    with self.lock:
                        self.pending[identifier] = request
                elif message.get("type") == "control_cancel_request":
                    with self.lock:
                        self.pending.pop(message.get("request_id"), None)
                self.callback(message)
                if message.get("type") == "result":
                    self.finished = True
                    break
        except Exception as error:
            self.callback({"type": "transport_error", "error": str(error)})
        finally:
            self.ready.set()
            self.close()
            self.stderr_closed.wait(1)
            if not self.finished:
                self.callback({"type": "transport_exit", "stopped": self.stopping,
                    "error": self.stderr.strip() or "Claude 未返回完成结果，任务可能已执行部分操作；请检查后再发送新消息。"})
            self.process.stdout.close()
            self.process.stdin.close()
            self.closed.set()

    def answer(self, identifier, decision=None, answers=None):
        with self.lock:
            request = self.pending.get(identifier)
            if request is None:
                raise ValueError("Claude 审批已经失效，请刷新会话。")
            value = dict(request.get("input") or {})
            if request.get("tool_name") == "AskUserQuestion":
                supplied = answers or {}
                resolved = {}
                for index, question in enumerate(value.get("questions", [])):
                    answer = supplied.get(str(index), "").strip()
                    if not answer or len(answer) > 10000:
                        raise ValueError("请回答全部问题。")
                    resolved[question["question"]] = answer
                value["answers"] = resolved
                response = {"behavior": "allow", "updatedInput": value}
            elif decision == "accept":
                response = {"behavior": "allow", "updatedInput": value}
            elif decision in {"decline", "cancel"}:
                response = {"behavior": "deny", "message": "用户拒绝了这次操作。",
                            "interrupt": decision == "cancel"}
                if decision == "cancel":
                    self.stopping = True
            else:
                raise ValueError("无效的审批决定。")
            self.write({"type": "control_response", "response": {"subtype": "success",
                        "request_id": identifier, "response": response}})
            del self.pending[identifier]

    def stop(self):
        self.stopping = True
        self.write({"type": "control_request", "request_id": uuid.uuid4().hex,
                    "request": {"subtype": "interrupt"}})
        def fallback():
            if not self.closed.wait(10):
                self.close()
        threading.Thread(target=fallback, daemon=True).start()

    def close(self):
        with self.cleanup_lock:
            self._close_process()

    def _close_process(self):
        # A reaped CLI has no process group on macOS (killpg may return EPERM).
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            if self.process.poll() is None:
                self.process.terminate()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                if self.process.poll() is None:
                    self.process.kill()
            self.process.wait(timeout=3)


class ClaudeChat:
    def __init__(self, bridge):
        self.bridge = bridge
        self.turns = {}
        self.catalogs = {}
        self.catalog_lock = threading.Lock()

    @staticmethod
    def normalize_models(rows):
        catalog = {}
        default_id = next((row.get("resolvedModel") for row in rows if row.get("value") == "default"), None)
        for row in rows:
            identifier = row.get("resolvedModel") or row.get("value")
            if not isinstance(identifier, str) or not identifier:
                continue
            levels = row.get("supportedEffortLevels", []) if row.get("supportsEffort") else []
            levels = [level for level in levels if level in {"low", "medium", "high", "xhigh", "max"}]
            if identifier not in catalog or row.get("value") != "default":
                aliases = catalog.get(identifier, {}).get("aliases", [])
                catalog[identifier] = {"model": identifier,
                    "displayName": (row.get("displayName") if row.get("value") != "default" else identifier) or identifier,
                    "defaultReasoningEffort": None,
                    "supportedReasoningEfforts": [{"reasoningEffort": level, "description": None} for level in levels],
                    "isDefault": identifier == default_id, "aliases": aliases}
            alias = row.get("value")
            if alias and alias not in catalog[identifier]["aliases"]:
                catalog[identifier]["aliases"].append(alias)
        return list(catalog.values())

    def models(self, request):
        session = self.bridge.session(request["sessionId"]) if request.get("sessionId") else None
        if session and (session.get("agent") != "claude" or session.get("mode") != "chat"):
            raise ValueError("请选择 Claude 聊天会话。")
        cwd = str(self.bridge.project(session["cwd"] if session else str(self.bridge.root)))
        raw = request.get("agentConfiguration")
        argv, environment = configuration(raw)
        key = hashlib.sha256(json.dumps([cwd, argv, environment], sort_keys=True).encode()).hexdigest()
        with self.catalog_lock:
            cached = self.catalogs.get(key)
            if cached and not request.get("refresh") and time.monotonic() - cached[0] < 300:
                return {"models": cached[1]}
            runner = ClaudeTurn(argv, environment, cwd, str(uuid.uuid4()), False, "default", None, lambda event: None)
            try:
                runner.start()
                if not runner.ready.wait(20) or runner.server_info is None:
                    raise ValueError("未能读取 Claude 模型列表，请检查 CLI 版本与登录状态后刷新。")
                models = self.normalize_models(runner.server_info.get("models", []))
                if not models:
                    raise ValueError("Claude CLI 没有返回模型列表，请升级 CLI 后重试。")
                self.catalogs[key] = (time.monotonic(), models)
                return {"models": models}
            finally:
                runner.close()
                runner.closed.wait(5)

    def effort_settings(self, request, session):
        effort = request.get("effort")
        if not effort:
            return None
        if effort not in {"low", "medium", "high", "xhigh", "max"}:
            raise ValueError("无效的 Claude 推理强度。")
        catalog = self.models({"sessionId": session["id"], "agentConfiguration": request.get("agentConfiguration")})["models"]
        model = request.get("model") or session.get("model")
        chosen = next((entry for entry in catalog if entry["model"] == model or model in entry["aliases"]), None) if model else next((entry for entry in catalog if entry["isDefault"]), None)
        if not chosen or effort not in {entry["reasoningEffort"] for entry in chosen["supportedReasoningEfforts"]}:
            raise ValueError("所选 Claude 模型不支持这个推理强度，请刷新模型列表或使用默认强度。")
        return effort

    def create(self, request):
        bridge = self.bridge
        path = bridge.project(request.get("cwd"))
        configuration(request.get("agentConfiguration"), request.get("model"))
        access = bridge.access_settings(request, {"cwd": str(path)})
        remote_id = str(uuid.uuid4())
        identifier = "claude:" + remote_id
        with bridge.lock:
            bridge.sessions[identifier] = {"id": identifier, "remoteThreadId": remote_id,
                "title": path.name or str(path), "cwd": str(path), "status": "idle",
                "turnId": None, "updatedAt": time.time(), "messages": [], "approvals": [],
                "diff": "", "error": None, "origin": "app", "readOnly": False,
                "agent": "claude", "mode": "chat", "historyLoaded": True,
                "model": request.get("model") or (request.get("agentConfiguration") or {}).get("model") or None,
                "effort": None, "accessMode": access["mode"]}
            bridge.store.save(bridge.sessions[identifier])
        bridge.add_project({"cwd": str(path)})
        return {"id": identifier}

    def catalog(self, request):
        """Import Claude Code sessions started outside this app (desktop terminal, IDE).

        Imported sessions resume through the normal ``--resume`` path. The transcript is
        a snapshot: it is re-read only while this app has not sent anything itself.
        """
        bridge = self.bridge
        root = claude_projects_directory()
        files = []
        try:
            for path in root.glob("*/*.jsonl"):
                if _UUID.match(path.stem):
                    try:
                        info = path.stat()
                    except OSError:
                        continue
                    files.append((info.st_mtime, info.st_size, path))
        except OSError:
            pass
        files.sort(reverse=True)
        imported = skipped = parsed = 0
        for mtime, size, path in files[:200]:
            identifier = "claude:" + path.stem
            with bridge.lock:
                known = bridge.sessions.get(identifier)
                if known is not None and known.get("origin") != "claude":
                    continue  # created by this app; it already holds the live history
                active = (time.time() - mtime) < IMPORT_ACTIVE_SECONDS and not (known or {}).get("turnId")
                if known is not None and known["status"] in {"idle", "externalActive"} and not known.get("turnId"):
                    known.update(status="externalActive" if active else "idle", readOnly=active)
                refresh = known is not None and not known.get("turnId") and known.get("claudeFileSize") != size
                if known is not None and not refresh:
                    continue
            if size > IMPORT_MAX_BYTES or parsed >= IMPORT_BATCH:
                if known is None:
                    skipped += 1
                continue
            parsed += 1
            try:
                transcript = parse_transcript(path)
                project = bridge.project(transcript["cwd"]) if transcript["cwd"] else None
            except Exception:  # unreadable file, or a cwd outside the allowed root
                project = None
            if project is None:
                skipped += 1
                continue
            with bridge.lock:
                known = bridge.sessions.get(identifier)
                if known is not None and known.get("turnId"):
                    continue  # this app started using it while we were parsing
                title = (transcript["title"] or project.name or str(project))[:100 if transcript["customTitle"] else 48]
                session = known or {"id": identifier, "remoteThreadId": path.stem, "cwd": str(project),
                    "turnId": None, "approvals": [], "diff": "", "error": None, "origin": "claude",
                    "agent": "claude", "mode": "chat", "model": None, "effort": None,
                    "accessMode": "default", "claudeStarted": True, "historyLoaded": True}
                if known is None or not known.get("customTitle"):
                    session.update(title=title, customTitle=transcript["customTitle"])
                active = (time.time() - mtime) < IMPORT_ACTIVE_SECONDS
                session.update(messages=transcript["messages"], claudeFileSize=size, updatedAt=mtime,
                               status="externalActive" if active else "idle", readOnly=active)
                bridge.sessions[identifier] = session
                bridge.store.save(session)
                imported += known is None
        return {"nextCursor": None, "imported": imported, "skipped": skipped}

    def send(self, request):
        bridge = self.bridge
        session = bridge.session(request.get("sessionId"))
        text = request.get("text", "")
        if not isinstance(text, str) or len(text) > 20000:
            raise ValueError("消息不能超过 20000 个字符。")
        text = text.strip()
        ids = request.get("attachments", [])
        if not isinstance(ids, list) or len(ids) > 8:
            raise ValueError("每次最多发送 8 个附件。")
        if not text and not ids:
            raise ValueError("消息不能为空。")
        with bridge.lock:
            if session["status"] in {"starting", "inProgress", "waiting"}:
                raise ValueError("当前 Claude 会话仍在运行或等待审批。")
            bridge.project(session["cwd"])
        previous = self.turns.get(session["id"])
        if previous and not previous.closed.wait(5):
            raise ValueError("Claude 上一轮正在退出，请稍后再发送。")
        attachments = [bridge.read_attachment(value, session) for value in ids]
        prompt = text or "请查看附件。"
        if attachments:
            prompt += "\n\n附件（位于当前项目，按需要读取）：\n" + "\n".join(
                json.dumps({"name": a["name"], "path": a["path"]}, ensure_ascii=False) for a in attachments)
        model = request.get("model") or session.get("model")
        argv, environment = configuration(request.get("agentConfiguration"), model)
        effort = self.effort_settings(request, session)
        access = bridge.access_settings(request, session)
        turn_id = str(uuid.uuid4())
        runner = ClaudeTurn(argv, environment, session["cwd"], session["remoteThreadId"],
                            bool(session.get("claudeStarted")), access["mode"], prompt,
                            lambda event: self.event(session["id"], turn_id, event), effort=effort)
        with bridge.lock:
            self.turns[session["id"]] = runner
            session.update(status="starting", error=None, diff="", turnId=turn_id,
                           approvals=[], model=model, effort=effort, accessMode=access["mode"])
            session.pop("claudeMessageId", None)
            if not session["messages"] and not session.get("customTitle"):
                session["title"] = (text or attachments[0]["name"])[:48]
            session["messages"].append({"id": "local:" + request["operationId"],
                "kind": "userMessage", "text": text + ("\n\n" if text and attachments else "") +
                "\n".join("📎 " + a["name"] for a in attachments), "attachments": attachments,
                "status": "accepted"})
            session["updatedAt"] = time.time()
            bridge.store.save(session)
        try:
            runner.start()
        except Exception as error:
            self.event(session["id"], turn_id, {"type": "transport_error", "error": str(error)})
        return {"id": turn_id}

    @staticmethod
    def upsert(session, identifier, kind, text, status="completed", delta=False):
        existing = next((m for m in session["messages"] if m["id"] == identifier), None)
        if existing:
            existing.update(text=(existing["text"] + text if delta else text), status=status)
        else:
            session["messages"].append({"id": identifier, "kind": kind, "text": text, "status": status})

    def event(self, identifier, turn_id, event):
        bridge = self.bridge
        with bridge.lock:
            session = bridge.session(identifier)
            if session["turnId"] != turn_id:
                return  # An old process can never overwrite its successor.
            kind = event.get("type")
            if kind == "system" and event.get("subtype") == "init":
                if event.get("session_id") != session["remoteThreadId"]:
                    session.update(status="failed", error="Claude 恢复到了不同会话，已停止以避免丢失上下文。")
                    self.turns[identifier].close()
                else:
                    session.update(claudeStarted=True, status="inProgress")
                    if event.get("model"):
                        session["model"] = event["model"]
            elif kind == "stream_event":
                value = event.get("event", {})
                # Subagent output belongs under its tool, not the parent's reply.
                if event.get("parent_tool_use_id"):
                    return
                if value.get("type") == "message_start":
                    session["claudeMessageId"] = value["message"]["id"]
                elif value.get("type") == "content_block_delta":
                    delta = value.get("delta", {})
                    if delta.get("type") == "text_delta":
                        key = session.get("claudeMessageId", turn_id) + ":" + str(value["index"])
                        self.upsert(session, key, "agentMessage", delta.get("text", ""), "inProgress", True)
            elif kind == "assistant":
                if event.get("parent_tool_use_id"):
                    return
                message = event.get("message", {})
                for index, block in enumerate(message.get("content", [])):
                    if block.get("type") == "text":
                        self.upsert(session, message["id"] + ":" + str(index), "agentMessage", block.get("text", ""))
                    elif block.get("type") == "tool_use":
                        name, value = block.get("name", "Tool"), block.get("input", {})
                        self.upsert(session, block["id"], "commandExecution" if name == "Bash" else "toolCall",
                                    name + "\n" + json.dumps(value, ensure_ascii=False, indent=2), "inProgress")
            elif kind == "user":
                for block in (event.get("message") or {}).get("content", []) if isinstance((event.get("message") or {}).get("content"), list) else []:
                    if block.get("type") != "tool_result":
                        continue
                    key = block.get("tool_use_id")
                    item = next((m for m in session["messages"] if m["id"] == key), None)
                    if item:
                        value = block.get("content", "")
                        output = value if isinstance(value, str) else "\n".join(
                            b.get("text", "") for b in value if isinstance(b, dict) and b.get("type") == "text")
                        item.update(text=item["text"] + "\n" + output,
                                    status="failed" if block.get("is_error") else "completed")
            elif kind == "control_request":
                request = event["request"]
                value = request.get("input", {})
                questions = request.get("tool_name") == "AskUserQuestion"
                params = {"turnId": turn_id, "cwd": session["cwd"], "agent": "claude",
                    "reason": request.get("decision_reason") or "Claude 请求使用工具：" + request.get("tool_name", ""),
                    "command": request.get("tool_name", "") + "\n" + json.dumps(value, ensure_ascii=False, indent=2),
                    "availableDecisions": ["accept", "decline", "cancel"]}
                if questions:
                    params["questions"] = [dict(q, id=str(i)) for i, q in enumerate(value.get("questions", []))]
                session["approvals"].append({"id": bridge.epoch + ":claude:" + event["request_id"],
                    "rpcId": event["request_id"], "method": "item/tool/requestUserInput" if questions else "claude/toolApproval", "params": params})
                session["status"] = "waiting"
            elif kind == "control_cancel_request":
                session["approvals"] = [a for a in session["approvals"] if a["rpcId"] != event.get("request_id")]
                if not session["approvals"] and session["status"] == "waiting":
                    session["status"] = "inProgress"
            elif kind in {"result", "transport_error", "transport_exit"}:
                runner = self.turns.get(identifier)
                stopped = event.get("stopped") or (runner and runner.stopping)
                failed = kind != "result" or event.get("is_error", False)
                session["status"] = "interrupted" if stopped else "failed" if failed else "completed"
                session["approvals"] = []
                if session["status"] == "completed":
                    session["completedTurnId"] = turn_id
                elif not session.get("error"):
                    session["error"] = str(event.get("error") or "\n".join(event.get("errors", [])) or
                                           event.get("result") or "Claude 任务已中断。")[:12000]
                for item in session["messages"]:
                    if item.get("status") == "inProgress":
                        item["status"] = session["status"]
            else:
                return
            session["updatedAt"] = time.time()
            bridge.store.save(session)

    def answer(self, request):
        bridge = self.bridge
        with bridge.lock:
            session = bridge.session(request.get("sessionId"))
            approval = next((a for a in session["approvals"] if a["id"] == request.get("requestId")), None)
            runner = self.turns.get(session["id"])
            if not runner or not approval or approval["params"]["turnId"] != session["turnId"] or session["status"] != "waiting":
                raise ValueError("Claude 审批已经失效，请刷新会话。")
            runner.answer(approval["rpcId"], request.get("decision"), request.get("answers"))
            session["approvals"].remove(approval)
            if not session["approvals"]:
                session["status"] = "inProgress"
            bridge.store.save(session)
        return {}

    def stop(self, request):
        identifier = request.get("sessionId")
        runner = self.turns.get(identifier)
        if not runner or runner.closed.is_set():
            raise ValueError("Claude 会话没有可停止的任务。")
        runner.stop()
        return {}

    def close(self):
        for runner in list(self.turns.values()):
            if not runner.closed.is_set():
                runner.close()
