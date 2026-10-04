"""SQLite store for local mode: one JSON document per row."""

from __future__ import annotations

import asyncio
import sqlite3
import threading
from typing import Any

from foreman.models import Event, Run, RunStatus, Task

_SCHEMA = """
CREATE TABLE IF NOT EXISTS runs (
    id TEXT PRIMARY KEY, status TEXT NOT NULL, created_at TEXT NOT NULL, data TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS runs_created ON runs (created_at);
CREATE TABLE IF NOT EXISTS tasks (
    run_id TEXT NOT NULL, id TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY (run_id, id));
CREATE TABLE IF NOT EXISTS events (
    seq INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, data TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS events_run ON events (run_id, seq);
"""


class SqliteStore:
    def __init__(self, path: str) -> None:
        self._db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.executescript(_SCHEMA)
        self._lock = threading.Lock()

    async def _exec(self, sql: str, params: tuple[Any, ...] = ()) -> list[tuple[Any, ...]]:
        def run() -> list[tuple[Any, ...]]:
            with self._lock:
                return self._db.execute(sql, params).fetchall()

        return await asyncio.to_thread(run)

    async def put_run(self, run: Run) -> None:
        await self._exec(
            "INSERT INTO runs (id, status, created_at, data) VALUES (?, ?, ?, ?) "
            "ON CONFLICT(id) DO UPDATE SET status=excluded.status, data=excluded.data",
            (run.id, run.status.value, run.created_at.isoformat(), run.model_dump_json()),
        )

    async def get_run(self, run_id: str) -> Run | None:
        rows = await self._exec("SELECT data FROM runs WHERE id = ?", (run_id,))
        return Run.model_validate_json(rows[0][0]) if rows else None

    async def list_runs(self, limit: int = 20) -> list[Run]:
        rows = await self._exec("SELECT data FROM runs ORDER BY created_at DESC LIMIT ?", (limit,))
        return [Run.model_validate_json(r[0]) for r in rows]

    async def list_runs_by_status(self, status: RunStatus) -> list[Run]:
        rows = await self._exec("SELECT data FROM runs WHERE status = ?", (status.value,))
        return [Run.model_validate_json(r[0]) for r in rows]

    async def put_task(self, task: Task) -> None:
        await self._exec(
            "INSERT INTO tasks (run_id, id, data) VALUES (?, ?, ?) "
            "ON CONFLICT(run_id, id) DO UPDATE SET data=excluded.data",
            (task.run_id, task.id, task.model_dump_json()),
        )

    async def get_task(self, run_id: str, task_id: str) -> Task | None:
        rows = await self._exec("SELECT data FROM tasks WHERE run_id = ? AND id = ?", (run_id, task_id))
        return Task.model_validate_json(rows[0][0]) if rows else None

    async def list_tasks(self, run_id: str) -> list[Task]:
        rows = await self._exec(
            "SELECT data FROM tasks WHERE run_id = ? ORDER BY json_extract(data, '$.position'), rowid",
            (run_id,),
        )
        return [Task.model_validate_json(r[0]) for r in rows]

    async def append_event(self, event: Event) -> None:
        await self._exec(
            "INSERT INTO events (run_id, data) VALUES (?, ?)", (event.run_id, event.model_dump_json())
        )

    async def list_events(self, run_id: str, limit: int = 50) -> list[Event]:
        rows = await self._exec(
            "SELECT data FROM events WHERE run_id = ? ORDER BY seq DESC LIMIT ?", (run_id, limit)
        )
        return [Event.model_validate_json(r[0]) for r in rows]

    async def close(self) -> None:
        self._db.close()
