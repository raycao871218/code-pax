#!/usr/bin/env python3
"""Personal Codex bridge. SSH is the transport; no TCP listener or external deps."""
import argparse
import base64
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import socketserver
import sqlite3
import subprocess
import sys
import threading
import time
import uuid

PROTOCOL = 2
MAX_WIRE = 2 * 1024 * 1024
MAX_TEXT = 12000
ACTIVE = {"inProgress", "waiting", "starting"}


def clipped(value, limit=MAX_TEXT):
    text = str(value or "")
    return text if len(text) <= limit else text[:limit] + "\n[内容过长，已截断]"


class BridgeError(Exception):
    pass


class Store:
    def __init__(self, directory):
        self.lock = threading.RLock()
        self.db = sqlite3.connect(directory / "history.sqlite3", check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript("""
          CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, value TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY, digest TEXT NOT NULL, value TEXT);
          CREATE TABLE IF NOT EXISTS projects(path TEXT PRIMARY KEY, title TEXT NOT NULL);
        """)
        self.db.commit()

    def load(self):
        return {key: json.loads(value) for key, value in self.db.execute("SELECT id,value FROM sessions")}

    def load_projects(self):
        return {path: title for path, title in self.db.execute("SELECT path,title FROM projects")}

    def save_project(self, path, title):
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO projects VALUES (?,?)", (path, title))
            self.db.commit()

    def save(self, session):
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO sessions VALUES (?,?)",
                            (session["id"], json.dumps(session, ensure_ascii=False)))
            self.db.commit()

    def operation(self, request, action):
        token = request.get("operationId", "")
        if not isinstance(token, str) or not 8 <= len(token) <= 100:
            raise BridgeError("操作缺少有效的幂等 ID。")
        digest = hashlib.sha256(json.dumps(request, sort_keys=True).encode()).hexdigest()
        with self.lock:
            row = self.db.execute("SELECT digest,value FROM operations WHERE id=?", (token,)).fetchone()
            if row:
                if row[0] != digest:
                    raise BridgeError("同一个操作 ID 不能用于不同的请求。")
                if row[1] is None:
                    raise BridgeError("上次请求结果尚不确定，请先刷新会话，不要重复发送任务。")
                return json.loads(row[1])
            self.db.execute("INSERT INTO operations VALUES (?,?,NULL)", (token, digest))
            self.db.commit()
        try:
            result = {"ok": True, "result": action()}
        except Exception as error:
            result = {"ok": False, "error": str(error)}
        with self.lock:
            self.db.execute("UPDATE operations SET value=? WHERE id=?", (json.dumps(result), token))
            self.db.commit()
        return result


class AppServer:
    def __init__(self, callback, executable="codex"):
        self.callback = callback
        self.pending = {}
        self.lock = threading.Lock()
        self.write_lock = threading.Lock()
        self.next_id = 0
        self.ready = False
        self.process = subprocess.Popen([executable, "app-server", "--listen", "stdio://"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=sys.stderr, text=True, bufsize=1)
        threading.Thread(target=self.read, daemon=True).start()
        try:
            self.request("initialize", {"clientInfo": {"name": "codex_ipad", "title": "Codex iPad", "version": "0.3.0"},
                                        "capabilities": {"experimentalApi": True}})
            self.write({"method": "initialized", "params": {}})
            self.ready = True
        except Exception:
            self.process.terminate()
            raise

    def write(self, message):
        with self.write_lock:
            self.process.stdin.write(json.dumps(message, ensure_ascii=False) + "\n")
            self.process.stdin.flush()

    def request(self, method, params, timeout=25):
        with self.lock:
            self.next_id += 1
            identifier = self.next_id
            future = concurrent.futures.Future()
            self.pending[identifier] = future
        try:
            self.write({"id": identifier, "method": method, "params": params})
            message = future.result(timeout=timeout)
            if "error" in message:
                raise BridgeError(message["error"].get("message", "Codex 请求失败"))
            return message.get("result", {})
        except concurrent.futures.TimeoutError:
            raise BridgeError("Codex 请求超时，操作可能已经执行，请刷新状态后再操作。") from None
        finally:
            with self.lock:
                self.pending.pop(identifier, None)

    def read(self):
        try:
            for line in self.process.stdout:
                if len(line) > 16 * MAX_WIRE:
                    raise BridgeError("Codex 消息超出限制。")
                message = json.loads(line)
                if "method" not in message and "id" in message:
                    with self.lock:
                        future = self.pending.get(message["id"])
                        if future and not future.done():
                            future.set_result(message)
                else:
                    self.callback(message)
        except Exception as error:
            print("app-server reader:", type(error).__name__, file=sys.stderr)
        finally:
            self.ready = False
            with self.lock:
                for future in self.pending.values():
                    if not future.done():
                        future.set_exception(BridgeError("Codex 后台连接已关闭。"))
            self.callback({"method": "bridge/disconnected", "params": {}})


class Bridge:
    def __init__(self, directory, root=None, rpc_factory=AppServer):
        self.directory = directory
        self.root = Path(root or Path.home()).resolve(strict=True)
        self.store = Store(directory)
        self.lock = threading.RLock()
        self.mutations = threading.Lock()
        self.sessions = self.store.load()
        self.projects = self.store.load_projects()
        self.model_catalog = []
        self.models_updated_at = 0
        self.loaded = set()
        self.stopping = False
        self.epoch = uuid.uuid4().hex
        for session in self.sessions.values():
            session["approvals"] = []
            if session["status"] in ACTIVE:
                session["status"] = "interrupted"
                session["error"] = "服务器后台已重启，原任务中断。发送新消息可继续会话。"
            self.store.save(session)
        self.rpc = rpc_factory(self.on_message)

    def project(self, raw):
        if not isinstance(raw, str) or not raw or len(raw) > 4096:
            raise BridgeError("请选择有效项目目录。")
        path = Path(raw).expanduser().resolve(strict=True)
        if not path.is_dir() or not path.is_relative_to(self.root):
            raise BridgeError("项目目录超出配置的工作根目录。")
        # Do not use credential/config folders themselves as project workspaces.
        if any(part in {".ssh", ".codex", ".gnupg"} for part in path.relative_to(self.root).parts):
            raise BridgeError("不能将凭据配置目录作为项目。")
        return path

    def session(self, identifier):
        if identifier not in self.sessions:
            raise BridgeError("会话不存在，请刷新列表。")
        return self.sessions[identifier]

    def status(self):
        # Some CLI releases route account/read through workspace discovery before the
        # first thread exists. The CLI's read-only login status avoids that dependency.
        login = subprocess.run([shutil.which("codex") or "codex", "login", "status"],
                               capture_output=True, timeout=10)
        return {"protocol": PROTOCOL, "ready": self.rpc.ready,
                "version": "0.3.0",
                "root": str(self.root), "authenticated": login.returncode == 0,
                "accountType": "服务器已有登录" if login.returncode == 0 else "尚未登录"}

    def snapshot(self, identifier):
        with self.lock:
            summaries = [{key: s.get(key) for key in ("id", "title", "cwd", "status", "updatedAt", "origin", "model")}
                         for s in sorted(self.sessions.values(), key=lambda s: s["updatedAt"], reverse=True)[:1000]]
            projects = dict(self.projects)
            for summary in summaries:
                projects.setdefault(summary["cwd"], Path(summary["cwd"]).name or summary["cwd"])
            selected = None
            if identifier in self.sessions:
                selected = dict(self.session(identifier))
                selected["messages"] = selected["messages"][-40:]
                selected["historyTruncated"] = len(self.session(identifier)["messages"]) > 40 or bool(selected.get("historyCursor"))
            # Detach from shared dicts before serializing in the request handler.
            return json.loads(json.dumps({"sessions": summaries, "projects": [{"id": p, "title": t} for p, t in sorted(projects.items())], "selected": selected,
                                         "ready": self.rpc.ready}, ensure_ascii=False))

    def add_project(self, request):
        path = self.project(request.get("cwd"))
        with self.lock:
            title = path.name or str(path)
            self.projects[str(path)] = title
            self.store.save_project(str(path), title)
        return {"id": str(path)}

    def catalog(self, request):
        params = {"limit": 50, "sortKey": "updated_at", "sourceKinds": ["cli", "vscode", "exec", "appServer", "unknown"]}
        if request.get("cursor"):
            params["cursor"] = request["cursor"]
        result = self.rpc.request("thread/list", params)
        imported, skipped = 0, 0
        for thread in result.get("data", []):
            try:
                raw = thread.get("cwd", "")
                if raw.startswith("file:"):
                    from urllib.parse import urlparse, unquote
                    parsed = urlparse(raw)
                    if parsed.netloc not in {"", "localhost"}:
                        raise BridgeError("远端环境路径不可用")
                    raw = unquote(parsed.path)
                path = self.project(raw)
            except (BridgeError, OSError, ValueError):
                skipped += 1
                continue
            identifier = thread["id"]
            with self.lock:
                if identifier not in self.sessions:
                    self.sessions[identifier] = {"id": identifier,
                        "title": clipped(thread.get("name") or thread.get("preview") or path.name, 100),
                        "cwd": str(path), "status": "idle", "turnId": None,
                        "updatedAt": thread.get("updatedAt") or thread.get("createdAt") or 0,
                        "origin": "codex", "messages": [], "approvals": [], "diff": "", "error": None,
                        "historyLoaded": False, "readOnly": False, "model": None, "effort": None}
                    self.store.save(self.sessions[identifier])
                    imported += 1
                elif identifier not in self.loaded:
                    session = self.sessions[identifier]
                    if thread.get("name"):
                        session["title"] = clipped(thread["name"], 100)
                    session["updatedAt"] = max(session["updatedAt"], thread.get("updatedAt") or 0)
                    self.store.save(session)
        return {"nextCursor": result.get("nextCursor"), "imported": imported, "skipped": skipped}

    def history_page(self, request):
        identifier = request.get("sessionId")
        with self.lock:
            session = self.session(identifier)
            self.project(session["cwd"])
        params = {"threadId": identifier, "limit": 40, "sortDirection": "desc"}
        if request.get("cursor"):
            params["cursor"] = request["cursor"]
        page = self.rpc.request("thread/items/list", params)
        messages = []
        for entry in reversed(page.get("data", [])):
            item = entry["item"]
            text = self.render_item(item)
            if text is not None:
                messages.append({"id": item["id"], "kind": item["type"], "text": clipped(text),
                                 "status": item.get("status", "completed")})
        return {"messages": messages, "nextCursor": page.get("nextCursor")}

    def open_session(self, request):
        identifier = request.get("sessionId")
        with self.lock:
            session = self.session(identifier)
            self.project(session["cwd"])
            if identifier in self.loaded:
                return {"id": identifier}
        metadata = self.rpc.request("thread/read", {"threadId": identifier})["thread"]
        turns = self.rpc.request("thread/turns/list", {"threadId": identifier, "limit": 1,
            "sortDirection": "desc", "itemsView": "notLoaded"}).get("data", [])
        page = self.history_page({"sessionId": identifier})
        with self.lock:
            session["messages"] = page["messages"]
            session["historyCursor"] = page["nextCursor"]
            session["historyLoaded"] = True
            if metadata.get("name"):
                session["title"] = clipped(metadata["name"], 100)
            if turns:
                latest = turns[0]
                # An external running task can be viewed, but is not owned by this process.
                external_active = latest["status"] == "inProgress" and session.get("origin") == "codex"
                session["readOnly"] = external_active
                session["status"] = "externalActive" if external_active else (
                    session["status"] if session["status"] == "interrupted" and latest["status"] == "inProgress" else latest["status"])
                session["turnId"] = latest["id"]
                if latest.get("error"):
                    session["error"] = clipped(latest["error"].get("message"))
        self.store.save(session)
        return {"id": identifier}

    def models(self, refresh=False):
        if self.model_catalog and not refresh and time.monotonic() - self.models_updated_at < 300:
            return {"models": self.model_catalog}
        catalog, cursor, seen = [], None, set()
        for _ in range(20):
            params = {"limit": 50, "includeHidden": False}
            if cursor:
                params["cursor"] = cursor
            result = self.rpc.request("model/list", params)
            for model in result.get("data", []):
                catalog.append({"model": model["model"], "displayName": model.get("displayName") or model["model"],
                    "defaultReasoningEffort": model.get("defaultReasoningEffort"),
                    "supportedReasoningEfforts": model.get("supportedReasoningEfforts", []),
                    "isDefault": model.get("isDefault", False)})
            cursor = result.get("nextCursor")
            if not cursor:
                break
            if cursor in seen:
                raise BridgeError("模型列表分页异常。")
            seen.add(cursor)
        else:
            raise BridgeError("模型列表页数过多。")
        self.model_catalog = catalog
        self.models_updated_at = time.monotonic()
        return {"models": catalog}

    def model_settings(self, request):
        name, effort = request.get("model"), request.get("effort")
        if not name:
            if effort:
                raise BridgeError("请先选择模型再设置推理强度。")
            return {}
        model = next((m for m in self.models()["models"] if m["model"] == name), None)
        if not model:
            raise BridgeError("服务器模型列表中没有这个模型，请刷新列表。")
        supported = {entry["reasoningEffort"] for entry in model["supportedReasoningEfforts"]}
        chosen = effort or model["defaultReasoningEffort"]
        if chosen and chosen not in supported:
            raise BridgeError("所选模型不支持这个推理强度。")
        return {"model": name, **({"effort": chosen} if chosen else {})}

    def on_message(self, message):
        method = message.get("method", "")
        params = message.get("params", {})
        with self.lock:
            if method == "bridge/disconnected":
                for session in self.sessions.values():
                    if session["status"] in ACTIVE:
                        session["status"] = "interrupted"
                        session["error"] = "Codex 进程已退出，请重新准备工作区。"
                    session["approvals"] = []
                    self.store.save(session)
                return
            identifier = params.get("threadId")
            if identifier not in self.sessions:
                if "id" in message:
                    self.rpc.write({"id": message["id"], "error": {"code": -32601, "message": "Unknown thread or unsupported request"}})
                return
            session = self.sessions[identifier]
            if "id" in message:
                supported = {"item/commandExecution/requestApproval", "item/fileChange/requestApproval",
                             "item/tool/requestUserInput", "item/permissions/requestApproval"}
                if method not in supported:
                    self.rpc.write({"id": message["id"], "error": {"code": -32601, "message": "This client does not support this request"}})
                    session["error"] = "不支持的交互请求已拒绝：" + method
                else:
                    session["approvals"].append({"id": self.epoch + ":" + json.dumps(message["id"]),
                                                 "rpcId": message["id"], "method": method, "params": params})
                    session["status"] = "waiting"
            elif method in {"turn/started", "turn/completed"}:
                turn = params["turn"]
                session["turnId"] = turn["id"]
                session["status"] = turn["status"]
                if method == "turn/completed":
                    session["approvals"] = [a for a in session["approvals"] if a["params"].get("turnId") != turn["id"]]
                    if turn.get("error"):
                        session["error"] = clipped(turn["error"].get("message"))
            elif method == "serverRequest/resolved":
                session["approvals"] = [a for a in session["approvals"] if a["rpcId"] != params.get("requestId")]
                if not session["approvals"] and session["status"] == "waiting":
                    session["status"] = "inProgress"
            elif method in {"item/started", "item/completed"}:
                item = params["item"]
                content = self.render_item(item)
                if content is not None:
                    existing = next((m for m in session["messages"] if m["id"] == item["id"]), None)
                    value = {"id": item["id"], "kind": item["type"], "text": clipped(content),
                             "status": item.get("status", "completed" if method.endswith("completed") else "inProgress")}
                    if existing:
                        existing.update(value)
                    else:
                        session["messages"].append(value)
            elif method in {"item/agentMessage/delta", "item/plan/delta", "item/commandExecution/outputDelta"}:
                existing = next((m for m in session["messages"] if m["id"] == params.get("itemId")), None)
                if existing:
                    existing["text"] = clipped(existing["text"] + params.get("delta", ""))
            elif method == "turn/diff/updated":
                session["diff"] = clipped(params.get("diff"), 128000)
            elif method == "error":
                session["error"] = clipped(params.get("error", {}).get("message"))
            else:
                return
            session["updatedAt"] = time.time()
            self.store.save(session)

    @staticmethod
    def render_item(item):
        kind = item["type"]
        if kind == "userMessage":
            return "\n".join(x.get("text", "") for x in item.get("content", []) if x.get("type") == "text")
        if kind in {"agentMessage", "plan"}:
            return item.get("text", "")
        if kind == "commandExecution":
            return item.get("command", "") + "\n" + (item.get("aggregatedOutput") or "")
        if kind == "fileChange":
            return "\n\n".join(c.get("path", "") + "\n" + c.get("diff", "") for c in item.get("changes", []))
        if kind == "reasoning":
            return None  # Do not display raw reasoning payloads.
        return json.dumps(item, ensure_ascii=False)

    def create(self, request):
        path = self.project(request.get("cwd"))
        settings = self.model_settings(request)
        result = self.rpc.request("thread/start", {"cwd": str(path), "approvalPolicy": "untrusted",
                                  "approvalsReviewer": "user", "sandbox": "workspace-write",
                                  **({"model": settings["model"]} if settings else {})})
        identifier = result["thread"]["id"]
        with self.lock:
            self.sessions[identifier] = {"id": identifier, "title": path.name or str(path), "cwd": str(path),
                "status": "idle", "turnId": None, "updatedAt": time.time(), "messages": [],
                "approvals": [], "diff": "", "error": None, "origin": "app", "readOnly": False,
                "model": result.get("model"), "effort": settings.get("effort") or result.get("reasoningEffort")}
            self.loaded.add(identifier)
            self.store.save(self.sessions[identifier])
        self.add_project({"cwd": str(path)})
        return {"id": identifier}

    def send(self, request):
        text = request.get("text", "").strip()
        if not text or len(text) > 20000:
            raise BridgeError("消息不能为空，且不能超过 20000 个字符。")
        identifier = request.get("sessionId")
        with self.lock:
            session = self.session(identifier)
            if session["status"] in ACTIVE or session.get("readOnly"):
                raise BridgeError("当前会话仍在运行或等待审批，请先完成或停止任务。")
            self.project(session["cwd"])
        if identifier not in self.loaded:
            self.open_session({"sessionId": identifier})
            if session.get("readOnly"):
                raise BridgeError("这个会话正在 CLI 中运行，请在 CLI 结束任务后刷新，再继续会话。")
            resumed = self.rpc.request("thread/resume", {"threadId": identifier, "cwd": session["cwd"],
                                              "approvalPolicy": "untrusted", "sandbox": "workspace-write", "excludeTurns": True})
            session["model"] = resumed.get("model") or session.get("model")
            session["effort"] = resumed.get("reasoningEffort") or session.get("effort")
            self.loaded.add(identifier)
        settings = self.model_settings(request)
        with self.lock:
            session["status"] = "starting"
            session["error"] = None
            session["diff"] = ""
            if not session["messages"]:
                session["title"] = text[:48]
            self.store.save(session)
        try:
            result = self.rpc.request("turn/start", {"threadId": identifier,
                "input": [{"type": "text", "text": text}], "approvalPolicy": "untrusted",
                "approvalsReviewer": "user", **settings})
            with self.lock:
                if settings:
                    session["model"] = settings["model"]
                    session["effort"] = settings.get("effort")
                session["turnId"] = result["turn"]["id"]
                if session["status"] == "starting":
                    session["status"] = result["turn"]["status"]
                self.store.save(session)
            return {"id": result["turn"]["id"]}
        except Exception:
            # A timed-out request may have started a real turn. Never retry automatically.
            with self.lock:
                if session["status"] == "starting":
                    session["status"] = "unknown"
                    session["error"] = "请求结果不确定，请刷新确认，不要重复发送。"
                    self.store.save(session)
            raise

    def answer(self, request):
        with self.lock:
            session = self.session(request.get("sessionId"))
            approval = next((a for a in session["approvals"] if a["id"] == request.get("requestId")), None)
            if not approval or session["status"] not in ACTIVE:
                raise BridgeError("审批已经失效，请刷新会话。")
            params = approval["params"]
            if params.get("turnId") != session["turnId"]:
                raise BridgeError("审批不属于当前任务，已阻止操作。")
            method = approval["method"]
            if method == "item/tool/requestUserInput":
                answers = request.get("answers", {})
                response = {"answers": {}}
                for question in params["questions"]:
                    value = answers.get(question["id"], "").strip()
                    if not value or len(value) > 10000:
                        raise BridgeError("请回答全部问题。")
                    response["answers"][question["id"]] = {"answers": [value]}
            elif method == "item/permissions/requestApproval":
                # Initial client does not support granting expanded filesystem/network permissions.
                if request.get("decision") != "decline":
                    raise BridgeError("当前版本只能拒绝额外权限请求。")
                response = {"permissions": {}, "scope": "turn"}
            else:
                decision = request.get("decision")
                if decision not in {"accept", "decline", "cancel"}:
                    raise BridgeError("无效的审批决定。")
                allowed = params.get("availableDecisions")
                if allowed is not None and decision not in allowed:
                    raise BridgeError("Codex 不支持这项审批选项。")
                response = {"decision": decision}
            self.rpc.write({"id": approval["rpcId"], "result": response})
            session["approvals"].remove(approval)
            if not session["approvals"]:
                session["status"] = "inProgress"
            self.store.save(session)
        return {}

    def stop(self, request):
        with self.lock:
            session = self.session(request.get("sessionId"))
            identifier, turn = session["id"], session["turnId"]
            if session["status"] not in ACTIVE or not turn:
                raise BridgeError("该会话没有可停止的任务。")
        self.rpc.request("turn/interrupt", {"threadId": identifier, "turnId": turn})
        return {}  # The actual turn/completed event determines the final state.

    def begin_shutdown(self):
        with self.mutations, self.lock:
            if any(s["status"] in ACTIVE | {"unknown"} for s in self.sessions.values()):
                raise BridgeError("还有运行中、待审批或结果不确定的任务，请先确认任务状态。")
            self.stopping = True

    def dispatch(self, request):
        action = request.get("action")
        if action == "status":
            return {"ok": True, "result": self.status()}
        if action == "snapshot":
            return {"ok": True, "result": self.snapshot(request.get("sessionId"))}
        if action in {"catalog", "open", "historyPage", "models"}:
            methods = {"catalog": self.catalog, "open": self.open_session, "historyPage": self.history_page,
                       "models": lambda r: self.models(refresh=bool(r.get("refresh")))}
            with self.mutations:
                return {"ok": True, "result": methods[action](request)}
        if action == "directories":
            path = self.project(request.get("path") or str(self.root))
            children = []
            for child in sorted(path.iterdir(), key=lambda p: p.name.lower()):
                try:
                    if child.name.startswith(".") or not child.is_dir():
                        continue
                    resolved = self.project(str(child))
                    children.append({"id": str(resolved), "name": child.name})
                except (BridgeError, OSError):
                    continue
                if len(children) >= 100:
                    break
            return {"ok": True, "result": {"path": str(path), "root": str(self.root),
                     "parent": str(path.parent) if path != self.root else None, "directories": children}}
        methods = {"create": self.create, "send": self.send, "answer": self.answer, "stop": self.stop, "addProject": self.add_project}
        if action not in methods:
            raise BridgeError("未知操作。")
        with self.mutations:
            if self.stopping:
                raise BridgeError("后台正在重启，请稍后重新准备工作区。")
            return self.store.operation(request, lambda: methods[action](request))


def state_directory():
    directory = Path(os.environ.get("CODEX_IPAD_HOME", str(Path.home() / ".local/share/codex-ipad")))
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if directory.is_symlink() or directory.stat().st_uid != os.getuid():
        raise BridgeError("后台目录的所有者或类型不正确。")
    directory.chmod(0o700)
    return directory


def call(directory, request):
    wire = json.dumps(request, ensure_ascii=False).encode() + b"\n"
    if len(wire) > MAX_WIRE:
        raise BridgeError("请求过大。")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(35)
        connection.connect(str(directory / "bridge.sock"))
        connection.sendall(wire)
        file = connection.makefile("rb")
        response = file.readline(MAX_WIRE + 1)
        if len(response) > MAX_WIRE or not response.endswith(b"\n"):
            raise BridgeError("后台响应过大或不完整。")
        return json.loads(response)


def serve(directory, root):
    import fcntl
    import signal
    # Keep lock alive for the entire daemon lifetime, including socket setup/cleanup.
    lock = open(directory / "daemon.lock", "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return
    bridge = Bridge(directory, root)
    (directory / "daemon.pid").write_text(str(os.getpid()))
    socket_path = directory / "bridge.sock"
    socket_path.unlink(missing_ok=True)

    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            stop_after_response = False
            try:
                wire = self.rfile.readline(MAX_WIRE + 1)
                if len(wire) > MAX_WIRE or not wire.endswith(b"\n"):
                    raise BridgeError("无效请求。")
                request = json.loads(wire)
                if request.get("action") == "shutdown":
                    bridge.begin_shutdown()
                    stop_after_response = True
                    result = {"ok": True, "result": {}}
                else:
                    result = bridge.dispatch(request)
            except Exception as error:
                result = {"ok": False, "error": str(error)}
            encoded = json.dumps(result, ensure_ascii=False).encode() + b"\n"
            if len(encoded) > MAX_WIRE:
                encoded = b'{"ok":false,"error":"Response too large"}\n'
            self.wfile.write(encoded)
            if stop_after_response:
                threading.Thread(target=server.shutdown, daemon=True).start()

    class Server(socketserver.ThreadingUnixStreamServer):
        daemon_threads = True

    with Server(str(socket_path), Handler) as server:
        socket_path.chmod(0o600)
        def terminate(_number, _frame):
            raise KeyboardInterrupt
        signal.signal(signal.SIGTERM, terminate)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            bridge.rpc.process.terminate()
            try:
                bridge.rpc.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                bridge.rpc.process.kill()
            socket_path.unlink(missing_ok=True)


def ensure(directory, root):
    try:
        result = call(directory, {"action": "snapshot"})
        if result.get("result", {}).get("ready"):
            return call(directory, {"action": "status"})
        raise BridgeError("Codex 后台已退出。请在服务器停止旧后台后重新准备工作区。")
    except (FileNotFoundError, ConnectionRefusedError):
        pass
    executable = shutil.which("codex")
    if not executable:
        raise BridgeError("未找到 codex，请先在服务器安装并登录 Codex CLI。")
    log = open(directory / "bridge.log", "a")
    command = [sys.executable, str(Path(__file__).resolve()), "serve"]
    if root:
        command += ["--root", root]
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                               cwd=str(Path.home()), start_new_session=True, close_fds=True)
    for _ in range(100):
        try:
            return call(directory, {"action": "status"})
        except (OSError, ValueError):
            if process.poll() is not None:
                raise BridgeError("后台启动失败，请查看 ~/.local/share/codex-ipad/bridge.log。") from None
            time.sleep(0.1)
    raise BridgeError("后台启动超时，请稍后重试。")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["serve", "ensure", "call"])
    parser.add_argument("payload", nargs="?")
    parser.add_argument("--root")
    args = parser.parse_args()
    directory = state_directory()
    try:
        if args.mode == "serve":
            serve(directory, args.root)
            return
        result = ensure(directory, args.root) if args.mode == "ensure" else call(
            directory, json.loads(base64.b64decode(args.payload, validate=True)))
    except Exception as error:
        result = {"ok": False, "error": str(error)}
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
