"""Server-rendered pages (Jinja2 + HTMX)."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from fastapi import APIRouter, Depends, Request
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse, Response
from fastapi.templating import Jinja2Templates
from starlette.datastructures import UploadFile

from foreman import __version__
from foreman.api import Svc, User, run_detail
from foreman.auth import require_csrf
from foreman.service import ForemanError, run_summary

HERE = Path(__file__).parent
STATIC = HERE / "static"
MAX_UPLOAD_BYTES = 100_000

STATUS_TONE = {
    "planning": "info", "awaiting_approval": "warn", "running": "info", "completed": "ok",
    "failed": "bad", "cancelled": "muted", "pending": "muted", "ready": "info", "pr_open": "info",
    "reviewed": "ok", "merged": "ok", "approve": "ok", "request_changes": "warn",
}


def _context(request: Request) -> dict[str, Any]:
    return {
        "csp_nonce": request.state.csp_nonce,
        "csrf_token": request.state.csrf_token,
        "user": request.state.user,
        "mode": request.app.state.foreman.settings.mode,
        "version": __version__,
    }


templates = Jinja2Templates(directory=HERE / "templates", context_processors=[_context])
templates.env.globals["tone"] = lambda status: STATUS_TONE.get(str(status), "muted")
templates.env.filters["label"] = lambda status: str(status).replace("_", " ")

router = APIRouter(dependencies=[Depends(require_csrf)])


def page(request: Request, name: str, status_code: int = 200, **context: Any) -> HTMLResponse:
    return templates.TemplateResponse(request, name, context, status_code=status_code)


@router.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/", response_class=HTMLResponse)
async def dashboard(request: Request, svc: Svc) -> HTMLResponse:
    runs = [run_summary(r, await svc.store.list_tasks(r.id)) for r in await svc.store.list_runs(30)]
    return page(request, "dashboard.html", runs=runs, models=await svc.fleet.status())


@router.get("/partials/models", response_class=HTMLResponse)
async def models_partial(request: Request, svc: Svc) -> HTMLResponse:
    return page(request, "partials/models.html", models=await svc.fleet.status())


@router.get("/runs/new", response_class=HTMLResponse)
async def new_run(request: Request) -> HTMLResponse:
    return page(request, "new.html", form={"base_branch": "main", "max_agents": 5, "plan_only": True})


@router.post("/runs", response_class=HTMLResponse)
async def create_run(request: Request, svc: Svc, user: User) -> Response:
    form = await request.form()

    def text(name: str, default: str = "") -> str:
        value = form.get(name)
        return value.strip() if isinstance(value, str) else default

    blueprint = text("blueprint_md")
    upload = form.get("blueprint_file")
    values: dict[str, Any] = {
        "repo": text("repo"), "base_branch": text("base_branch", "main") or "main",
        "plan_only": form.get("plan_only") == "on", "blueprint_md": blueprint,
    }
    try:
        if isinstance(upload, UploadFile) and upload.filename:
            data = await upload.read(MAX_UPLOAD_BYTES + 1)
            if len(data) > MAX_UPLOAD_BYTES:
                raise ForemanError("uploaded blueprint is too large")
            blueprint = blueprint or data.decode("utf-8", "replace")
        try:
            values["max_agents"] = int(text("max_agents", "5"))
        except ValueError as exc:
            raise ForemanError("max_agents must be a number") from exc
        run = await svc.create_run(blueprint, values["repo"], values["base_branch"], values["max_agents"],
                                   values["plan_only"], user)
    except ForemanError as exc:
        values.setdefault("max_agents", 5)
        return page(request, "new.html", status_code=400, form=values, error=str(exc))
    return RedirectResponse(f"/runs/{run.id}", status_code=303)


@router.get("/runs/{run_id}", response_class=HTMLResponse)
async def run_page(run_id: str, request: Request, svc: Svc) -> HTMLResponse:
    return page(request, "run.html", run=await run_detail(svc, run_id))


@router.get("/runs/{run_id}/live", response_class=HTMLResponse)
async def run_live(run_id: str, request: Request, svc: Svc) -> HTMLResponse:
    return page(request, "partials/run_live.html", run=await run_detail(svc, run_id))


@router.get("/settings", response_class=HTMLResponse)
async def settings_page(request: Request, svc: Svc) -> HTMLResponse:
    s = svc.settings
    rows = [
        ("Mode", s.mode), ("Executor", s.executor_kind), ("Planner", f"{s.planner_model} @ {s.planner_base_url}"),
        ("Reviewer", f"{s.reviewer_model} @ {s.reviewer_base_url}"),
        ("Worker model", f"{s.worker_model} @ {s.worker_base_url}"),
        ("Fake models", "yes" if s.fake_models else "no"),
        ("Dependency gate", s.dependency_gate), ("Max concurrency", str(s.max_concurrency)),
        ("Heartbeat timeout", f"{s.heartbeat_timeout_s}s"), ("Worker limits",
                                                             f"{s.worker_max_turns} turns / {s.worker_timeout_s}s"),
        ("Model API key", "configured" if s.model_api_key else "not set"),
        ("GitHub token", "configured" if s.github_token else "not set"),
        ("Models zone", s.models_zone),
    ]
    return page(request, "settings.html", rows=rows)


@router.get("/manifest.webmanifest")
async def manifest() -> FileResponse:
    return FileResponse(STATIC / "manifest.webmanifest", media_type="application/manifest+json")


@router.get("/sw.js")
async def service_worker() -> FileResponse:
    # Served from the root so its scope covers the whole app.
    return FileResponse(STATIC / "sw.js", media_type="text/javascript", headers={"Cache-Control": "no-cache"})
