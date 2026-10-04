"""Scheduling decisions (pure) and the asyncio loop that applies them.

``plan_tick`` is a pure function of a run's tasks and the clock; the
``Scheduler`` loop does the IO (store, executor) through ``Foreman.tick``.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Literal

from foreman.models import MAX_ATTEMPTS, RunStatus, Task, TaskStatus

log = logging.getLogger(__name__)

DONE_FOR_GATE: dict[str, set[TaskStatus]] = {
    "reviewed": {TaskStatus.reviewed, TaskStatus.merged},
    "merged": {TaskStatus.merged},
}
OPEN = {TaskStatus.pending, TaskStatus.ready, TaskStatus.running, TaskStatus.pr_open}


@dataclass
class TickPlan:
    make_ready: list[str] = field(default_factory=list)
    dispatch: list[str] = field(default_factory=list)
    stuck: dict[str, str] = field(default_factory=dict)  # task id -> reason
    blocked: list[str] = field(default_factory=list)
    run_status: RunStatus | None = None


def plan_tick(tasks: list[Task], *, max_parallel: int, gate: Literal["reviewed", "merged"], now: datetime,
              heartbeat_timeout_s: float, exited: set[str]) -> TickPlan:
    plan = TickPlan()
    by_id = {t.id: t for t in tasks}
    done = DONE_FOR_GATE[gate]
    dead = {TaskStatus.failed, TaskStatus.cancelled}

    for task in tasks:
        if task.status == TaskStatus.pending:
            deps = [by_id[d] for d in task.depends_on if d in by_id]
            if any(d.status in dead for d in deps):
                plan.blocked.append(task.id)
            elif all(d.status in done for d in deps):
                plan.make_ready.append(task.id)
        elif task.status == TaskStatus.running:
            if task.id in exited:
                plan.stuck[task.id] = "worker exited without reporting a result"
            elif task.last_heartbeat and now - task.last_heartbeat > timedelta(seconds=heartbeat_timeout_s):
                plan.stuck[task.id] = f"no heartbeat for over {int(heartbeat_timeout_s)}s"

    running = sum(1 for t in tasks if t.status == TaskStatus.running and t.id not in plan.stuck)
    ready = [t.id for t in tasks if t.status == TaskStatus.ready or t.id in plan.make_ready]
    plan.dispatch = ready[: max(0, max_parallel - running)]

    changed = plan.make_ready or plan.stuck or plan.blocked
    if tasks and not changed and not any(t.status in OPEN for t in tasks):
        ok = all(t.status in {TaskStatus.reviewed, TaskStatus.merged} for t in tasks)
        plan.run_status = RunStatus.completed if ok else RunStatus.failed
    return plan


def status_after_failure(task: Task) -> TaskStatus:
    """A failed attempt is retried once (attempts counts dispatches)."""
    return TaskStatus.pending if task.attempts < MAX_ATTEMPTS else TaskStatus.failed


class Scheduler:
    def __init__(self, tick: Callable[[], Awaitable[None]], interval_s: float) -> None:
        self._tick = tick
        self.interval_s = interval_s
        self._task: asyncio.Task[None] | None = None

    async def _loop(self) -> None:
        while True:
            try:
                await self._tick()
            except Exception:  # keep scheduling; the next tick retries
                log.exception("scheduler tick failed")
            await asyncio.sleep(self.interval_s)

    def start(self) -> None:
        self._task = asyncio.create_task(self._loop())

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._task
