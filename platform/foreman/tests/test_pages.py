from __future__ import annotations

import httpx

from foreman.service import Foreman

from .conftest import BLUEPRINT


async def test_dashboard_empty_and_models(client: httpx.AsyncClient) -> None:
    resp = await client.get("/")
    assert resp.status_code == 200
    html = resp.text
    assert "No runs yet." in html
    assert 'href="/manifest.webmanifest"' in html
    for name in ("architect", "coder", "fast"):
        assert f'data-model="{name}"' in html
    assert "$3.50/hour while running" in html
    assert 'hx-post="/api/models/architect/start"' in html


async def test_model_start_stop_buttons(client: httpx.AsyncClient) -> None:
    resp = await client.post("/api/models/coder/start", json={})
    assert resp.json() == {"model": "coder", "requested": "start"}
    status = (await client.get("/api/models")).json()
    coder = next(m for m in status["models"] if m["name"] == "coder")
    assert coder["running"] and coder["instance"] == "devbox-model-coder"
    html = (await client.get("/partials/models")).text
    assert 'hx-post="/api/models/coder/stop"' in html
    assert (await client.post("/api/models/gpu9/start", json={})).status_code == 404


async def test_new_run_form(client: httpx.AsyncClient) -> None:
    html = (await client.get("/runs/new")).text
    assert '<textarea name="blueprint_md"' in html
    assert 'type="file" name="blueprint_file"' in html
    assert 'type="range" name="max_agents" min="1" max="20" value="5"' in html
    assert 'name="plan_only" class="toggle" checked' in html


async def test_upload_and_validation_error(client: httpx.AsyncClient, svc: Foreman) -> None:
    await client.get("/runs/new")
    token = client.cookies["foreman_csrf"]
    bad = await client.post("/runs", data={"repo": "not a repo", "csrf_token": token, "max_agents": "5"})
    assert bad.status_code == 400 and "blueprint must be" in bad.text
    resp = await client.post(
        "/runs", data={"repo": "acme/todo", "csrf_token": token, "max_agents": "2"},
        files={"blueprint_file": ("bp.md", BLUEPRINT.encode(), "text/markdown")},
    )
    assert resp.status_code == 303
    await svc.wait_idle()
    run_id = resp.headers["location"].rsplit("/", 1)[1]
    run = await svc.get_run(run_id)
    assert run.plan_only is False  # checkbox not sent
    assert run.max_agents == 2 and "Todo service" in run.blueprint_md


async def test_run_page_renders_plan(client: httpx.AsyncClient, svc: Foreman) -> None:
    run = await svc.create_run(BLUEPRINT, "acme/todo", "main", 5, True, "local")
    await svc.wait_idle()
    html = (await client.get(f"/runs/{run.id}")).text
    assert "awaiting approval" in html
    assert f'hx-post="/api/runs/{run.id}/approve"' in html
    assert 'id="task-rest-api"' in html
    assert f'data-stream="/api/runs/{run.id}/stream"' in html
    assert "<progress" in html
    live = await client.get(f"/runs/{run.id}/live")
    assert live.status_code == 200 and "<html" not in live.text
    assert (await client.get("/runs/nope")).status_code == 404


async def test_settings_manifest_sw_static(client: httpx.AsyncClient) -> None:
    settings = await client.get("/settings")
    assert settings.status_code == 200 and "Dependency gate" in settings.text
    manifest = await client.get("/manifest.webmanifest")
    assert manifest.headers["content-type"].startswith("application/manifest+json")
    assert {i["sizes"] for i in manifest.json()["icons"]} >= {"192x192", "512x512"}
    assert (await client.get("/sw.js")).status_code == 200
    assert (await client.get("/static/vendor/htmx-2.0.11.min.js")).status_code == 200
    assert (await client.get("/static/icons/icon-512.png")).status_code == 200
    assert (await client.get("/healthz")).json() == {"status": "ok"}


async def test_sse_stream_sends_update(client: httpx.AsyncClient, svc: Foreman) -> None:
    run = await svc.create_run(BLUEPRINT, "acme/todo", "main", 5, True, "local")
    await svc.wait_idle()
    async with client.stream("GET", f"/api/runs/{run.id}/stream") as resp:
        assert resp.headers["content-type"].startswith("text/event-stream")
        lines = resp.aiter_lines()
        assert await anext(lines) == "event: update"
        assert '"status": "awaiting_approval"' in await anext(lines)
