from __future__ import annotations

from datetime import timedelta

from foreman.models import RunStatus, Task, TaskStatus, utcnow
from foreman.scheduler import plan_tick, status_after_failure

NOW = utcnow()


def t(tid: str, status: TaskStatus = TaskStatus.pending, deps: list[str] | None = None, **kw: object) -> Task:
    return Task(id=tid, run_id="r", title=tid, description=tid, status=status, depends_on=deps or [], **kw)  # type: ignore[arg-type]


def tick(tasks: list[Task], *, max_parallel: int = 5, gate: str = "reviewed", exited: set[str] | None = None):
    return plan_tick(tasks, max_parallel=max_parallel, gate=gate, now=NOW,  # type: ignore[arg-type]
                     heartbeat_timeout_s=300, exited=exited or set())


def test_roots_become_ready_and_dispatch() -> None:
    plan = tick([t("a"), t("b", deps=["a"])])
    assert plan.make_ready == ["a"]
    assert plan.dispatch == ["a"]
    assert plan.run_status is None


def test_reviewed_gate_unblocks_on_review() -> None:
    tasks = [t("a", TaskStatus.reviewed), t("b", deps=["a"])]
    assert tick(tasks).make_ready == ["b"]
    assert tick(tasks, gate="merged").make_ready == []
    tasks[0].status = TaskStatus.merged
    assert tick(tasks, gate="merged").make_ready == ["b"]


def test_pr_open_does_not_satisfy_dependency() -> None:
    assert tick([t("a", TaskStatus.pr_open), t("b", deps=["a"])]).make_ready == []


def test_concurrency_cap_counts_running() -> None:
    tasks = [t("a", TaskStatus.running, last_heartbeat=NOW), t("b"), t("c"), t("d")]
    plan = tick(tasks, max_parallel=2)
    assert plan.make_ready == ["b", "c", "d"]
    assert plan.dispatch == ["b"]
    assert tick(tasks, max_parallel=1).dispatch == []


def test_stuck_by_heartbeat_and_exit() -> None:
    old = NOW - timedelta(seconds=301)
    tasks = [t("a", TaskStatus.running, last_heartbeat=old), t("b", TaskStatus.running, last_heartbeat=NOW),
             t("c", TaskStatus.running, last_heartbeat=NOW)]
    plan = tick(tasks, exited={"c"})
    assert set(plan.stuck) == {"a", "c"}
    assert "heartbeat" in plan.stuck["a"] and "exited" in plan.stuck["c"]


def test_stuck_tasks_free_capacity() -> None:
    old = NOW - timedelta(seconds=999)
    plan = tick([t("a", TaskStatus.running, last_heartbeat=old), t("b")], max_parallel=1)
    assert plan.dispatch == ["b"]


def test_failed_dependency_blocks_dependents() -> None:
    plan = tick([t("a", TaskStatus.failed), t("b", deps=["a"]), t("c")])
    assert plan.blocked == ["b"]
    assert plan.make_ready == ["c"]


def test_run_completion() -> None:
    assert tick([t("a", TaskStatus.reviewed), t("b", TaskStatus.merged)]).run_status == RunStatus.completed
    assert tick([t("a", TaskStatus.reviewed), t("b", TaskStatus.failed)]).run_status == RunStatus.failed
    assert tick([t("a", TaskStatus.reviewed), t("b", TaskStatus.pr_open)]).run_status is None


def test_retry_once() -> None:
    task = t("a", attempts=1)
    assert status_after_failure(task) == TaskStatus.pending
    task.attempts = 2
    assert status_after_failure(task) == TaskStatus.failed
