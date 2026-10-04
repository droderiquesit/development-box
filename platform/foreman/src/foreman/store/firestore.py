"""Firestore store for gcp mode.

Layout: ``runs/{run_id}``, ``runs/{run_id}/tasks/{task_id}``,
``runs/{run_id}/events/{event_id}``. Timestamps are stored as ISO-8601 UTC
strings, which sort lexicographically in time order.
"""

from __future__ import annotations

from google.cloud import firestore

from foreman.models import Event, Run, RunStatus, Task


class FirestoreStore:
    def __init__(self, project: str, database: str = "(default)", client: firestore.AsyncClient | None = None):
        self._db = client or firestore.AsyncClient(project=project, database=database)

    def _run_ref(self, run_id: str) -> firestore.AsyncDocumentReference:
        return self._db.collection("runs").document(run_id)

    async def put_run(self, run: Run) -> None:
        await self._run_ref(run.id).set(run.model_dump(mode="json"))

    async def get_run(self, run_id: str) -> Run | None:
        snap = await self._run_ref(run_id).get()
        return Run.model_validate(snap.to_dict()) if snap.exists else None

    async def list_runs(self, limit: int = 20) -> list[Run]:
        query = (
            self._db.collection("runs")
            .order_by("created_at", direction=firestore.Query.DESCENDING)
            .limit(limit)
        )
        return [Run.model_validate(doc.to_dict()) async for doc in query.stream()]

    async def list_runs_by_status(self, status: RunStatus) -> list[Run]:
        query = self._db.collection("runs").where(filter=firestore.FieldFilter("status", "==", status.value))
        return [Run.model_validate(doc.to_dict()) async for doc in query.stream()]

    async def put_task(self, task: Task) -> None:
        await self._run_ref(task.run_id).collection("tasks").document(task.id).set(task.model_dump(mode="json"))

    async def get_task(self, run_id: str, task_id: str) -> Task | None:
        snap = await self._run_ref(run_id).collection("tasks").document(task_id).get()
        return Task.model_validate(snap.to_dict()) if snap.exists else None

    async def list_tasks(self, run_id: str) -> list[Task]:
        docs = self._run_ref(run_id).collection("tasks").stream()
        tasks = [Task.model_validate(doc.to_dict()) async for doc in docs]
        return sorted(tasks, key=lambda t: t.position)

    async def append_event(self, event: Event) -> None:
        await self._run_ref(event.run_id).collection("events").document(event.id).set(event.model_dump(mode="json"))

    async def list_events(self, run_id: str, limit: int = 50) -> list[Event]:
        query = (
            self._run_ref(run_id)
            .collection("events")
            .order_by("created_at", direction=firestore.Query.DESCENDING)
            .limit(limit)
        )
        return [Event.model_validate(doc.to_dict()) async for doc in query.stream()]

    async def close(self) -> None:
        self._db.close()
