"""JSON API, SSE stream and the worker contract."""

from __future__ import annotations

import json
import time
from collections.abc import AsyncIterator
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from foreman.auth import bearer, current_user, require_csrf
from foreman.fleet import UnknownModel
from foreman.models import Task
from foreman.service import Foreman, Unauthorized, WorkerEvent, public_task, run_summary

router = APIRouter(prefix="/api", dependencies=[Depends(require_csrf)])
worker_router = APIRouter(prefix="/api/worker")


def foreman(request: Request) -> Foreman:
    return request.app.state.foreman


Svc = Annotated[Foreman, Depends(foreman)]
User = Annotated[str, Depends(current_user)]


class RunCreate(BaseModel):
    blueprint_md: str = Field(min_length=1)
    repo: str
    base_branch: str = "main"
    max_agents: int = Field(default=5, ge=1, le=20)
    plan_only: bool = True


def _changed(request: Request, response: Response) -> None:
    """Tell HTMX pages to refresh their fragments after an action."""
    if request.headers.get("hx-request"):
        response.headers["HX-Trigger"] = "foreman-changed"


async def run_detail(svc: Foreman, run_id: str) -> dict[str, Any]:
    run = await svc.get_run(run_id)
    tasks = await svc.store.list_tasks(run_id)
    events = await svc.store.list_events(run_id, limit=50)
    return {
        **run_summary(run, tasks),
        "blueprint_md": run.blueprint_md,
        "plan": run.plan.model_dump() if run.plan else None,
        "tasks": [public_task(t) for t in tasks],
        "events": [e.model_dump(mode="json") for e in events],
    }


@router.post("/runs", status_code=201)
async def create_run(body: RunCreate, svc: Svc, user: User) -> dict[str, Any]:
    run = await svc.create_run(body.blueprint_md, body.repo, body.base_branch, body.max_agents,
                               body.plan_only, user)
    return run_summary(run, [])


@router.get("/runs")
async def list_runs(svc: Svc, limit: int = 20) -> list[dict[str, Any]]:
    runs = await svc.store.list_runs(min(max(limit, 1), 100))
    return [run_summary(r, await svc.store.list_tasks(r.id)) for r in runs]


@router.get("/runs/{run_id}")
async def get_run(run_id: str, svc: Svc) -> dict[str, Any]:
    return await run_detail(svc, run_id)


@router.post("/runs/{run_id}/approve")
async def approve(run_id: str, svc: Svc, user: User, request: Request, response: Response) -> dict[str, Any]:
    run = await svc.approve_plan(run_id, user)
    _changed(request, response)
    return run_summary(run, await svc.store.list_tasks(run_id))


@router.post("/runs/{run_id}/cancel")
async def cancel(run_id: str, svc: Svc, user: User, request: Request, response: Response) -> dict[str, Any]:
    run = await svc.cancel_run(run_id, user)
    _changed(request, response)
    return run_summary(run, await svc.store.list_tasks(run_id))


@router.post("/runs/{run_id}/tasks/{task_id}/merge")
async def merge(run_id: str, task_id: str, svc: Svc, user: User, request: Request,
                response: Response) -> dict[str, Any]:
    task = await svc.merge_task(run_id, task_id, user)
    _changed(request, response)
    return public_task(task)


@router.get("/models")
async def models(svc: Svc) -> dict[str, Any]:
    vms = await svc.fleet.status()
    return {"mode": svc.settings.mode, "models": [vm.model_dump() | {"running": vm.running} for vm in vms]}


@router.post("/models/{name}/{action}")
async def model_action(name: str, action: str, svc: Svc, request: Request, response: Response) -> dict[str, str]:
    if action not in {"start", "stop"}:
        raise HTTPException(404, "unknown action")
    try:
        await (svc.fleet.start(name) if action == "start" else svc.fleet.stop(name))
    except UnknownModel as exc:
        raise HTTPException(404, str(exc)) from exc
    if request.headers.get("hx-request"):
        response.headers["HX-Trigger"] = "models-changed"
    return {"model": name, "requested": action}


@router.get("/runs/{run_id}/stream")
async def stream(run_id: str, svc: Svc, request: Request) -> StreamingResponse:
    await svc.get_run(run_id)

    async def events() -> AsyncIterator[str]:
        seen = -1
        deadline = time.monotonic() + 600  # EventSource reconnects by itself
        while time.monotonic() < deadline and not await request.is_disconnected():
            version = svc.version(run_id)
            if version != seen:
                seen = version
                run = await svc.get_run(run_id)
                payload = run_summary(run, await svc.store.list_tasks(run_id))
                yield f"event: update\ndata: {json.dumps(payload, default=str)}\n\n"
            else:
                yield ": keepalive\n\n"
            await svc.wait_for_change(run_id, seen, 15)

    return StreamingResponse(events(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


# ------------------------------------------------------------- worker contract
async def worker_task(request: Request, svc: Svc) -> Task:
    token = bearer(request.headers)
    if not token:
        raise HTTPException(401, "missing task token", headers={"WWW-Authenticate": "Bearer"})
    try:
        return await svc.authenticate_worker(token)
    except Unauthorized as exc:
        raise HTTPException(401, str(exc), headers={"WWW-Authenticate": "Bearer"}) from exc


WorkerTask = Annotated[Task, Depends(worker_task)]


@worker_router.get("/task")
async def get_worker_task(task: WorkerTask, svc: Svc) -> dict[str, Any]:
    return await svc.worker_task_spec(task)


@worker_router.post("/events", status_code=204)
async def post_worker_event(event: WorkerEvent, task: WorkerTask, svc: Svc) -> Response:
    try:
        await svc.worker_event(task, event)
    except Unauthorized as exc:
        raise HTTPException(401, str(exc)) from exc
    return Response(status_code=204)
