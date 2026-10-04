"""Second-model review of a task's pull request."""

from __future__ import annotations

from foreman.github import GitHub
from foreman.llm import ChatModel, complete_json
from foreman.models import ReviewResult, Task, Usage

SYSTEM_PROMPT = """\
You are a senior code reviewer. Review the pull request diff against the task and its
acceptance criteria. Report only real problems: bugs, missing acceptance criteria,
missing or wrong tests, security issues. Do not restate the diff. Verdict
"request_changes" only if a blocker or major finding exists; otherwise "approve".
Reply with JSON only."""


async def review_pr(model: ChatModel, github: GitHub, repo: str, number: int, task: Task,
                    max_diff_bytes: int) -> tuple[ReviewResult, Usage]:
    diff = await github.get_pr_diff(repo, number, max_diff_bytes)
    acceptance = "\n".join(f"- {a}" for a in task.acceptance)
    user = (
        f"Task {task.id}: {task.title}\n{task.description}\n\n"
        f"Acceptance criteria:\n{acceptance}\n\n<diff>\n{diff}\n</diff>"
    )
    messages = [{"role": "system", "content": SYSTEM_PROMPT}, {"role": "user", "content": user}]
    result, usage = await complete_json(model, messages, ReviewResult)
    await github.post_review_comment(repo, number, format_review(result, model.name))
    return result, usage


def format_review(result: ReviewResult, model_name: str) -> str:
    lines = [f"**Foreman automated review** ({model_name}): `{result.verdict}`", "", result.summary]
    if result.findings:
        lines.append("")
        for f in result.findings:
            where = f" `{f.file}{':' + str(f.line) if f.line else ''}`" if f.file else ""
            lines.append(f"- **{f.severity}**{where}: {f.message}")
    lines += ["", "_A human approves and merges; this comment is advisory._"]
    return "\n".join(lines)


def findings_feedback(result: ReviewResult) -> str:
    items = "\n".join(
        f"- [{f.severity}] {f.file or ''}{':' + str(f.line) if f.line else ''} {f.message}" for f in result.findings
    )
    return f"Reviewer requested changes: {result.summary}\n{items}"
