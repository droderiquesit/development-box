"""End-to-end flow through the HTTP API with fake models and a recording executor."""

from __future__ import annotations

from collections.abc import Callable
from datetime import timedelta
from typing import Any

import httpx

from foreman.executors.simulated import SimulatedExecutor
from foreman.fake import FakeGitHub
from foreman.service import Foreman

from .conftest import BLUEPRINT, RecordingExecutor, ScriptedModel, plan_json

REVIEW_CHANGES = (
    '{"verdict": "request_changes", "summary": "missing tests", '
    '"findings": [{"severity": "major", "file": "a.py", "line": 3, "message": "no test"}]}'
)
REVIEW_OK = '{"verdict": "approve", "summary": "fine", "findings": []}'


async def submit(client: httpx.AsyncClient, svc: Foreman, plan_only: bool = True, max_agents: int = 5) -> str:
    resp = await client.post("/api/runs", json={"blueprint_md": BLUEPRINT, "repo": "acme/todo",
                                                "max_agents": max_agents, "plan_only": plan_only})
    assert resp.status_code == 201, resp.text
    await svc.wait_idle()
    return resp.json()["id"]


def worker(client: httpx.AsyncClient, env: dict[str, str]) -> Callable[..., Any]:
    async def post(**event: Any) -> httpx.Response:
        return await client.post("/api/worker/events", json=event,
                                 headers={"Authorization": f"Bearer {env['TASK_TOKEN']}"})
    return post


async def test_plan_only_waits_for_approval(client: httpx.AsyncClient, svc: Foreman,
                                            executor: RecordingExecutor) -> None:
    run_id = await submit(client, svc)
    run = (await client.get(f"/api/runs/{run_id}")).json()
    assert run["status"] == "awaiting_approval"
    assert [t["id"] for t in run["tasks"]] == ["data-model", "rest-api", "web-ui"]
    assert run["plan"]["summary"]
    assert "token_hash" not in run["tasks"][0]
    await svc.tick()
    assert executor.launched == []

    assert (await client.post(f"/api/runs/{run_id}/approve", json={})).json()["status"] == "running"
    await svc.tick()
    assert [task.id for task, _ in executor.launched] == ["data-model"]  # others depend on it
    _, env = executor.launched[0]
    assert set(env) == {"TASK_ID", "TASK_TOKEN", "FOREMAN_URL"}
    assert env["FOREMAN_URL"] == "http://testserver"


async def test_full_flow_review_requeue_and_merge(make_app: Callable[..., Any], executor: RecordingExecutor,
                                                  github: FakeGitHub) -> None:
    reviewer = ScriptedModel(REVIEW_CHANGES, REVIEW_OK, name="reviewer")
    planner = ScriptedModel(plan_json(("a", []), ("b", ["a"])), name="planner")
    app = make_app(planner=planner, reviewer=reviewer)
    svc: Foreman = app.state.foreman
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://testserver") as client:
        run_id = await submit(client, svc, plan_only=False)
        await svc.tick()
        task, env = executor.launched[-1]
        assert task.id == "a"
        post = worker(client, env)
        spec = (await client.get("/api/worker/task", headers={"Authorization": f"Bearer {env['TASK_TOKEN']}"})).json()
        assert spec["branch"] == f"foreman/{run_id[:8]}/a"
        assert (await post(type="started", message="hi")).status_code == 204
        resp = await post(type="finished", pr_url="https://github.com/acme/todo/pull/7", branch=spec["branch"],
                          usage={"prompt_tokens": 100, "completion_tokens": 50})
        assert resp.status_code == 204
        await svc.wait_idle()
        # Reviewer asked for changes on attempt 1 -> re-queued with findings, token revoked.
        a = await svc.get_task(run_id, "a")
        assert a.status == "pending" and "no test" in a.feedback
        assert (await post(type="heartbeat")).status_code == 401
        assert github.reviews and "request_changes" in github.reviews[0][2]

        await svc.tick()  # ready and dispatched again
        task, env = executor.launched[-1]
        assert task.id == "a" and task.attempts == 2
        spec = (await client.get("/api/worker/task", headers={"Authorization": f"Bearer {env['TASK_TOKEN']}"})).json()
        assert "no test" in spec["prompt"] and "pull/7" in spec["prompt"]
        await worker(client, env)(type="finished", pr_url="https://github.com/acme/todo/pull/7")
        await svc.wait_idle()
        assert (await svc.get_task(run_id, "a")).status == "reviewed"

        await svc.tick()
        assert executor.launched[-1][0].id == "b"  # gate=reviewed unblocks b

        github.checks = "failure"
        resp = await client.post(f"/api/runs/{run_id}/tasks/a/merge", json={})
        assert resp.status_code == 409 and "checks are failure" in resp.json()["detail"]
        github.checks = "success"
        resp = await client.post(f"/api/runs/{run_id}/tasks/a/merge", json={})
        assert resp.status_code == 200 and resp.json()["status"] == "merged"
        assert github.merged == [("acme/todo", 7)]
        run = (await client.get(f"/api/runs/{run_id}")).json()
        assert run["usage"]["workers"]["prompt_tokens"] == 100
        assert run["usage"]["reviewer"]["prompt_tokens"] == 20


async def test_failed_attempt_retried_once_with_log(client: httpx.AsyncClient, svc: Foreman,
                                                    executor: RecordingExecutor) -> None:
    run_id = await submit(client, svc, plan_only=False)
    await svc.tick()
    _, env = executor.launched[-1]
    await worker(client, env)(type="log", message="pytest: 3 failed")
    await worker(client, env)(type="failed", message="tests failed")
    task = await svc.get_task(run_id, "data-model")
    assert task.status == "pending" and "pytest: 3 failed" in task.feedback
    await svc.tick()
    _, env = executor.launched[-1]
    assert executor.launched[-1][0].attempts == 2
    await worker(client, env)(type="failed", message="again")
    assert (await svc.get_task(run_id, "data-model")).status == "failed"
    await svc.tick()  # dependents are blocked, run fails
    run = await svc.get_run(run_id)
    tasks = {t.id: t.status for t in await svc.store.list_tasks(run_id)}
    assert tasks == {"data-model": "failed", "rest-api": "cancelled", "web-ui": "cancelled"}
    await svc.tick()
    assert (await svc.get_run(run_id)).status == "failed", run


async def test_pr_url_outside_repo_is_rejected(client: httpx.AsyncClient, svc: Foreman,
                                               executor: RecordingExecutor) -> None:
    run_id = await submit(client, svc, plan_only=False)
    await svc.tick()
    _, env = executor.launched[-1]
    await worker(client, env)(type="finished", pr_url="https://github.com/evil/repo/pull/1")
    task = await svc.get_task(run_id, "data-model")
    assert task.status == "pending" and "not a pull request in acme/todo" in (task.error or "")


async def test_heartbeat_timeout_and_launch_failure(client: httpx.AsyncClient, svc: Foreman,
                                                    executor: RecordingExecutor) -> None:
    run_id = await submit(client, svc, plan_only=False)
    executor.fail_launch = True
    await svc.tick()
    task = await svc.get_task(run_id, "data-model")
    assert task.status == "pending" and "launch failed" in (task.error or "")
    executor.fail_launch = False
    await svc.tick()
    task = await svc.get_task(run_id, "data-model")
    assert task.status == "running"
    task.last_heartbeat = task.last_heartbeat - timedelta(hours=1) if task.last_heartbeat else None
    await svc.store.put_task(task)
    await svc.tick()
    task = await svc.get_task(run_id, "data-model")
    assert task.status == "failed" and "heartbeat" in (task.error or "")


async def test_cancel_stops_workers(client: httpx.AsyncClient, svc: Foreman, executor: RecordingExecutor) -> None:
    run_id = await submit(client, svc, plan_only=False)
    await svc.tick()
    _, env = executor.launched[-1]
    resp = await client.post(f"/api/runs/{run_id}/cancel", json={})
    assert resp.json()["status"] == "cancelled"
    assert executor.cancelled == ["h-data-model-1"]
    assert (await worker(client, env)(type="heartbeat")).status_code == 401
    assert (await client.post(f"/api/runs/{run_id}/cancel", json={})).status_code == 409


async def test_simulated_worker_end_to_end(make_app: Callable[..., Any]) -> None:
    holder: dict[str, Any] = {}
    sim = SimulatedExecutor(step_s=0, transport=httpx.ASGITransport(app=lambda s, r, se: holder["app"](s, r, se)))
    app = make_app(executor=sim)
    holder["app"] = app
    svc: Foreman = app.state.foreman
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://testserver") as client:
        run_id = await submit(client, svc, plan_only=False, max_agents=1)
        await svc.tick()
        for job in list(sim._jobs.values()):
            await job
        await svc.wait_idle()
        task = await svc.get_task(run_id, "data-model")
        assert task.status == "reviewed", task
        assert task.pr_url and task.pr_url.startswith("https://github.com/acme/todo/pull/")
        assert any("writing code" in line for line in task.log_tail)
