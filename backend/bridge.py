#!/usr/bin/env python3
"""Personal Codex bridge. SSH is the transport; no TCP listener or external deps."""
import argparse
import base64
import concurrent.futures
import fcntl
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
BRIDGE_VERSION = "0.11.4"
MAX_WIRE = 2 * 1024 * 1024
MAX_TEXT = 12000
MESSAGE_PREVIEW = 4000
ACTIVE = {"inProgress", "waiting", "starting"}
WRITER_CONFLICT = "此会话被另一个 Codex 客户端占用，本条消息尚未发送。请先退出另一端打开此会话的 Codex App / CLI，再重试；也可以新建聊天继续工作。"


def writer_conflict(error):
    text = str(error).lower()
    return "thread-store conflict" in text and "already has an active writer" in text


def thread_writer_occupied(identifier):
    # Match Codex's local writer lock namespace. Never create, delete, or retain a lock.
    try:
        identifier = str(uuid.UUID(identifier))
    except (ValueError, TypeError, AttributeError):
        return None
    home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    try:
        with (home / "thread-writer-locks" / (identifier + ".lock")).open("rb") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            fcntl.flock(handle, fcntl.LOCK_UN)
            return False
    except FileNotFoundError:
        return False
    except OSError:
        return None  # Unknown is not proof of occupancy; resume remains authoritative.


def clipped(value, limit=MAX_TEXT):
    text = str(value or "")
    return text if len(text) <= limit else text[:limit] + "\n[内容过长，已截断]"


class BridgeError(Exception):
    pass


def codex_executable():
    # SSH commands may not load the interactive shell's PATH (notably .zshrc).
    executable = shutil.which("codex")
    if executable:
        return executable
    home = Path.home()
    for directory in (home / ".local/bin", home / ".npm-global/bin",
                      home / "bin", Path("/opt/homebrew/bin"), Path("/usr/local/bin")):
        executable = shutil.which("codex", path=str(directory))
        if executable:
            return executable
    raise BridgeError("未找到 codex，请先在服务器安装 Codex CLI，并将其加入 PATH 或安装到 ~/.local/bin。")


class Store:
    def __init__(self, directory):
        self.lock = threading.RLock()
        self.db = sqlite3.connect(directory / "history.sqlite3", check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript("""
          CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, value TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY, digest TEXT NOT NULL, value TEXT);
          CREATE TABLE IF NOT EXISTS projects(path TEXT PRIMARY KEY, title TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS message_bodies(session TEXT, id TEXT, text TEXT NOT NULL, PRIMARY KEY(session,id));
          CREATE TABLE IF NOT EXISTS message_attachments(session TEXT, id TEXT, value TEXT NOT NULL, PRIMARY KEY(session,id));
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
            self._save_bodies(session["id"], session["messages"])
            self.db.commit()

    def _save_bodies(self, session, messages):
        self.db.executemany("INSERT INTO message_bodies VALUES (?,?,?) ON CONFLICT(session,id) DO UPDATE SET text=excluded.text WHERE text != excluded.text",
                            [(session, m["id"], m["text"]) for m in messages])

        for message in messages:
            if message.get("attachments"):
                value = json.dumps(message["attachments"], ensure_ascii=False)
                for identifier in {message["id"], message.get("sourceItemId", message["id"])}:
                    self.db.execute("INSERT OR REPLACE INTO message_attachments VALUES (?,?,?)", (session, identifier, value))

    def attachments_for(self, session, identifier):
        with self.lock:
            row = self.db.execute("SELECT value FROM message_attachments WHERE session=? AND id=?", (session, identifier)).fetchone()
            return json.loads(row[0]) if row else []

    def save_bodies(self, session, messages):
        with self.lock:
            self._save_bodies(session, messages)
            self.db.commit()

    def body(self, session, identifier):
        with self.lock:
            row = self.db.execute("SELECT text FROM message_bodies WHERE session=? AND id=?", (session, identifier)).fetchone()
            return row[0] if row else None

    @staticmethod
    def rejected_send(request, result):
        # Only explicit failures known to precede turn acceptance are recoverable.
        return (request.get("action") == "send" and not result.get("ok") and
                (result.get("error", "").startswith("thread not loaded:") or
                 writer_conflict(result.get("error", "")) or
                 result.get("error") == WRITER_CONFLICT or
                 result.get("error") in {"thread/items/list is not supported yet",
                     "找不到附件，请重新添加。", "附件不属于当前会话，或路径无效。",
                     "附件上传不完整或已被删除，请重新添加。", "每次最多发送 8 个附件。"}))

    def operation_status(self, request):
        token = request.get("operationId", "")
        digest = hashlib.sha256(json.dumps(request, sort_keys=True).encode()).hexdigest()
        with self.lock:
            row = self.db.execute("SELECT digest,value FROM operations WHERE id=?", (token,)).fetchone()
        if not row:
            return {"state": "missing"}
        if row[0] != digest:
            raise BridgeError("待确认请求与服务器记录不匹配。")
        if row[1] is None:
            return {"state": "unknown"}
        result = json.loads(row[1])
        if result.get("ok"):
            return {"state": "accepted"}
        if self.rejected_send(request, result):
            return {"state": "rejected", "error": result.get("error")}
        return {"state": "unknown", "error": result.get("error")}

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
                previous = json.loads(row[1])
                # These explicit rejections happened before a turn was accepted.
                # Older bridges cached them forever, including after an upgrade.
                retryable = self.rejected_send(request, previous)
                if not retryable:
                    return previous
                self.db.execute("DELETE FROM operations WHERE id=?", (token,))
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
    def __init__(self, callback, executable=None):
        self.callback = callback
        self.pending = {}
        self.lock = threading.Lock()
        self.write_lock = threading.Lock()
        self.next_id = 0
        self.ready = False
        self.process = subprocess.Popen([executable or codex_executable(), "app-server", "--listen", "stdio://"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=sys.stderr, text=True, bufsize=1)
        threading.Thread(target=self.read, daemon=True).start()
        try:
            self.request("initialize", {"clientInfo": {"name": "codex_ipad", "title": "Code Pax", "version": BRIDGE_VERSION},
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
        self.account_usage = None
        self.usage_updated_at = 0
        self.usage_dirty = False
        self.usage_lock = threading.Lock()
        self.loaded = set()
        self.stopping = False
        self.epoch = uuid.uuid4().hex
        for session in self.sessions.values():
            if session.get("status") == "completed" and session.get("turnId"):
                session.setdefault("completedTurnId", session["turnId"])
            session["approvals"] = []
            for message in session["messages"]:
                if message["kind"] == "userMessage" and message["status"] == "sending":
                    message["status"] = "unknown"
            if session["status"] in ACTIVE:
                session["status"] = "interrupted"
                session["error"] = "服务器后台已重启，原任务中断。发送新消息可继续会话。"
            for message in session["messages"]:
                self.recover_attachment_metadata(session, message)
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
        login = subprocess.run([codex_executable(), "login", "status"],
                               capture_output=True, timeout=10)
        return {"protocol": PROTOCOL, "ready": self.rpc.ready,
                "version": BRIDGE_VERSION,
                "capabilities": ["accessMode", "operationStatus", "optimisticMessages", "usage", "attachments", "messageBody", "manageSessions", "downloadFiles"],
                "root": str(self.root), "authenticated": login.returncode == 0,
                "accountType": "服务器已有登录" if login.returncode == 0 else "尚未登录"}

    def snapshot(self, identifier):
        with self.lock:
            if identifier in self.sessions:
                self.update_writer_occupancy(self.sessions[identifier])
            summaries = [{key: s.get(key) for key in ("id", "title", "cwd", "status", "updatedAt", "origin", "model", "completedTurnId", "pinned", "archived")}
                         for s in sorted(self.sessions.values(), key=lambda s: s["updatedAt"], reverse=True)[:1000]]
            projects = dict(self.projects)
            for summary in summaries:
                projects.setdefault(summary["cwd"], Path(summary["cwd"]).name or summary["cwd"])
            selected = None
            if identifier in self.sessions:
                selected = dict(self.session(identifier))
                selected["messages"] = [self.preview_message(m) for m in selected["messages"][-40:]]
                selected["diffLength"] = len(selected.get("diff", ""))
                selected["diffTruncated"] = selected["diffLength"] > MESSAGE_PREVIEW
                selected["diff"] = selected.get("diff", "")[:MESSAGE_PREVIEW]
                selected["historyTruncated"] = len(self.session(identifier)["messages"]) > 40 or bool(selected.get("historyCursor"))
            # Detach from shared dicts before serializing in the request handler.
            return json.loads(json.dumps({"sessions": summaries, "projects": [{"id": p, "title": t} for p, t in sorted(projects.items())], "selected": selected,
                                         "ready": self.rpc.ready}, ensure_ascii=False))

    @staticmethod
    def preview_message(message):
        text = message["text"]
        return {**message, "text": text[:MESSAGE_PREVIEW], "sourceText": None,
                "contentLength": len(text), "textTruncated": len(text) > MESSAGE_PREVIEW}

    def message_body(self, request):
        with self.lock:
            session = self.session(request.get("sessionId"))
            self.project(session["cwd"])
            identifier = request.get("messageId")
            if not isinstance(identifier, str):
                raise BridgeError("无效消息 ID。")
            if identifier == "__diff__":
                text = session.get("diff", "")
            else:
                message = next((m for m in session["messages"] if m["id"] == identifier), None)
                text = message["text"] if message else self.store.body(session["id"], identifier)
            if text is None:
                raise BridgeError("找不到消息，请重新同步历史。")
            revision = hashlib.sha256(text.encode()).hexdigest()
            if request.get("revision") and request["revision"] != revision:
                raise BridgeError("内容仍在更新，请在回答完成后重新打开。")
            offset = request.get("offset", 0)
            if type(offset) is not int or not 0 <= offset <= len(text):
                raise BridgeError("无效分页位置。")
            end = min(len(text), offset + 24000)
            return {"text": text[offset:end], "nextOffset": end if end < len(text) else None,
                    "contentLength": len(text), "revision": revision}

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
            identifier = next((s["id"] for s in self.sessions.values()
                               if s.get("remoteThreadId") == identifier), identifier)
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
                    if thread.get("name") and not session.get("customTitle"):
                        session["title"] = clipped(thread["name"], 100)
                    session["updatedAt"] = max(session["updatedAt"], thread.get("updatedAt") or 0)
                    self.store.save(session)
        return {"nextCursor": result.get("nextCursor"), "imported": imported, "skipped": skipped}

    def history_page(self, request):
        identifier = request.get("sessionId")
        with self.lock:
            session = self.session(identifier)
            self.project(session["cwd"])
        remote_id = session.get("remoteThreadId", identifier)
        if str(request.get("cursor", "")).startswith("legacy:"):
            return self.legacy_history_page(remote_id, request.get("cursor"))
        params = {"threadId": remote_id, "limit": 40, "sortDirection": "desc"}
        if request.get("cursor"):
            params["cursor"] = request["cursor"]
        try:
            page = self.rpc.request("thread/items/list", params)
        except BridgeError as error:
            if not self.unsupported_history(error):
                raise
            return self.legacy_history_page(remote_id)
        messages = []
        for entry in reversed(page.get("data", [])):
            item = entry["item"]
            text = self.render_item(item)
            if text is not None:
                messages.append({"id": item["id"], "kind": item["type"], "text": text,
                                 "status": item.get("status", "completed")})
        return {"messages": messages, "nextCursor": page.get("nextCursor")}

    @staticmethod
    def unsupported_history(error):
        text = str(error).lower()
        return any(value in text for value in ("not supported", "unsupported", "unknown method", "method not found"))

    def legacy_history_page(self, identifier, cursor=None):
        # Older CLI releases expose saved items through thread/read only.
        thread = self.rpc.request("thread/read", {"threadId": identifier, "includeTurns": True})["thread"]
        messages = []
        for turn in thread.get("turns", []):
            for item in turn.get("items", []):
                text = self.render_item(item)
                if text is not None:
                    messages.append({"id": item["id"], "kind": item["type"], "text": text,
                                     "status": item.get("status", "completed")})
        end = len(messages)
        if cursor:
            anchor = cursor.removeprefix("legacy:")
            end = next((i for i, item in enumerate(messages) if item["id"] == anchor), -1)
            if end < 0:
                raise BridgeError("历史分页位置已失效，请重新打开会话。")
        start = max(0, end - 40)
        return {"messages": messages[start:end],
                "nextCursor": "legacy:" + messages[start]["id"] if start else None}

    def update_writer_occupancy(self, session):
        identifier = session["id"]
        occupied = False if identifier in self.loaded else thread_writer_occupied(session.get("remoteThreadId", identifier))
        if occupied is None:
            return
        if occupied:
            if session["status"] != "externalOccupied":
                session["writerPreviousStatus"] = session["status"]
            session.update(status="externalOccupied", readOnly=True, writerOccupied=True)
        else:
            if session["status"] == "externalOccupied":
                session["status"] = session.pop("writerPreviousStatus", "idle")
            session["writerOccupied"] = False
            session["readOnly"] = session["status"] == "externalActive"

    def open_session(self, request):
        identifier = request.get("sessionId")
        with self.lock:
            session = self.session(identifier)
            self.project(session["cwd"])
            if identifier in self.loaded:
                return {"id": identifier}
        remote_id = session.get("remoteThreadId", identifier)
        try:
            metadata = self.rpc.request("thread/read", {"threadId": remote_id})["thread"]
        except BridgeError as error:
            # Pre-0.3 app threads could disappear on restart before their first turn.
            # Browsing stays read-only; a replacement is created only on Send.
            if (str(error).startswith("thread not loaded:") and session.get("origin") != "codex"
                    and not session["messages"] and not session.get("turnId")):
                session["needsRecreation"] = True
                self.store.save(session)
                return {"id": identifier}
            raise
        try:
            turns = self.rpc.request("thread/turns/list", {"threadId": remote_id, "limit": 1,
                "sortDirection": "desc", "itemsView": "notLoaded"}).get("data", [])
        except BridgeError as error:
            if not self.unsupported_history(error):
                raise
            metadata = self.rpc.request("thread/read", {"threadId": remote_id, "includeTurns": True})["thread"]
            turns = metadata.get("turns", [])[-1:]
        page = self.decorate_history(identifier, self.history_page({"sessionId": identifier}))
        with self.lock:
            # Keep optimistic IDs stable when disk history is read after reconnecting.
            previous = session["messages"]
            used = set()
            for item in reversed(page["messages"]):
                match = next((m for m in previous if m.get("sourceItemId") == item["id"]), None)
                if match is None and item["kind"] == "userMessage":
                    match = next((m for m in reversed(previous) if m["id"] == session.get("pendingUserMessageId")
                                  and m["id"] not in used and m.get("sourceText", m["text"]) == item["text"]), None)
                if match is not None:
                    item.update(id=match["id"], status="accepted", sourceItemId=item["id"])
                    if match.get("attachments"):
                        item["attachments"] = match["attachments"]
                    if match.get("sourceText"):
                        item.update(text=match["text"], sourceText=match["sourceText"])
                    used.add(match["id"])
            session["messages"] = page["messages"]
            session["historyCursor"] = page["nextCursor"]
            session["historyLoaded"] = True
            if metadata.get("name") and not session.get("customTitle"):
                session["title"] = clipped(metadata["name"], 100)
            if turns:
                latest = turns[0]
                # An external running task can be viewed, but is not owned by this process.
                external_active = latest["status"] == "inProgress" and session.get("origin") == "codex"
                session["readOnly"] = external_active
                session["status"] = "externalActive" if external_active else (
                    session["status"] if session["status"] == "interrupted" and latest["status"] == "inProgress" else latest["status"])
                session["turnId"] = latest["id"]
                if latest["status"] == "completed":
                    session["completedTurnId"] = latest["id"]
                if latest.get("error"):
                    session["error"] = clipped(latest["error"].get("message"))
        self.update_writer_occupancy(session)
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
            if method == "account/rateLimits/updated":
                # Notifications are sparse; refetch rather than erase missing buckets.
                self.usage_dirty = True
                return
            if method == "bridge/disconnected":
                for session in self.sessions.values():
                    if session["status"] in ACTIVE:
                        session["status"] = "interrupted"
                        session["error"] = "Codex 进程已退出，请重新准备工作区。"
                    session["approvals"] = []
                    self.store.save(session)
                return
            identifier = params.get("threadId")
            identifier = next((s["id"] for s in self.sessions.values()
                               if s.get("remoteThreadId") == identifier), identifier)
            if identifier not in self.sessions:
                if "id" in message:
                    self.rpc.write({"id": message["id"], "error": {"code": -32601, "message": "Unknown thread or unsupported request"}})
                return
            session = self.sessions[identifier]
            if method == "thread/tokenUsage/updated":
                session["tokenUsage"] = params.get("tokenUsage")
                self.store.save(session)
                return
            if method == "thread/closed":
                self.loaded.discard(identifier)
                return
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
                    if turn["status"] == "completed":
                        session["completedTurnId"] = turn["id"]
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
                    existing = next((m for m in session["messages"] if m["id"] == item["id"] or m.get("sourceItemId") == item["id"]), None)
                    if existing is None and item["type"] == "userMessage":
                        existing = next((m for m in session["messages"]
                                         if m["id"] == session.get("pendingUserMessageId") and m.get("sourceText", m["text"]) == content), None)
                    value = {"id": item["id"], "kind": item["type"], "text": content,
                             "status": item.get("status", "completed" if method.endswith("completed") else "inProgress")}
                    if existing:
                        if existing["id"].startswith("local:"):
                            value.update(id=existing["id"], sourceItemId=item["id"], status="accepted")
                            if existing.get("sourceText"):
                                value["text"] = existing["text"]
                            session.pop("pendingUserMessageId", None)
                        if existing.get("attachments"):
                            value["attachments"] = existing["attachments"]
                        existing.update(value)
                    else:
                        session["messages"].append(value)
            elif method in {"item/agentMessage/delta", "item/plan/delta", "item/commandExecution/outputDelta"}:
                existing = next((m for m in session["messages"] if m["id"] == params.get("itemId")), None)
                if existing:
                    existing["text"] += params.get("delta", "")
            elif method == "turn/diff/updated":
                session["diff"] = params.get("diff") or ""
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
        access = self.access_settings(request, {"cwd": str(path)})
        result = self.rpc.request("thread/start", {"cwd": str(path), **access["thread"],
                                  **({"model": settings["model"]} if settings else {})})
        identifier = result["thread"]["id"]
        with self.lock:
            self.sessions[identifier] = {"id": identifier, "title": path.name or str(path), "cwd": str(path),
                "status": "idle", "turnId": None, "updatedAt": time.time(), "messages": [],
                "approvals": [], "diff": "", "error": None, "origin": "app", "readOnly": False,
                "model": result.get("model"), "effort": settings.get("effort") or result.get("reasoningEffort"),
                "accessMode": access["mode"]}
            self.loaded.add(identifier)
            self.store.save(self.sessions[identifier])
        self.add_project({"cwd": str(path)})
        return {"id": identifier}

    @staticmethod
    def access_settings(request, session=None):
        mode = request.get("accessMode", (session or {}).get("accessMode", "default"))
        if mode not in {"default", "fullAccess"}:
            raise BridgeError("无效的权限模式，请选择默认权限或 Full Access。")
        full = mode == "fullAccess"
        common = {"approvalPolicy": "never" if full else "untrusted", "approvalsReviewer": "user"}
        return {"mode": mode,
                "thread": {**common, "sandbox": "danger-full-access" if full else "workspace-write"},
                "turn": {**common, "sandboxPolicy": {"type": "dangerFullAccess"} if full else {
                    "type": "workspaceWrite", "writableRoots": [(session or {})["cwd"]], "networkAccess": False}}}

    def decorate_history(self, identifier, page):
        for message in page["messages"]:
            attachments = self.store.attachments_for(identifier, message["id"])
            if attachments:
                message["attachments"] = attachments
            else:
                self.recover_attachment_metadata(self.session(identifier), message)
        return page

    def recover_attachment_metadata(self, session, message):
        if message.get("kind") != "userMessage" or message.get("attachments"):
            return
        recovered = []
        for line in (message.get("sourceText") or message.get("text", "")).splitlines():
            if not line.startswith("{"):
                continue
            try:
                value = json.loads(line)
                if not isinstance(value, dict) or not isinstance(value.get("path"), str): continue
                identifier = Path(value["path"]).parent.name
                record = self.read_attachment(identifier, session)
                if record["path"] == value["path"] and record["name"] == value.get("name"):
                    if not any(item["id"] == identifier for item in recovered): recovered.append(record)
            except (BridgeError, OSError, ValueError):
                continue
        if recovered:
            message["attachments"] = recovered

    def session_metadata(self, request):
        with self.lock:
            session = self.session(request.get("sessionId"))
            title = request.get("title")
            if title is not None:
                if not isinstance(title, str) or not title.strip() or len(title.strip()) > 100:
                    raise BridgeError("聊天名称不能为空，且不能超过 100 个字符。")
            for field in ("pinned", "archived"):
                if field in request and type(request[field]) is not bool:
                    raise BridgeError("无效的会话设置。")
            if request.get("archived") and (session["status"] in ACTIVE | {"externalActive", "unknown"} or session.get("readOnly")):
                raise BridgeError("请先等待任务完成或停止，再归档聊天。")
            if title is not None:
                session["title"] = title.strip(); session["customTitle"] = True
            for field in ("pinned", "archived"):
                if field in request: session[field] = request[field]
            self.store.save(session)
            return {"id": session["id"]}

    def file_info(self, request):
        with self.lock:
            project = self.project(self.session(request.get("sessionId"))["cwd"])
        raw = request.get("path")
        if not isinstance(raw, str) or not raw or len(raw) > 4096:
            raise BridgeError("无效文件路径。")
        candidate = Path(raw)
        try:
            target = (candidate if candidate.is_absolute() else project / candidate).resolve(strict=True)
        except (OSError, RuntimeError):
            raise BridgeError("文件不存在或无法访问，请确认文件路径。") from None
        if not target.is_relative_to(project) or not target.is_file():
            raise BridgeError("只能预览和下载当前项目中的文件。")
        before = target.stat()
        if before.st_size > 100 * 1024 * 1024:
            raise BridgeError("单个下载文件不能超过 100 MB。")
        digest = hashlib.sha256()
        with target.open("rb") as handle:
            while data := handle.read(1024 * 1024): digest.update(data)
        after = target.stat()
        if (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
            raise BridgeError("文件正在更新，请稍后重试。")
        return {"name": target.name, "path": str(target), "size": after.st_size, "sha256": digest.hexdigest()}

    def attachment_manifest(self, identifier):
        if not isinstance(identifier, str) or len(identifier) != 32 or any(c not in "0123456789abcdef" for c in identifier):
            raise BridgeError("无效附件 ID。")
        return self.directory / "attachments" / (identifier + ".json")

    def attachment(self, request):
        session = self.session(request.get("sessionId"))
        project = self.project(session["cwd"])
        if request["action"] == "attachmentBegin":
            name, size = request.get("name"), request.get("size")
            if (not isinstance(name, str) or not name or len(name.encode("utf-8")) > 240 or name in {".", ".."}
                    or any(c in name for c in '/\\') or any(ord(c) < 32 for c in name)):
                raise BridgeError("无效文件名。")
            if type(size) is not int or not 0 < size <= 20 * 1024 * 1024:
                raise BridgeError("附件不能为空，单个附件不能超过 20 MB。")
            identifier = uuid.uuid4().hex
            base = project / ".codex-ipad-attachments"
            if base.is_symlink():
                raise BridgeError("附件目录不能是符号链接。")
            target = base / identifier
            target.mkdir(parents=True, mode=0o700)
            record = {"id": identifier, "sessionId": session["id"], "name": name, "size": size,
                      "path": str(target / name), "kind": "image" if Path(name).suffix.lower() in {".jpg", ".jpeg", ".png", ".webp"} else "file"}
            manifest = self.attachment_manifest(identifier)
            manifest.parent.mkdir(exist_ok=True, mode=0o700)
            manifest.write_text(json.dumps(record, ensure_ascii=False))
            return {**record, "uploadPath": record["path"] + ".part"}
        record = self.read_attachment(request.get("id"), session, require_complete=False)
        target = Path(record["path"])
        partial = Path(record["path"] + ".part")
        if not record.get("complete"):
            if partial.is_symlink() or not partial.is_file() or partial.stat().st_size != record["size"]:
                raise BridgeError("附件上传不完整，请重新添加。")
            partial.chmod(0o600)
            os.replace(partial, target)
            record["complete"] = True
            self.attachment_manifest(record["id"]).write_text(json.dumps(record, ensure_ascii=False))
        return record

    def read_attachment(self, identifier, session, require_complete=True):
        try:
            record = json.loads(self.attachment_manifest(identifier).read_text())
        except (FileNotFoundError, ValueError):
            raise BridgeError("找不到附件，请重新添加。") from None
        target = Path(record["path"])
        expected = self.project(session["cwd"]) / ".codex-ipad-attachments" / identifier / record["name"]
        if record["sessionId"] != session["id"] or target != expected or target.resolve() != expected:
            raise BridgeError("附件不属于当前会话，或路径无效。")
        if require_complete and (not record.get("complete") or not target.is_file() or target.stat().st_size != record["size"]):
            raise BridgeError("附件上传不完整或已被删除，请重新添加。")
        return record

    def send(self, request):
        text = request.get("text", "").strip()
        attachment_ids = request.get("attachments", [])
        if not isinstance(attachment_ids, list) or len(attachment_ids) > 8:
            raise BridgeError("每次最多发送 8 个附件。")
        if (not text and not attachment_ids) or len(text) > 20000:
            raise BridgeError("消息不能为空，且不能超过 20000 个字符。")
        identifier = request.get("sessionId")
        with self.lock:
            session = self.session(identifier)
            self.update_writer_occupancy(session)
            if session.get("writerOccupied"):
                raise BridgeError(WRITER_CONFLICT)
            if session["status"] in ACTIVE or session.get("readOnly"):
                raise BridgeError("当前会话仍在运行或等待审批，请先完成或停止任务。")
            self.project(session["cwd"])
        attachments = [self.read_attachment(value, session) for value in attachment_ids]
        display_text = text + ("\n\n" if text and attachments else "") + "\n".join("📎 " + a["name"] for a in attachments)
        prompt = text or "请查看附件。"
        if attachments:
            prompt += "\n\n附件（位于当前项目，按需要读取）：\n" + "\n".join(
                json.dumps({"name": a["name"], "path": a["path"]}, ensure_ascii=False) for a in attachments)
        inputs = [{"type": "text", "text": prompt}]
        inputs += [{"type": "localImage", "path": a["path"]} for a in attachments if a["kind"] == "image"]
        access = self.access_settings(request, session)
        if identifier not in self.loaded:
            self.open_session({"sessionId": identifier})
            if session.get("writerOccupied"):
                raise BridgeError(WRITER_CONFLICT)
            if session.get("readOnly"):
                raise BridgeError("这个会话正在 CLI 中运行，请在 CLI 结束任务后刷新，再继续会话。")
            if session.get("needsRecreation"):
                resumed = self.rpc.request("thread/start", {"cwd": session["cwd"], **access["thread"]})
                session["remoteThreadId"] = resumed["thread"]["id"]
                session.pop("needsRecreation", None)
                self.store.save(session)
            else:
                try:
                    resumed = self.rpc.request("thread/resume", {"threadId": session.get("remoteThreadId", identifier), "cwd": session["cwd"],
                                                      **access["thread"], "excludeTurns": True})
                except BridgeError as error:
                    if writer_conflict(error):
                        # Resume failed before turn/start; the user can safely retry after
                        # the owning client releases its writer. Never steal its lease.
                        raise BridgeError(WRITER_CONFLICT) from None
                    raise
            session["model"] = resumed.get("model") or session.get("model")
            session["effort"] = resumed.get("reasoningEffort") or session.get("effort")
            self.loaded.add(identifier)
        settings = self.model_settings(request)
        with self.lock:
            session["status"] = "starting"
            session["error"] = None
            session["diff"] = ""
            if not session["messages"] and not session.get("customTitle"):
                session["title"] = (text or attachments[0]["name"])[:48]
            message_id = "local:" + request["operationId"]
            session["messages"].append({"id": message_id, "kind": "userMessage", "text": display_text, "sourceText": prompt, "attachments": attachments, "status": "sending"})
            session["pendingUserMessageId"] = message_id
            self.store.save(session)
        try:
            result = self.rpc.request("turn/start", {"threadId": session.get("remoteThreadId", identifier),
                "input": inputs, **access["turn"], **settings})
            with self.lock:
                next(m for m in session["messages"] if m["id"] == message_id)["status"] = "accepted"
                session["accessMode"] = access["mode"]
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
                message = next(m for m in session["messages"] if m["id"] == message_id)
                if message["status"] == "sending":
                    message["status"] = "unknown"
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
            identifier, turn = session.get("remoteThreadId", session["id"]), session["turnId"]
            if session["status"] not in ACTIVE or not turn:
                raise BridgeError("该会话没有可停止的任务。")
        self.rpc.request("turn/interrupt", {"threadId": identifier, "turnId": turn})
        return {}  # The actual turn/completed event determines the final state.

    def begin_shutdown(self):
        with self.mutations, self.lock:
            if any(s["status"] in ACTIVE | {"unknown"} for s in self.sessions.values()):
                raise BridgeError("还有运行中、待审批或结果不确定的任务，请先确认任务状态。")
            self.stopping = True

    def usage(self, request):
        identifier = request.get("sessionId")
        with self.lock:
            thread_usage = self.session(identifier).get("tokenUsage") if identifier else None
        error = None
        with self.usage_lock:
            if request.get("refresh") or self.usage_dirty or self.account_usage is None or time.time() - self.usage_updated_at >= 60:
                try:
                    result = self.rpc.request("account/rateLimits/read", {})
                    if not isinstance(result.get("rateLimits"), dict) and not isinstance(result.get("rateLimitsByLimitId"), dict):
                        raise BridgeError("服务器未提供账号额度。")
                    self.account_usage = {key: result.get(key) for key in ("rateLimits", "rateLimitsByLimitId")}
                    self.usage_updated_at = time.time()
                    self.usage_dirty = False
                except Exception as failure:
                    error = str(failure)
            return {**(self.account_usage or {}), "threadUsage": thread_usage,
                    "updatedAt": self.usage_updated_at or None, "error": error}

    def dispatch(self, request):
        action = request.get("action")
        if action == "fileInfo":
            return {"ok": True, "result": self.file_info(request)}
        if action == "messageBody":
            return {"ok": True, "result": self.message_body(request)}
        if action == "historyPage":
            with self.mutations:
                page = self.decorate_history(request["sessionId"], self.history_page(request))
                self.store.save_bodies(request["sessionId"], page["messages"])
                return {"ok": True, "result": {**page, "messages": [self.preview_message(m) for m in page["messages"]]}}
        if action in {"attachmentBegin", "attachmentFinish"}:
            with self.mutations:
                return {"ok": True, "result": self.attachment(request)}
        if action == "usage":
            return {"ok": True, "result": self.usage(request)}
        if action == "operationStatus":
            operation = request.get("operation")
            if not isinstance(operation, dict) or operation.get("action") != "send":
                raise BridgeError("无效的待确认发送请求。")
            return {"ok": True, "result": self.store.operation_status(operation)}
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
        methods = {"create": self.create, "send": self.send, "answer": self.answer, "stop": self.stop, "addProject": self.add_project, "sessionMetadata": self.session_metadata}
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
        status = call(directory, {"action": "status"})
        if not status.get("ok"):
            raise BridgeError(status.get("error", "无法读取后台状态。"))
        running = status["result"]
        if running.get("ready") and running.get("protocol") == PROTOCOL and running.get("version") == BRIDGE_VERSION:
            return status
        snapshot = call(directory, {"action": "snapshot"})
        if not snapshot.get("ok"):
            raise BridgeError(snapshot.get("error", "无法确认任务状态。"))
        active = any(s.get("status") in ACTIVE | {"unknown"} for s in snapshot["result"].get("sessions", []))
        if active:
            running["upgradePending"] = True
            return status
        # The daemon rechecks under its mutation lock, protecting tasks started after our snapshot.
        stopped = call(directory, {"action": "shutdown"})
        if not stopped.get("ok"):
            running["upgradePending"] = True
            return status
        root = root or running.get("root")
        for _ in range(100):
            if not (directory / "bridge.sock").exists():
                break
            time.sleep(0.1)
        else:
            raise BridgeError("后台正在更新，请稍后重新连接。")
    except (FileNotFoundError, ConnectionRefusedError):
        pass
    codex_executable()
    command = [sys.executable, str(Path(__file__).resolve()), "serve"]
    if root:
        command += ["--root", root]
    with open(directory / "bridge.log", "a") as log:
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
