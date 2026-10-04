"""Run each worker as a detached, auto-removed podman container (local mode)."""

from __future__ import annotations

import asyncio
import os

from foreman.executors.base import ExecState
from foreman.models import Task


class PodmanError(RuntimeError):
    pass


class LocalPodmanExecutor:
    def __init__(self, image: str, network: str = "host", secrets: dict[str, str] | None = None,
                 podman: str = "podman") -> None:
        self.image = image
        self.network = network
        # Local mode only: model key / GitHub token handed to the worker as env.
        self.secrets = secrets or {}
        self.podman = podman

    def command(self, name: str, env: dict[str, str]) -> list[str]:
        cmd = [self.podman, "run", "--rm", "-d", "--name", name, "--network", self.network,
               "--cap-drop=ALL", "--security-opt=no-new-privileges", "--pids-limit=1024"]
        # Values travel through the child's environment, never argv (visible in `ps`).
        for key in sorted({**env, **self.secrets}):
            cmd += ["--env", key]
        return [*cmd, self.image]

    async def _run(self, args: list[str], env: dict[str, str] | None = None) -> tuple[int, str]:
        proc = await asyncio.create_subprocess_exec(
            *args, env={**os.environ, **(env or {})},
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
        )
        out, _ = await proc.communicate()
        return proc.returncode or 0, out.decode(errors="replace").strip()

    async def launch(self, task: Task, env: dict[str, str]) -> str:
        name = f"foreman-{task.run_id[:8]}-{task.id}-{task.attempts}"
        code, out = await self._run(self.command(name, env), {**env, **self.secrets})
        if code != 0:
            raise PodmanError(f"podman run failed ({code}): {out[-500:]}")
        return name

    async def status(self, handle: str) -> ExecState:
        code, out = await self._run([self.podman, "container", "inspect", "--format", "{{.State.Running}}", handle])
        # --rm removes the container on exit, so "not found" means it has exited.
        return ExecState.running if code == 0 and out == "true" else ExecState.exited

    async def cancel(self, handle: str) -> None:
        await self._run([self.podman, "stop", "--time", "10", handle])
