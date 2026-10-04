"""Executor interface: start one worker per task attempt and observe it."""

from __future__ import annotations

from enum import StrEnum
from typing import Protocol

from foreman.models import Task


class ExecState(StrEnum):
    running = "running"
    exited = "exited"  # finished or vanished; the task's own events say whether it succeeded


class Executor(Protocol):
    async def launch(self, task: Task, env: dict[str, str]) -> str:
        """Start a worker with ``env`` (TASK_ID, TASK_TOKEN, FOREMAN_URL) and return a handle."""
        ...

    async def status(self, handle: str) -> ExecState: ...

    async def cancel(self, handle: str) -> None: ...
