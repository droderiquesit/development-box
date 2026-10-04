from __future__ import annotations

import json
from collections.abc import AsyncIterator, Callable
from typing import Any

import httpx
import pytest

from foreman.app import create_app
from foreman.config import Settings
from foreman.executors.base import ExecState
from foreman.fake import FakeGitHub, FakeModel
from foreman.fleet import StubFleet
from foreman.models import Task, Usage
from foreman.service import Foreman
from foreman.store.sqlite import SqliteStore

BLUEPRINT = """# Todo service

## Data model
Tasks with title and done flag.

## REST API
CRUD endpoints.

## Web UI
A small page.
"""


class ScriptedModel:
    """Returns queued replies in order; records the json_schema argument of each call."""

    def __init__(self, *replies: str | Exception, name: str = "scripted") -> None:
        self.name = name
        self.replies = list(replies)
        self.schemas: list[dict[str, Any] | None] = []
        self.messages: list[list[dict[str, str]]] = []

    async def chat(self, messages: list[dict[str, str]], json_schema: dict[str, Any] | None) -> tuple[str, Usage]:
        self.schemas.append(json_schema)
        self.messages.append(messages)
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply, Usage(prompt_tokens=10, completion_tokens=5)


class RecordingExecutor:
    """Executor that launches nothing; tests drive worker events themselves."""

    def __init__(self) -> None:
        self.launched: list[tuple[Task, dict[str, str]]] = []
        self.cancelled: list[str] = []
        self.states: dict[str, ExecState] = {}
        self.fail_launch = False

    async def launch(self, task: Task, env: dict[str, str]) -> str:
        if self.fail_launch:
            raise RuntimeError("no capacity")
        handle = f"h-{task.id}-{task.attempts}"
        self.launched.append((task, env))
        self.states[handle] = ExecState.running
        return handle

    async def status(self, handle: str) -> ExecState:
        return self.states.get(handle, ExecState.exited)

    async def cancel(self, handle: str) -> None:
        self.cancelled.append(handle)


def plan_json(*tasks: tuple[str, list[str]]) -> str:
    return json.dumps({
        "summary": "test plan",
        "tasks": [
            {"id": tid, "title": f"Task {tid}", "description": f"do {tid}", "acceptance": [f"{tid} works"],
             "tests": [], "files_hint": [], "depends_on": deps}
            for tid, deps in tasks
        ],
    })


@pytest.fixture
def settings(tmp_path: Any) -> Settings:
    return Settings(db_path=str(tmp_path / "foreman.db"), fake_models=True, executor="simulated",
                    url="http://testserver", scheduler_interval_s=0.05)


@pytest.fixture
def executor() -> RecordingExecutor:
    return RecordingExecutor()


@pytest.fixture
def github() -> FakeGitHub:
    return FakeGitHub()


@pytest.fixture
def make_app(settings: Settings, executor: RecordingExecutor, github: FakeGitHub) -> Callable[..., Any]:
    def factory(app_settings: Settings | None = None, **overrides: Any) -> Any:
        kwargs: dict[str, Any] = {
            "store": SqliteStore(settings.db_path),
            "executor": executor,
            "planner": FakeModel("planner"),
            "reviewer": FakeModel("reviewer"),
            "github": github,
            "fleet": StubFleet({"architect": 3.5, "coder": 1.25, "fast": 0.5}),
            "run_scheduler": False,
        }
        kwargs.update(overrides)
        return create_app(app_settings or settings, **kwargs)

    return factory


@pytest.fixture
async def app(make_app: Callable[..., Any]) -> Any:
    return make_app()


@pytest.fixture
async def client(app: Any) -> AsyncIterator[httpx.AsyncClient]:
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://testserver") as c:
        yield c


@pytest.fixture
def svc(app: Any) -> Foreman:
    return app.state.foreman
