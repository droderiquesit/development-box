"""Application wiring: settings -> store, models, executor, GitHub, fleet."""

from __future__ import annotations

import contextlib
import logging
from collections.abc import AsyncIterator
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from mcp.server.transport_security import TransportSecuritySettings

from foreman import api, web
from foreman.auth import SecurityMiddleware
from foreman.config import Settings
from foreman.executors.base import Executor
from foreman.fake import FakeGitHub, FakeModel
from foreman.fleet import ComputeFleet, Fleet, StubFleet
from foreman.github import GitHub, GitHubClient
from foreman.llm import ChatModel, OpenAICompatModel
from foreman.mcp_server import build_mcp
from foreman.scheduler import Scheduler
from foreman.service import Foreman, ForemanError
from foreman.store.base import Store

log = logging.getLogger(__name__)


def _model(settings: Settings, base_url: str, name: str) -> ChatModel:
    if settings.fake_models:
        return FakeModel(f"fake-{name}")
    key = settings.model_api_key.get_secret_value() if settings.model_api_key else None
    return OpenAICompatModel(base_url, name, key, settings.model_timeout_s)


def _store(settings: Settings) -> Store:
    if settings.mode == "gcp":
        from foreman.store.firestore import FirestoreStore

        assert settings.gcp_project
        return FirestoreStore(settings.gcp_project, settings.firestore_database)
    from foreman.store.sqlite import SqliteStore

    return SqliteStore(settings.db_path)


def _executor(settings: Settings) -> Executor:
    kind = settings.executor_kind
    if kind == "cloudrun":
        from foreman.executors.cloudrun import CloudRunJobExecutor

        if not settings.gcp_project:
            raise ValueError("the cloudrun executor needs FOREMAN_GCP_PROJECT")
        return CloudRunJobExecutor(settings.gcp_project, settings.region, settings.worker_job)
    if kind == "simulated":
        from foreman.executors.simulated import SimulatedExecutor

        return SimulatedExecutor()
    if settings.mode != "local":
        raise ValueError("the podman executor is for local mode only")
    if not settings.worker_image:
        raise ValueError("the podman executor needs FOREMAN_WORKER_IMAGE")
    from foreman.executors.podman import LocalPodmanExecutor

    secrets = {}
    if settings.model_api_key:
        secrets["MODEL_API_KEY"] = settings.model_api_key.get_secret_value()
    if settings.github_token:
        secrets["GITHUB_TOKEN"] = settings.github_token.get_secret_value()
    return LocalPodmanExecutor(settings.worker_image, settings.podman_network, secrets)


def _github(settings: Settings) -> GitHub:
    if settings.github_token:
        return GitHubClient(settings.github_token.get_secret_value(), settings.github_api_url)
    if settings.fake_models:
        return FakeGitHub()
    raise ValueError("FOREMAN_GITHUB_TOKEN is required unless FOREMAN_FAKE_MODELS=1")


def _fleet(settings: Settings) -> Fleet:
    if settings.mode == "gcp":
        assert settings.gcp_project
        return ComputeFleet(settings.gcp_project, settings.models_zone, settings.model_cost_per_hour)
    return StubFleet(settings.model_cost_per_hour)


def _transport_security(settings: Settings) -> TransportSecuritySettings:
    from urllib.parse import urlsplit

    if settings.mode == "local":
        return TransportSecuritySettings(
            allowed_hosts=["127.0.0.1:*", "localhost:*", "[::1]:*"],
            allowed_origins=["http://127.0.0.1:*", "http://localhost:*", "http://[::1]:*"],
        )
    host = urlsplit(settings.url).netloc
    return TransportSecuritySettings(allowed_hosts=[host], allowed_origins=[f"https://{host}"])


def create_app(settings: Settings | None = None, *, store: Store | None = None, executor: Executor | None = None,
               planner: ChatModel | None = None, reviewer: ChatModel | None = None, github: GitHub | None = None,
               fleet: Fleet | None = None, iap_request: Any | None = None, run_scheduler: bool = True) -> FastAPI:
    settings = settings or Settings()
    svc = Foreman(
        settings,
        store or _store(settings),
        executor or _executor(settings),
        planner or _model(settings, settings.planner_base_url, settings.planner_model),
        reviewer or _model(settings, settings.reviewer_base_url, settings.reviewer_model),
        github or _github(settings),
        fleet or _fleet(settings),
    )
    mcp = build_mcp(svc)
    mcp_app = mcp.streamable_http_app(streamable_http_path="/mcp", stateless_http=True, json_response=True,
                                      transport_security=_transport_security(settings))
    scheduler = Scheduler(svc.tick, settings.scheduler_interval_s)

    @contextlib.asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        async with mcp.session_manager.run():
            if run_scheduler:
                scheduler.start()
            try:
                yield
            finally:
                await scheduler.stop()
                await svc.wait_idle()
                await svc.store.close()

    app = FastAPI(title="Foreman", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    app.state.foreman = svc

    @app.exception_handler(ForemanError)
    async def foreman_error(_: Request, exc: ForemanError) -> JSONResponse:
        return JSONResponse({"detail": str(exc)}, status_code=exc.status_code)

    app.include_router(api.worker_router)
    app.include_router(api.router)
    app.include_router(web.router)
    app.mount("/static", StaticFiles(directory=web.STATIC), name="static")
    # The MCP transport route itself (its Starlette app only adds the session-manager lifespan,
    # which runs in ours above).
    app.router.routes.extend(mcp_app.routes)
    app.add_middleware(SecurityMiddleware, settings=settings, iap_request=iap_request)
    return app
