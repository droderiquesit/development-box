"""Foreman's core: runs, tasks, worker events, reviews and merges.

All state changes happen under one asyncio lock and re-read the stored
document first, so concurrent worker events and scheduler ticks never
overwrite each other. Foreman is designed to run as a single instance.
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import logging
import re
import secrets
from collections.abc import Coroutine
from typing import Any, Literal

from pydantic import BaseModel, Field

from foreman.config import Settings
from foreman.executors.base import ExecState, Executor
from foreman.fleet import Fleet
from foreman.github import REPO, GitHub, GitHubError, parse_pr_url
from foreman.llm import ChatModel
from foreman.models import (
    ACTIVE_RUN,
    MAX_ATTEMPTS,
    TERMINAL_TASK,
    Event,
    Run,
    RunStatus,
    Task,
    TaskStatus,
    Usage,
    utcnow,
)
from foreman.planner import plan_blueprint
from foreman.review import findings_feedback, review_pr
from foreman.scheduler import plan_tick, status_after_failure
from foreman.store.base import Store

log = logging.getLogger(__name__)

BRANCH = re.compile(r"^[A-Za-z0-9._/-]{1,100}$")
MAX_BLUEPRINT_CHARS = 100_000
MAX_REVIEW_ATTEMPTS = 3


class ForemanError(Exception):
    status_code = 400


class NotFound(ForemanError):
    status_code = 404


class Conflict(ForemanError):
    status_code = 409


class Unauthorized(ForemanError):
    status_code = 401


class WorkerEvent(BaseModel):
    type: Literal["started", "log", "heartbeat", "finished", "failed"]
    message: str | None = Field(default=None, max_length=8000)
    pr_url: str | None = Field(default=None, max_length=300)
    branch: str | None = Field(default=None, pattern=BRANCH.pattern)
    usage: Usage | None = None


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


class Foreman:
    def __init__(self, settings: Settings, store: Store, executor: Executor, planner: ChatModel,
                 reviewer: ChatModel, github: GitHub, fleet: Fleet) -> None:
        self.settings = settings
        self.store = store
        self.executor = executor
        self.planner = planner
        self.reviewer = reviewer
        self.github = github
        self.fleet = fleet
        self._lock = asyncio.Lock()
        self._background: set[asyncio.Task[Any]] = set()
        self._reviewing: set[tuple[str, str]] = set()
        self._changed = asyncio.Condition()
        self._versions: dict[str, int] = {}

    # ----------------------------------------------------------------- helpers
    def _spawn(self, coro: Coroutine[Any, Any, Any]) -> None:
        task = asyncio.create_task(coro)
        self._background.add(task)
        task.add_done_callback(self._background.discard)

    async def _event(self, run_id: str, type_: str, message: str = "", task_id: str | None = None) -> None:
        await self.store.append_event(Event(run_id=run_id, task_id=task_id, type=type_, message=message[:2000]))
        self._versions[run_id] = self._versions.get(run_id, 0) + 1
        async with self._changed:
            self._changed.notify_all()

    def version(self, run_id: str) -> int:
        return self._versions.get(run_id, 0)

    async def wait_for_change(self, run_id: str, seen: int, within_s: float) -> int:
        try:
            async with self._changed:
                await asyncio.wait_for(self._changed.wait_for(lambda: self.version(run_id) != seen), within_s)
        except TimeoutError:
            pass
        return self.version(run_id)

    async def _save_task(self, task: Task) -> None:
        task.updated_at = utcnow()
        await self.store.put_task(task)

    async def _save_run(self, run: Run) -> None:
        run.updated_at = utcnow()
        await self.store.put_run(run)

    async def get_run(self, run_id: str) -> Run:
        run = await self.store.get_run(run_id)
        if run is None:
            raise NotFound(f"run {run_id} not found")
        return run

    async def get_task(self, run_id: str, task_id: str) -> Task:
        task = await self.store.get_task(run_id, task_id)
        if task is None:
            raise NotFound(f"task {task_id} not found in run {run_id}")
        return task

    async def wait_idle(self) -> None:
        """Wait for background planning/review work (tests and shutdown)."""
        while self._background:
            await asyncio.gather(*list(self._background), return_exceptions=True)

    # -------------------------------------------------------------------- runs
    async def create_run(self, blueprint_md: str, repo: str, base_branch: str, max_agents: int,
                         plan_only: bool, created_by: str) -> Run:
        blueprint_md = blueprint_md.strip()
        if not blueprint_md or len(blueprint_md) > MAX_BLUEPRINT_CHARS:
            raise ForemanError(f"blueprint must be 1-{MAX_BLUEPRINT_CHARS} characters")
        if not REPO.match(repo):
            raise ForemanError("repo must look like owner/name")
        if not BRANCH.match(base_branch):
            raise ForemanError("invalid base branch")
        if not 1 <= max_agents <= 20:
            raise ForemanError("max_agents must be between 1 and 20")
        run = Run(blueprint_md=blueprint_md, repo=repo, base_branch=base_branch, max_agents=max_agents,
                  plan_only=plan_only, created_by=created_by)
        await self._save_run(run)
        await self._event(run.id, "run_created", f"by {created_by}")
        self._spawn(self._plan(run.id))
        return run

    async def _plan(self, run_id: str) -> None:
        run = await self.get_run(run_id)
        try:
            plan, usage = await plan_blueprint(self.planner, run.blueprint_md, run.repo, run.base_branch,
                                               run.max_agents)
        except Exception as exc:  # noqa: BLE001 - recorded on the run
            log.warning("planning %s failed: %s", run_id, exc)
            async with self._lock:
                run = await self.get_run(run_id)
                if run.status == RunStatus.planning:
                    run.status, run.error = RunStatus.failed, f"planning failed: {exc}"[:2000]
                    await self._save_run(run)
            await self._event(run_id, "plan_failed", str(exc))
            return
        async with self._lock:
            run = await self.get_run(run_id)
            if run.status != RunStatus.planning:  # cancelled meanwhile
                return
            for position, item in enumerate(plan.tasks):
                await self._save_task(Task(run_id=run.id, position=position, **item.model_dump()))
            run.plan = plan
            run.usage.planner.add(usage)
            run.status = RunStatus.awaiting_approval if run.plan_only else RunStatus.running
            await self._save_run(run)
        await self._event(run_id, "planned", f"{len(plan.tasks)} task(s)")

    async def approve_plan(self, run_id: str, by: str) -> Run:
        async with self._lock:
            run = await self.get_run(run_id)
            if run.status != RunStatus.awaiting_approval:
                raise Conflict(f"run is {run.status}, not awaiting approval")
            run.status = RunStatus.running
            await self._save_run(run)
        await self._event(run_id, "plan_approved", f"by {by}")
        return run

    async def cancel_run(self, run_id: str, by: str) -> Run:
        async with self._lock:
            run = await self.get_run(run_id)
            if run.status not in ACTIVE_RUN:
                raise Conflict(f"run is already {run.status}")
            handles = []
            for task in await self.store.list_tasks(run_id):
                if task.status in TERMINAL_TASK or task.status in {TaskStatus.pr_open, TaskStatus.reviewed}:
                    continue
                if task.status == TaskStatus.running and task.handle:
                    handles.append(task.handle)
                task.status, task.token_hash = TaskStatus.cancelled, None
                await self._save_task(task)
            run.status = RunStatus.cancelled
            await self._save_run(run)
        for handle in handles:
            try:
                await self.executor.cancel(handle)
            except Exception as exc:  # noqa: BLE001 - the task is cancelled either way
                log.warning("cancel %s failed: %s", handle, exc)
        await self._event(run_id, "run_cancelled", f"by {by}")
        return run

    async def merge_task(self, run_id: str, task_id: str, by: str) -> Task:
        """Squash-merge a task's PR. Only ever called on an explicit human request."""
        run = await self.get_run(run_id)
        task = await self.get_task(run_id, task_id)
        if task.status not in {TaskStatus.pr_open, TaskStatus.reviewed} or not task.pr_url:
            raise Conflict(f"task is {task.status}; nothing to merge")
        number = parse_pr_url(task.pr_url, run.repo)
        try:
            sha = await self.github.head_sha(run.repo, number)
            checks = await self.github.checks_state(run.repo, sha)
            if checks != "success":
                raise Conflict(f"refusing to merge: checks are {checks}")
            await self.github.merge_pr(run.repo, number, sha)
        except GitHubError as exc:
            raise Conflict(str(exc)) from exc
        async with self._lock:
            task = await self.get_task(run_id, task_id)
            task.status, task.merged_by = TaskStatus.merged, by
            await self._save_task(task)
        await self._event(run_id, "merged", f"{task.pr_url} by {by}", task_id)
        return task

    # --------------------------------------------------------------- scheduling
    async def tick(self) -> None:
        for run in await self.store.list_runs_by_status(RunStatus.running):
            await self._tick_run(run.id)

    async def _tick_run(self, run_id: str) -> None:
        tasks = await self.store.list_tasks(run_id)
        exited: set[str] = set()
        for task in tasks:
            if task.status == TaskStatus.running and task.handle:
                try:
                    if await self.executor.status(task.handle) == ExecState.exited:
                        exited.add(task.id)
                except Exception as exc:  # noqa: BLE001 - heartbeat timeout still applies
                    log.warning("status of %s failed: %s", task.handle, exc)

        async with self._lock:
            run = await self.get_run(run_id)
            if run.status != RunStatus.running:
                return
            tasks = await self.store.list_tasks(run_id)
            plan = plan_tick(tasks, max_parallel=min(run.max_agents, self.settings.max_concurrency),
                             gate=self.settings.dependency_gate, now=utcnow(),
                             heartbeat_timeout_s=self.settings.heartbeat_timeout_s, exited=exited)
            by_id = {t.id: t for t in tasks}
            notes: list[tuple[str, str, str]] = []
            for task_id, reason in plan.stuck.items():
                notes.append(await self._fail(by_id[task_id], reason))
            for task_id in plan.blocked:
                task = by_id[task_id]
                task.status, task.error = TaskStatus.cancelled, "a dependency failed"
                await self._save_task(task)
                notes.append((task_id, "blocked", "a dependency failed"))
            for task_id in plan.make_ready:
                by_id[task_id].status = TaskStatus.ready
                await self._save_task(by_id[task_id])
            launches = [await self._prepare_dispatch(run, by_id[task_id]) for task_id in plan.dispatch]
            if plan.run_status:
                run.status = plan.run_status
                await self._save_run(run)
                notes.append(("", f"run_{plan.run_status}", ""))
        for task_id, type_, message in notes:
            await self._event(run_id, type_, message, task_id or None)
        for task, env in launches:
            await self._launch(task, env)
        for task in tasks:
            key = (run_id, task.id)
            if (task.status == TaskStatus.pr_open and key not in self._reviewing
                    and task.review_attempts < MAX_REVIEW_ATTEMPTS):
                self._start_review(run_id, task.id)

    async def _prepare_dispatch(self, run: Run, task: Task) -> tuple[Task, dict[str, str]]:
        token = f"{run.id}.{task.id}.{secrets.token_urlsafe(32)}"
        task.status, task.token_hash, task.handle, task.error = TaskStatus.running, hash_token(token), None, None
        task.attempts += 1
        task.branch = task.branch or f"foreman/{run.id[:8]}/{task.id}"
        task.last_heartbeat = utcnow()
        await self._save_task(task)
        return task, {"TASK_ID": task.id, "TASK_TOKEN": token, "FOREMAN_URL": self.settings.url}

    async def _launch(self, task: Task, env: dict[str, str]) -> None:
        try:
            handle = await self.executor.launch(task, env)
        except Exception as exc:  # noqa: BLE001 - becomes a task failure
            async with self._lock:
                current = await self.get_task(task.run_id, task.id)
                note = await self._fail(current, f"launch failed: {exc}") if current.status == TaskStatus.running \
                    else None
            if note:
                await self._event(task.run_id, note[1], note[2], task.id)
            return
        async with self._lock:
            current = await self.get_task(task.run_id, task.id)
            if current.status == TaskStatus.running and current.attempts == task.attempts:
                current.handle = handle
                await self._save_task(current)
        await self._event(task.run_id, "dispatched", f"attempt {task.attempts} ({handle})", task.id)

    async def _fail(self, task: Task, reason: str) -> tuple[str, str, str]:
        """Record a failed attempt (caller holds the lock). Returns an event to emit."""
        task.log(f"FAILED: {reason}")
        task.error = reason[:2000]
        task.token_hash = None
        tail = "\n".join(task.log_tail[-20:])
        task.feedback = f"Previous attempt {task.attempts} failed: {reason}\nLast log lines:\n{tail}"[-4000:]
        task.status = status_after_failure(task)
        await self._save_task(task)
        kind = "retrying" if task.status == TaskStatus.pending else "task_failed"
        return task.id, kind, reason

    # ------------------------------------------------------------------ workers
    async def authenticate_worker(self, token: str) -> Task:
        parts = token.split(".")
        if len(parts) != 3:
            raise Unauthorized("invalid task token")
        task = await self.store.get_task(parts[0], parts[1])
        if task is None or task.token_hash is None or task.status != TaskStatus.running:
            raise Unauthorized("invalid task token")
        if not hmac.compare_digest(hash_token(token), task.token_hash):
            raise Unauthorized("invalid task token")
        return task

    async def worker_task_spec(self, task: Task) -> dict[str, Any]:
        run = await self.get_run(task.run_id)
        return {
            "task_id": task.id,
            "run_id": run.id,
            "repo_url": f"https://github.com/{run.repo}.git",
            "base_branch": run.base_branch,
            "branch": task.branch,
            "title": task.title,
            "prompt": await self._worker_prompt(run, task),
            "acceptance": task.acceptance,
            "model": {"base_url": self.settings.worker_base_url, "name": self.settings.worker_model},
            "limits": {"max_turns": self.settings.worker_max_turns, "timeout_s": self.settings.worker_timeout_s},
        }

    async def _worker_prompt(self, run: Run, task: Task) -> str:
        tasks = {t.id: t for t in await self.store.list_tasks(run.id)}
        parts = [
            f"Repository {run.repo}, base branch {run.base_branch}. Work on branch {task.branch} and open ONE "
            f"pull request into {run.base_branch}.",
        ]
        if run.plan:
            parts.append(f"Project context: {run.plan.summary}")
        parts.append(f"Task {task.id}: {task.title}\n{task.description}")
        if task.tests:
            parts.append("Tests expected:\n" + "\n".join(f"- {t}" for t in task.tests))
        if task.files_hint:
            parts.append("Start from: " + ", ".join(task.files_hint))
        done = [tasks[d] for d in task.depends_on if d in tasks]
        if done:
            parts.append("Builds on: " + "; ".join(f"{d.id} ({d.title}) {d.pr_url or ''}".strip() for d in done))
        if task.pr_url:
            parts.append(f"A pull request already exists: {task.pr_url}. Push fixes to the same branch.")
        if task.feedback:
            parts.append(task.feedback[-4000:])
        parts.append("Read only the files you need. Run the tests before finishing.")
        return "\n\n".join(parts)

    async def worker_event(self, token_task: Task, event: WorkerEvent) -> None:
        note: tuple[str, str, str] | None = None
        async with self._lock:
            task = await self.get_task(token_task.run_id, token_task.id)
            if task.status != TaskStatus.running or task.token_hash != token_task.token_hash:
                raise Unauthorized("task is no longer running")
            run = await self.get_run(task.run_id)
            task.last_heartbeat = utcnow()
            if event.usage:
                task.usage.add(event.usage)
                run.usage.workers.add(event.usage)
                await self._save_run(run)
            if event.message and event.type != "heartbeat":
                task.log(f"{event.type}: {event.message}")
            if event.type == "finished":
                try:
                    if not event.pr_url:
                        raise GitHubError("worker finished without a pr_url")
                    parse_pr_url(event.pr_url, run.repo)
                except GitHubError as exc:
                    note = await self._fail(task, str(exc))
                else:
                    task.status, task.pr_url, task.token_hash = TaskStatus.pr_open, event.pr_url, None
                    task.branch = event.branch or task.branch
                    task.review_attempts = 0
                    await self._save_task(task)
                    note = (task.id, "pr_opened", event.pr_url)
            elif event.type == "failed":
                note = await self._fail(task, event.message or "worker reported failure")
            else:
                await self._save_task(task)
        if event.type in {"started", "log", "finished", "failed"}:
            message = note[2] if note else (event.message or "")
            await self._event(task.run_id, note[1] if note else event.type, message, task.id)
        if note and note[1] == "pr_opened":
            self._start_review(task.run_id, task.id)

    # ------------------------------------------------------------------ reviews
    def _start_review(self, run_id: str, task_id: str) -> None:
        key = (run_id, task_id)
        if key in self._reviewing:
            return
        self._reviewing.add(key)
        self._spawn(self._review(run_id, task_id))

    async def _review(self, run_id: str, task_id: str) -> None:
        try:
            run = await self.get_run(run_id)
            task = await self.get_task(run_id, task_id)
            if task.status != TaskStatus.pr_open or not task.pr_url:
                return
            try:
                number = parse_pr_url(task.pr_url, run.repo)
                result, usage = await review_pr(self.reviewer, self.github, run.repo, number, task,
                                                self.settings.review_max_diff_bytes)
            except Exception as exc:  # noqa: BLE001 - retried by the scheduler
                async with self._lock:
                    task = await self.get_task(run_id, task_id)
                    task.review_attempts += 1
                    task.error = f"review failed: {exc}"[:2000]
                    await self._save_task(task)
                await self._event(run_id, "review_failed", str(exc), task_id)
                return
            async with self._lock:
                task = await self.get_task(run_id, task_id)
                if task.status != TaskStatus.pr_open:
                    return
                run = await self.get_run(run_id)
                run.usage.reviewer.add(usage)
                await self._save_run(run)
                task.review, task.review_attempts = result, task.review_attempts + 1
                if result.verdict == "request_changes" and task.attempts < MAX_ATTEMPTS:
                    task.status = TaskStatus.pending
                    task.feedback = findings_feedback(result)[-4000:]
                else:
                    task.status = TaskStatus.reviewed
                await self._save_task(task)
            requeued = task.status == TaskStatus.pending
            await self._event(run_id, "review", f"{result.verdict}{' (re-queued)' if requeued else ''}", task_id)
        finally:
            self._reviewing.discard((run_id, task_id))

    # --------------------------------------------------------------- summaries
    @staticmethod
    def progress(tasks: list[Task]) -> dict[str, int]:
        counts: dict[str, int] = {s.value: 0 for s in TaskStatus}
        for task in tasks:
            counts[task.status.value] += 1
        done = counts["reviewed"] + counts["merged"]
        counts["total"] = len(tasks)
        counts["done"] = done
        counts["percent"] = round(100 * done / len(tasks)) if tasks else 0
        return counts


def run_summary(run: Run, tasks: list[Task]) -> dict[str, Any]:
    return {
        "id": run.id,
        "repo": run.repo,
        "base_branch": run.base_branch,
        "status": run.status,
        "max_agents": run.max_agents,
        "plan_only": run.plan_only,
        "created_by": run.created_by,
        "created_at": run.created_at,
        "error": run.error,
        "usage": run.usage.model_dump(),
        "progress": Foreman.progress(tasks),
    }


def public_task(task: Task) -> dict[str, Any]:
    return task.model_dump(mode="json", exclude={"token_hash", "feedback"})
