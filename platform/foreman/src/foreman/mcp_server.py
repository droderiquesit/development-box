"""MCP server for the Hermes coordinator (mcp 2.x ``MCPServer``, streamable HTTP).

Mounted at ``/mcp`` by ``app.py``; authentication (Bearer FOREMAN_SERVICE_TOKEN)
is enforced by ``SecurityMiddleware`` before requests reach the transport.
"""

from __future__ import annotations

from typing import Any

from mcp.server.mcpserver import MCPServer

from foreman.service import Foreman, run_summary

ACTOR = "hermes"


def build_mcp(svc: Foreman) -> MCPServer:
    server = MCPServer(
        name="foreman",
        instructions=(
            "Foreman plans blueprints into tasks, runs coding agents and reviews their PRs. "
            "Submit with plan_only=True and show the plan to the human before approve_plan. "
            "Never call merge_task_pr unless the human explicitly asked to merge that task in this "
            "conversation. GPU models cost money while running: stop them when idle."
        ),
    )

    @server.tool()
    async def submit_blueprint(blueprint_md: str, repo: str, base_branch: str = "main", max_agents: int = 5,
                               plan_only: bool = True) -> dict[str, Any]:
        """Submit a markdown blueprint for repo (owner/name). Planning runs in the background;
        poll run_status. With plan_only=True no worker starts until approve_plan."""
        run = await svc.create_run(blueprint_md, repo, base_branch, max_agents, plan_only, ACTOR)
        return run_summary(run, [])

    @server.tool()
    async def approve_plan(run_id: str) -> dict[str, Any]:
        """Approve a run's plan so its workers start (run must be awaiting_approval)."""
        run = await svc.approve_plan(run_id, ACTOR)
        return run_summary(run, await svc.store.list_tasks(run_id))

    @server.tool()
    async def run_status(run_id: str) -> dict[str, Any]:
        """Status, plan and per-task state (PR links, review verdicts) of one run."""
        run = await svc.get_run(run_id)
        tasks = await svc.store.list_tasks(run_id)
        return {
            **run_summary(run, tasks),
            "plan_summary": run.plan.summary if run.plan else None,
            "tasks": [
                {"id": t.id, "title": t.title, "status": t.status, "depends_on": t.depends_on,
                 "attempts": t.attempts, "pr_url": t.pr_url, "error": t.error,
                 "review": t.review.model_dump() if t.review else None}
                for t in tasks
            ],
        }

    @server.tool()
    async def list_runs(limit: int = 10) -> list[dict[str, Any]]:
        """Most recent runs, newest first."""
        runs = await svc.store.list_runs(min(max(limit, 1), 50))
        return [run_summary(r, await svc.store.list_tasks(r.id)) for r in runs]

    @server.tool()
    async def cancel_run(run_id: str) -> dict[str, Any]:
        """Cancel a run and stop its running workers. Open PRs are left as they are."""
        run = await svc.cancel_run(run_id, ACTOR)
        return run_summary(run, await svc.store.list_tasks(run_id))

    @server.tool()
    async def merge_task_pr(run_id: str, task_id: str, confirm: bool = False) -> dict[str, Any]:
        """Squash-merge a task's PR. Only on an explicit human request; requires confirm=True.
        Refused while the PR's checks are failing or still running."""
        if not confirm:
            raise ValueError("merging needs confirm=True, set only after the human explicitly asked to merge")
        task = await svc.merge_task(run_id, task_id, ACTOR)
        return {"task_id": task.id, "status": task.status, "pr_url": task.pr_url}

    @server.tool()
    async def models_status() -> list[dict[str, Any]]:
        """Status and hourly cost of the GPU model VMs (architect, coder, fast)."""
        return [vm.model_dump() | {"running": vm.running} for vm in await svc.fleet.status()]

    @server.tool()
    async def start_model(name: str) -> str:
        """Start a GPU model VM: architect, coder or fast. It costs money until stopped."""
        await svc.fleet.start(name)
        return f"start requested for {name}"

    @server.tool()
    async def stop_model(name: str) -> str:
        """Stop a GPU model VM: architect, coder or fast."""
        await svc.fleet.stop(name)
        return f"stop requested for {name}"

    return server
