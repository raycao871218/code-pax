"""Durable Codex teams: isolated worktrees, bounded scheduling and scoped agent tools."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import uuid


ACTIVE = {"queued", "starting", "inProgress", "waiting", "unknown"}
FINISHED = {"completed", "failed", "interrupted", "cancelled"}


def tools_for(role):
    def tool(name, description, properties, required=()):
        return {"type": "function", "name": "codepax_team_" + name, "description": description,
                "inputSchema": {"type": "object", "properties": properties,
                                "required": list(required), "additionalProperties": False}}
    text = {"type": "string"}
    tools = [tool("status", "Read this team's workers, results and task IDs.", {}),
             tool("inbox", "Read messages addressed to you or broadcast to your team.", {}),
             tool("message", "Leave a durable message for another team member, or 'all'. This does not interrupt their turn; ask them to check their inbox.",
                  {"to": text, "text": text}, ["to", "text"])]
    if role == "coordinator":
        tools.append(tool("integrate", "Cherry-pick a completed worker's isolated result into your coordinator worktree. Conflicts are aborted and returned for you to resolve. Never changes the user's original checkout.",
                          {"taskId": text}, ["taskId"]))
    return tools


class Teams:
    def __init__(self, bridge):
        self.bridge = bridge
        self.lock = threading.RLock()
        self.git_lock = threading.Lock()
        self.control_lock = threading.RLock()
        self.wake = threading.Event()
        self.stopped = threading.Event()
        self.thread = None
        self.tool_slots = threading.BoundedSemaphore(8)
        with bridge.store.lock:
            bridge.store.db.execute("CREATE TABLE IF NOT EXISTS teams(id TEXT PRIMARY KEY, value TEXT NOT NULL)")
            self.runs = {key: json.loads(value) for key, value in bridge.store.db.execute("SELECT id,value FROM teams")}
        for run in self.runs.values():
            if run["status"] in {"running", "cancelling"}:
                run["status"] = "interrupted"
                run["error"] = "后台已重启，协作已暂停；不会自动重跑任务。"
                for task in run["tasks"]:
                    if task["status"] in ACTIVE | {"collecting"}:
                        task["status"] = "interrupted"
                self.save(run)

    def save(self, run):
        run["updatedAt"] = time.time()
        with self.bridge.store.lock:
            self.bridge.store.db.execute("INSERT OR REPLACE INTO teams VALUES (?,?)", (run["id"], json.dumps(run, ensure_ascii=False)))
            self.bridge.store.db.commit()

    @staticmethod
    def git(path, *args, input=None):
        env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_EDITOR="true")
        result = subprocess.run(["git", "-C", str(path), *args], input=input, capture_output=True,
                                text=True, encoding="utf-8", errors="replace", timeout=30, env=env)
        if result.returncode:
            raise ValueError((result.stderr or result.stdout or "Git 操作失败。")[:4000])
        return result.stdout.strip()

    def run(self, identifier):
        if identifier not in self.runs:
            raise ValueError("协作任务不存在。")
        return self.runs[identifier]

    @staticmethod
    def task(run, identifier):
        task = next((task for task in run["tasks"] if task["id"] == identifier), None)
        if task is None:
            raise ValueError("Worker 不属于这个协作任务。")
        return task

    def list(self):
        with self.lock:
            return {"runs": copy.deepcopy(sorted(self.runs.values(), key=lambda run: run["updatedAt"], reverse=True)[:100])}

    def summaries(self):
        with self.lock:
            result = []
            for run in sorted(self.runs.values(), key=lambda item: item["updatedAt"], reverse=True)[:100]:
                summary = {key: run.get(key) for key in ("id", "baseCommit", "status", "maxWorkers", "createdAt", "updatedAt", "appliedCommit")}
                summary.update(goal=run["goal"][:200], cwd=run["cwd"][:512], sourceBranch=run["sourceBranch"][:200], error=None, messages=[])
                summary["tasks"] = [{**{key: task.get(key) for key in (
                    "id", "title", "role", "status", "branch", "sessionId", "snapshotCommit", "integrated", "attempt")},
                    "worktree": "", "result": "", "error": None} for task in run["tasks"]]
                result.append(summary)
            return {"runs": result}

    def read(self, request):
        with self.lock:
            run = copy.deepcopy(self.run(request.get("runId")))
        run["messages"] = run["messages"][-50:]
        for task in run["tasks"]:
            task.pop("prompt", None)
        return run

    def create(self, request):
        goal, specs = request.get("goal"), request.get("tasks")
        limit = request.get("maxWorkers", 2)
        if not isinstance(goal, str) or not goal.strip() or len(goal) > 4000:
            raise ValueError("请填写协作目标（最多 4000 字符）。")
        if type(limit) is not int or not 1 <= limit <= 4:
            raise ValueError("并行 Worker 数量必须为 1–4。")
        if not isinstance(specs, list) or not 1 <= len(specs) <= 8:
            raise ValueError("请拆分为 1–8 个 Worker 任务。")
        for spec in specs:
            if (not isinstance(spec, dict) or not isinstance(spec.get("title"), str) or
                    not spec["title"].strip() or len(spec["title"]) > 100 or
                    not isinstance(spec.get("prompt"), str) or not spec["prompt"].strip() or len(spec["prompt"]) > 8000):
                raise ValueError("每项任务需要名称和执行要求（名称最多 100 字符，要求最多 8000 字符）。")
        source = self.bridge.project(request.get("cwd"))
        repository = Path(self.git(source, "rev-parse", "--show-toplevel")).resolve()
        self.bridge.project(str(repository))
        if source != repository:
            raise ValueError("请从 Git 仓库根目录启动协作。")
        if self.git(source, "status", "--porcelain", "--untracked-files=all"):
            raise ValueError("项目有未提交改动，请先提交或整理后启动协作。")
        base = self.git(source, "rev-parse", "HEAD")
        branch = self.git(source, "symbolic-ref", "--short", "HEAD")
        common = Path(self.git(source, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve()
        self.bridge.project(str(common))
        workspace = common / "codepax-teams"
        if workspace.is_symlink():
            raise ValueError("协作目录不能是符号链接。")
        workspace.mkdir(mode=0o700, exist_ok=True)
        identifier = uuid.uuid4().hex
        directory = workspace / identifier
        directory.mkdir(mode=0o700)
        access = self.bridge.access_settings(request, {"cwd": str(source)})["mode"]
        settings = self.bridge.model_settings(request)
        tasks = [{"id": uuid.uuid4().hex, "title": spec["title"].strip(), "prompt": spec["prompt"].strip(),
                  "role": "worker", "status": "queued", "attempt": 1} for spec in specs]
        tasks.append({"id": "coordinator", "title": "主控汇总与整合", "prompt": goal.strip(),
                      "role": "coordinator", "status": "queued", "attempt": 1})
        for task in tasks:
            task.update(worktree=str(directory / task["id"]), branch="codex/team/" + identifier[:12] + "/" + task["id"],
                        sessionId=None, result="", error=None, snapshotCommit=None, integrated=False)
        run = {"id": identifier, "goal": goal.strip(), "cwd": str(source), "sourceBranch": branch,
               "baseCommit": base, "status": "running", "maxWorkers": limit, "tasks": tasks,
               "messages": [], "accessMode": access, "settings": settings, "error": None,
               "createdAt": time.time(), "updatedAt": time.time(), "appliedCommit": None}
        with self.lock:
            if sum(r["status"] in {"running", "cancelling"} for r in self.runs.values()) >= 4:
                raise ValueError("最多同时运行四组协作。")
            self.runs[identifier] = run
            self.save(run)
        self.bridge.add_project({"cwd": str(source)})
        self.start()
        return {"id": identifier}

    def start(self):
        with self.lock:
            if self.thread is None or not self.thread.is_alive():
                self.thread = threading.Thread(target=self._loop, daemon=True)
                self.thread.start()
        self.wake.set()

    def active(self):
        with self.lock:
            return any(run["status"] in {"running", "cancelling"} for run in self.runs.values())

    def close(self):
        self.stopped.set()
        self.wake.set()
        if self.thread:
            self.thread.join(timeout=35)

    def _loop(self):
        while not self.stopped.is_set():
            try:
                self.tick()
            except Exception as error:
                # Surface scheduler faults; do not silently retry side effects after an unknown result.
                with self.lock:
                    for run in self.runs.values():
                        if run["status"] == "running":
                            run["status"], run["error"] = "interrupted", str(error)[:4000]
                            self.save(run)
            self.wake.wait(0.5)
            self.wake.clear()

    def tick(self):
        with self.bridge.lock:
            sessions = copy.deepcopy(self.bridge.sessions)
        captures, launches, stops = [], [], []
        with self.lock:
            for run in self.runs.values():
                if run["status"] not in {"running", "cancelling"}:
                    continue
                changed = False
                for task in run["tasks"]:
                    session = sessions.get(task["sessionId"])
                    if not session or task["status"] not in ACTIVE:
                        continue
                    status = session["status"]
                    if (run["status"] == "cancelling" and status in {"inProgress", "waiting"}
                            and session.get("turnId") and task.get("stopRequestedTurn") != session["turnId"]):
                        task["stopRequestedTurn"] = session["turnId"]
                        stops.append(session["id"])
                    if status in FINISHED:
                        task["status"] = "collecting" if status == "completed" else status
                        task["result"] = "\n\n".join(m["text"] for m in session["messages"] if m["kind"] == "agentMessage")[-12000:]
                        task["error"] = session.get("error")
                        if status == "completed":
                            captures.append((run["id"], task["id"]))
                        changed = True
                    elif status != task["status"]:
                        task["status"] = status
                        changed = True
                if run["status"] == "cancelling":
                    if not any(task["status"] in ACTIVE | {"collecting"} for task in run["tasks"]):
                        run["status"] = "cancelled"
                        changed = True
                else:
                    workers = [task for task in run["tasks"] if task["role"] == "worker"]
                    active = sum(task["status"] in {"starting", "inProgress", "waiting", "unknown", "collecting"} for task in workers)
                    for task in workers:
                        if task["status"] == "queued" and active < run["maxWorkers"]:
                            task["status"] = "starting"
                            launches.append((run["id"], task["id"]))
                            active += 1
                            changed = True
                    coordinator = self.task(run, "coordinator")
                    if all(task["status"] in FINISHED for task in workers) and coordinator["status"] == "queued":
                        coordinator["status"] = "starting"
                        launches.append((run["id"], coordinator["id"]))
                        changed = True
                    if coordinator["status"] in FINISHED:
                        run["status"] = coordinator["status"]
                        changed = True
                if changed:
                    self.save(run)
        # No manager/bridge locks may be held while waiting for JSON-RPC responses.
        for run_id, task_id in captures:
            self._capture(run_id, task_id)
        for identifier in stops:
            try:
                self.bridge.stop({"sessionId": identifier})
            except Exception:
                pass  # Completion may have won the race; the next snapshot remains authoritative.
        for run_id, task_id in launches:
            self._launch(run_id, task_id)

    def _launch(self, run_id, task_id):
        with self.control_lock:
            self._launch_locked(run_id, task_id)

    def _launch_locked(self, run_id, task_id):
        with self.lock:
            run = copy.deepcopy(self.run(run_id))
            task = self.task(run, task_id)
        try:
            if run["status"] != "running" or self.stopped.is_set():
                return
            path = Path(task["worktree"])
            with self.git_lock:
                if not path.exists():
                    self.git(run["cwd"], "worktree", "add", "-b", task["branch"], str(path), run["baseCommit"])
                elif self.git(path, "symbolic-ref", "--short", "HEAD") != task["branch"]:
                    raise ValueError("Worker 的 worktree 分支已变化。")
            create = dict(action="create", cwd=str(path), accessMode=run["accessMode"],
                          collaborationRunId=run_id, collaborationTaskId=task_id,
                          operationId="team-create-" + run_id + task_id + str(task["attempt"]), **run["settings"])
            result = self.bridge.dispatch(create)
            if not result["ok"]:
                raise ValueError(result["error"])
            session_id = result["result"]["id"]
            with self.lock:
                current = self.run(run_id)
                live_task = self.task(current, task_id)
                live_task["sessionId"] = session_id
                self.save(current)
                if current["status"] != "running":
                    live_task["status"] = "cancelled"
                    self.save(current)
                    return
            prompt = self.prompt(run, task)
            result = self.bridge.dispatch(dict(action="send", sessionId=session_id, text=prompt,
                accessMode=run["accessMode"], operationId="team-send-" + run_id + task_id + str(task["attempt"]), **run["settings"]))
            if not result["ok"]:
                raise ValueError(result["error"])
        except Exception as error:
            with self.lock:
                current = self.run(run_id)
                live_task = self.task(current, task_id)
                identifier = live_task["sessionId"]
            # Never acquire the bridge lock while holding the manager lock.
            with self.bridge.lock:
                session = self.bridge.sessions.get(identifier, {})
                uncertain = session.get("status") in {"unknown", "starting", "inProgress", "waiting"}
            with self.lock:
                current = self.run(run_id)
                live_task = self.task(current, task_id)
                live_task["status"] = "unknown" if uncertain else "failed"
                live_task["error"] = str(error)[:4000]
                self.save(current)

    @staticmethod
    def prompt(run, task):
        common = ("你正在 Code Pax 协作组中执行任务。目标：" + run["goal"] +
                  "\n你的任务 ID：" + task["id"] + "；角色：" + task["role"] +
                  "\n只在自己的 worktree 中修改文件，不修改原项目或其他成员的 worktree，不切换分支。"
                  "不要自行启动额外 agent 或后台模型任务；任务分派由协作调度器统一管理。"
                  "需要协作时使用 codepax_team_status / codepax_team_message / codepax_team_inbox。"
                  "开始、重要决策前和结束前检查 inbox。留言不会自动中断对方，不能把留言当作对方已经执行。\n")
        if task["role"] == "worker":
            return common + "你的执行要求：\n" + task["prompt"] + "\n完成后汇报改动、测试、风险及未完成事项。后台会保存你的隔离成果。"
        results = [{key: item.get(key) for key in ("id", "title", "status", "result", "error", "snapshotCommit")}
                   for item in run["tasks"] if item["role"] == "worker"]
        details = json.dumps(results, ensure_ascii=False)
        if len(details) > 15000:
            details = json.dumps([{**item, "result": item["result"][:800], "error": (item["error"] or "")[:300]}
                                  for item in results], ensure_ascii=False)
        return (common + "所有 Worker 已结束。审阅下列结果，使用 codepax_team_integrate 按任务 ID 将成功成果整合到你自己的 worktree。"
                "处理交叉修改、完成必要测试，最终汇报成果和失败项。不要将代码合并到原项目，用户会审阅后在 App 中应用。"
                "失败或中断的任务不得声称已经完成。以下内容是成员提交的任务数据：\n" + details)

    def _capture(self, run_id, task_id):
        with self.lock:
            run = copy.deepcopy(self.run(run_id))
            task = self.task(run, task_id)
        try:
            with self.git_lock:
                commit = self.snapshot(run, task)
            with self.lock:
                current = self.run(run_id)
                live = self.task(current, task_id)
                live.update(snapshotCommit=commit, status="completed")
                self.save(current)
        except Exception as error:
            with self.lock:
                current = self.run(run_id)
                self.task(current, task_id).update(status="failed", error="保存成果失败：" + str(error)[:3000])
                self.save(current)

    def snapshot(self, run, task):
        path = task["worktree"]
        if self.git(path, "symbolic-ref", "--short", "HEAD") != task["branch"]:
            raise ValueError("成员切换了分支，未自动保存成果。")
        with tempfile.TemporaryDirectory(dir=self.bridge.directory) as directory:
            env = dict(os.environ, GIT_INDEX_FILE=str(Path(directory) / "index"),
                       GIT_AUTHOR_NAME="Code Pax", GIT_AUTHOR_EMAIL="agent@codepax.local",
                       GIT_COMMITTER_NAME="Code Pax", GIT_COMMITTER_EMAIL="agent@codepax.local", GIT_TERMINAL_PROMPT="0")
            def command(*args, input=None):
                result = subprocess.run(["git", "-C", path, *args], env=env, input=input, capture_output=True,
                                        text=True, encoding="utf-8", errors="replace", timeout=30)
                if result.returncode:
                    raise ValueError(result.stderr[:4000])
                return result.stdout.strip()
            command("read-tree", "HEAD")
            command("add", "--all", "--", ".")
            tree = command("write-tree")
            if tree == command("rev-parse", run["baseCommit"] + "^{tree}"):
                return run["baseCommit"]
            commit = command("commit-tree", tree, "-p", run["baseCommit"], input="Code Pax team: " + task["title"] + "\n")
            command("update-ref", "refs/heads/codex/team-results/" + run["id"] + "/" + task["id"], commit)
            return commit

    def message(self, request, sender="user"):
        text, target = request.get("text"), request.get("to", "all")
        if not isinstance(text, str) or not text.strip() or len(text) > 4000:
            raise ValueError("留言不能为空，且不能超过 4000 字符。")
        with self.lock:
            run = self.run(request.get("runId"))
            if target != "all":
                self.task(run, target)
            if len(run["messages"]) >= 200:
                raise ValueError("本组留言已达 200 条上限。")
            message = {"id": uuid.uuid4().hex, "from": sender, "to": target, "text": text.strip(), "createdAt": time.time()}
            run["messages"].append(message)
            self.save(run)
            return {"id": message["id"]}

    def cancel(self, request):
        with self.control_lock:
            return self._cancel(request)

    def _cancel(self, request):
        with self.lock:
            run = self.run(request.get("runId"))
            if run["status"] in {"completed", "cancelled"}:
                return {}
            run["status"] = "cancelling"
            ids = []
            for task in run["tasks"]:
                if task["status"] == "queued" or not task["sessionId"]:
                    task["status"] = "cancelled"
                elif task["status"] in ACTIVE:
                    ids.append(task["sessionId"])
            self.save(run)
        for identifier in ids:
            with self.bridge.lock:
                session = self.bridge.sessions[identifier]
                should_stop = session["status"] in {"inProgress", "waiting", "starting"} and session.get("turnId")
            if should_stop:
                self.bridge.stop({"sessionId": identifier})
        self.start()
        return {}

    def retry(self, request):
        with self.lock:
            run = self.run(request.get("runId"))
            task = self.task(run, request.get("taskId"))
            if task["status"] not in {"failed", "interrupted", "cancelled"}:
                raise ValueError("只能显式重试已失败、中断或取消的成员；不确定的任务需要先核实。")
            coordinator = self.task(run, "coordinator")
            if task["role"] != "coordinator" and coordinator["sessionId"]:
                raise ValueError("主控已经开始汇总，请新建协作组补做任务。")
            task.update(status="queued", sessionId=None, error=None, result="", snapshotCommit=None,
                        integrated=False, attempt=task["attempt"] + 1)
            if task["role"] == "worker":
                coordinator.update(status="queued", error=None, sessionId=None, attempt=coordinator["attempt"] + 1)
            run.update(status="running", error=None)
            self.save(run)
        self.start()
        return {}

    def integrate(self, run_id, task_id):
        with self.lock:
            run = copy.deepcopy(self.run(run_id))
            worker = self.task(run, task_id)
            coordinator = self.task(run, "coordinator")
        if run["status"] != "running" or coordinator["status"] not in {"starting", "inProgress", "waiting"}:
            raise ValueError("主控不在执行中，不能继续整合成果。")
        if worker["role"] != "worker" or worker["status"] != "completed" or not worker["snapshotCommit"]:
            raise ValueError("只能整合已成功保存的 Worker 成果。")
        if worker["integrated"]:
            return {"integrated": True, "alreadyIntegrated": True}
        with self.git_lock:
            path = coordinator["worktree"]
            if self.git(path, "symbolic-ref", "--short", "HEAD") != coordinator["branch"]:
                raise ValueError("主控分支已变化。")
            if self.git(path, "status", "--porcelain", "--untracked-files=all"):
                raise ValueError("主控有未提交修改，请先处理后再整合。")
            if worker["snapshotCommit"] != run["baseCommit"]:
                try:
                    self.git(path, "-c", "user.name=Code Pax", "-c", "user.email=agent@codepax.local",
                             "cherry-pick", worker["snapshotCommit"])
                except Exception as error:
                    self.git(path, "cherry-pick", "--abort")
                    raise ValueError("成果存在冲突，已回退本次整合；请审阅后手动处理：" + str(error)) from None
        with self.lock:
            live = self.run(run_id)
            self.task(live, task_id)["integrated"] = True
            self.save(live)
        return {"integrated": True}

    def diff(self, request):
        with self.lock:
            run = copy.deepcopy(self.run(request.get("runId")))
            task = self.task(run, request.get("taskId", "coordinator"))
        if not task["snapshotCommit"]:
            raise ValueError("成员尚未保存成果，请先查看其会话。")
        with tempfile.TemporaryFile() as output:
            process = subprocess.run(["git", "-C", run["cwd"], "diff", "--no-ext-diff", "--no-textconv", "--no-color",
                                      run["baseCommit"], task["snapshotCommit"], "--"], stdout=output,
                                     stderr=subprocess.PIPE, timeout=30)
            if process.returncode:
                raise ValueError(process.stderr.decode(errors="replace")[:4000])
            output.seek(0)
            data = output.read(128000 + 1)
        return {"text": data[:128000].decode(errors="replace"), "truncated": len(data) > 128000}

    def apply(self, request):
        with self.lock:
            run = copy.deepcopy(self.run(request.get("runId")))
            coordinator = self.task(run, "coordinator")
        if run["appliedCommit"]:
            return {"commit": run["appliedCommit"]}
        if run["status"] != "completed" or not coordinator["snapshotCommit"]:
            raise ValueError("请等待主控成功完成汇总和测试后再应用。")
        with self.git_lock:
            source = self.bridge.project(run["cwd"])
            if self.git(source, "symbolic-ref", "--short", "HEAD") != run["sourceBranch"]:
                raise ValueError("原项目已切换分支，请切回 " + run["sourceBranch"] + " 后再应用。")
            if self.git(source, "status", "--porcelain", "--untracked-files=all"):
                raise ValueError("原项目有未提交修改，请先处理后再应用。")
            commit = coordinator["snapshotCommit"]
            head = self.git(source, "rev-parse", "HEAD")
            if head not in {run["baseCommit"], commit}:
                raise ValueError("原项目已产生新提交；请手动审阅成果分支并合并，未自动覆盖项目。")
            self.git(source, "merge", "--ff-only", "--no-edit", commit)
        with self.lock:
            live = self.run(run["id"])
            live["appliedCommit"] = commit
            self.save(live)
        return {"commit": commit}

    def handle_tool(self, message, session):
        params = message["params"]
        def respond(success, value):
            self.bridge.rpc.write({"id": message["id"], "result": {"success": success,
                "contentItems": [{"type": "inputText", "text": json.dumps(value, ensure_ascii=False)}]}})
        if not self.tool_slots.acquire(blocking=False):
            respond(False, {"error": "协作工具忙，请稍后重试。"})
            return
        def execute():
            try:
                run_id, task_id = session.get("collaborationRunId"), session.get("collaborationTaskId")
                with self.lock:
                    run = self.run(run_id)
                    task = self.task(run, task_id)
                    if task["sessionId"] != session["id"] or params.get("turnId") != session.get("turnId"):
                        raise ValueError("协作工具请求不属于当前成员和任务轮次。")
                    role = task["role"]
                name = params.get("tool", "")
                args = params.get("arguments")
                if not isinstance(args, dict) or params.get("namespace"):
                    raise ValueError("无效的协作工具参数。")
                def invoke():
                    if name == "codepax_team_status":
                        with self.lock:
                            current = self.run(run_id)
                            return {"status": current["status"], "tasks": [
                                {k: item.get(k) for k in ("id", "title", "role", "status", "result", "error", "integrated")}
                                for item in current["tasks"]]}
                    if name == "codepax_team_inbox":
                        with self.lock:
                            return {"messages": copy.deepcopy([item for item in self.run(run_id)["messages"]
                                                               if item["to"] in {task_id, "all"}][-50:])}
                    if name == "codepax_team_message":
                        return self.message(dict(runId=run_id, to=args.get("to"), text=args.get("text")), task_id)
                    if name == "codepax_team_integrate" and role == "coordinator":
                        return self.integrate(run_id, args.get("taskId"))
                    raise ValueError("当前角色不能调用这个协作工具。")
                identity = session["id"] + ":" + str(params.get("callId"))
                operation = {"action": "teamTool", "operationId": "team-tool-" + hashlib.sha256(identity.encode()).hexdigest(),
                             "sessionId": session["id"], "tool": name, "arguments": args}
                result = self.bridge.store.operation(operation, invoke)
                respond(result["ok"], result.get("result") if result["ok"] else {"error": result["error"]})
            except Exception as error:
                try:
                    respond(False, {"error": str(error)[:4000]})
                except Exception:
                    pass
            finally:
                self.tool_slots.release()
        threading.Thread(target=execute, daemon=True).start()
