"""An in-process stand-in worker for fake mode and tests.

It speaks the real worker HTTP contract against FOREMAN_URL (fetch the task,
post started/log/heartbeat/finished), so it doubles as a reference client for
the worker implementation. It writes no code and opens no real PR.
"""

from __future__ import annotations

import asyncio
import random

import httpx

from foreman.executors.base import ExecState
from foreman.models import Task


class SimulatedExecutor:
    def __init__(self, step_s: float = 1.0, transport: httpx.AsyncBaseTransport | None = None) -> None:
        self.step_s = step_s
        self.transport = transport
        self._jobs: dict[str, asyncio.Task[None]] = {}

    async def launch(self, task: Task, env: dict[str, str]) -> str:
        handle = f"sim-{task.run_id[:8]}-{task.id}-{task.attempts}"
        self._jobs[handle] = asyncio.create_task(self._work(env))
        return handle

    async def _work(self, env: dict[str, str]) -> None:
        headers = {"Authorization": f"Bearer {env['TASK_TOKEN']}"}
        async with httpx.AsyncClient(base_url=env["FOREMAN_URL"], headers=headers,
                                     transport=self.transport, timeout=10) as client:
            spec = (await client.get("/api/worker/task")).raise_for_status().json()

            async def post(**event: object) -> None:
                (await client.post("/api/worker/events", json=event)).raise_for_status()

            await post(type="started", message=f"simulated worker on {spec['branch']}")
            for step in ("cloning repository", "reading relevant files", "writing code", "running tests"):
                await asyncio.sleep(self.step_s)
                await post(type="log", message=step)
                await post(type="heartbeat")
            repo = spec["repo_url"].removeprefix("https://github.com/").removesuffix(".git")
            await post(
                type="finished",
                message="opened pull request",
                branch=spec["branch"],
                pr_url=f"https://github.com/{repo}/pull/{random.randint(1, 9999)}",  # noqa: S311 - fake PR number
                usage={"prompt_tokens": 1200, "completion_tokens": 300},
            )

    async def status(self, handle: str) -> ExecState:
        job = self._jobs.get(handle)
        return ExecState.running if job is not None and not job.done() else ExecState.exited

    async def cancel(self, handle: str) -> None:
        job = self._jobs.get(handle)
        if job is not None:
            job.cancel()
