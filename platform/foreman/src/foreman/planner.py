"""Turn a blueprint into a validated task DAG using the planner (architect) model."""

from __future__ import annotations

from foreman.llm import ChatModel, complete_json
from foreman.models import Plan, Usage

SYSTEM_PROMPT = """\
You are the architect of an autonomous software team. You turn a blueprint into a
plan of small, independent tasks. Each task is executed by a separate coding agent
in its own container, and each task must result in exactly ONE reviewable pull
request against the target repository.

Rules:
- Read only what is needed. Work from the blueprint alone; do not ask for or assume
  repository contents it does not state. In each task, name the files or areas the
  agent should look at (files_hint) so it reads only what it needs.
- Keep each task small enough for one focused PR (roughly under 400 changed lines).
- Every task has concrete acceptance criteria and the tests that must prove them.
- depends_on lists ids of tasks whose PRs must land first. The graph must be acyclic.
  Prefer parallelism: only add a dependency when the work really needs it.
- Task ids are short kebab-case (e.g. "api-models"), unique within the plan.
- Use as few tasks as the blueprint allows, never more than the stated maximum.
- Reply with JSON only."""


def validate_plan(plan: Plan, max_tasks: int) -> list[str]:
    """Semantic checks the JSON schema cannot express. Returns a list of problems."""
    problems: list[str] = []
    ids = [t.id for t in plan.tasks]
    if len(ids) > max_tasks:
        problems.append(f"plan has {len(ids)} tasks; the maximum is {max_tasks}")
    if len(set(ids)) != len(ids):
        problems.append("task ids are not unique")
    known = set(ids)
    for task in plan.tasks:
        for dep in task.depends_on:
            if dep == task.id:
                problems.append(f"task {task.id} depends on itself")
            elif dep not in known:
                problems.append(f"task {task.id} depends on unknown task {dep}")
    if not problems and _has_cycle({t.id: t.depends_on for t in plan.tasks}):
        problems.append("dependencies contain a cycle")
    return problems


def _has_cycle(graph: dict[str, list[str]]) -> bool:
    """Kahn's algorithm: a cycle exists iff some node never reaches in-degree 0."""
    indegree = {node: len(set(deps)) for node, deps in graph.items()}
    dependents: dict[str, list[str]] = {node: [] for node in graph}
    for node, deps in graph.items():
        for dep in set(deps):
            dependents[dep].append(node)
    queue = [node for node, degree in indegree.items() if degree == 0]
    seen = 0
    while queue:
        node = queue.pop()
        seen += 1
        for child in dependents[node]:
            indegree[child] -= 1
            if indegree[child] == 0:
                queue.append(child)
    return seen != len(graph)


async def plan_blueprint(model: ChatModel, blueprint_md: str, repo: str, base_branch: str,
                         max_tasks: int) -> tuple[Plan, Usage]:
    user = (
        f"Target repository: {repo} (base branch {base_branch}).\n"
        f"Maximum tasks: {max_tasks}\n\n"
        f"<blueprint>\n{blueprint_md}\n</blueprint>"
    )
    messages = [{"role": "system", "content": SYSTEM_PROMPT}, {"role": "user", "content": user}]
    return await complete_json(model, messages, Plan, check=lambda p: validate_plan(p, max_tasks))
