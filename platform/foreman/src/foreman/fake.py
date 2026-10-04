"""Deterministic stand-ins for the GPU models and GitHub (FOREMAN_FAKE_MODELS=1).

They let the whole UI and task flow be exercised on a laptop without GPUs,
model weights or a real repository. Never enabled in gcp mode.
"""

from __future__ import annotations

import json
import re
from typing import Any

from foreman.llm import Message
from foreman.models import Usage


def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:40] or "task"


class FakeModel:
    def __init__(self, name: str = "fake") -> None:
        self.name = name
        self.calls: list[list[Message]] = []

    async def chat(self, messages: list[Message], json_schema: dict[str, Any] | None) -> tuple[str, Usage]:
        self.calls.append(messages)
        prompt = "\n".join(m["content"] for m in messages)
        kind = json_schema["name"] if json_schema else ("Plan" if "Maximum tasks" in prompt else "ReviewResult")
        body = self._plan(prompt) if kind == "Plan" else self._review()
        return json.dumps(body), Usage(prompt_tokens=len(prompt) // 4, completion_tokens=120)

    @staticmethod
    def _plan(prompt: str) -> dict[str, Any]:
        limit_match = re.search(r"Maximum tasks: (\d+)", prompt)
        limit = int(limit_match.group(1)) if limit_match else 3
        blueprint = prompt.split("<blueprint>", 1)[-1].split("</blueprint>", 1)[0]
        headings = re.findall(r"^##\s+(.+)$", blueprint, re.MULTILINE) or ["Implement blueprint"]
        tasks: list[dict[str, Any]] = []
        for heading in headings[:limit]:
            task_id = _slug(heading)
            if any(t["id"] == task_id for t in tasks):
                task_id = f"{task_id[:36]}-{len(tasks)}"
            tasks.append({
                "id": task_id,
                "title": heading.strip()[:120],
                "description": f"Implement the '{heading.strip()}' section of the blueprint.",
                "acceptance": [f"'{heading.strip()}' behaves as the blueprint describes"],
                "tests": ["unit tests cover the new behaviour"],
                "files_hint": [],
                "depends_on": [tasks[0]["id"]] if tasks else [],
            })
        return {"summary": f"Fake plan with {len(tasks)} task(s).", "tasks": tasks}

    @staticmethod
    def _review() -> dict[str, Any]:
        return {
            "verdict": "approve",
            "summary": "Fake review: the change matches the task.",
            "findings": [{"severity": "nit", "file": None, "line": None, "message": "Fake reviewer finding."}],
        }


class FakeGitHub:
    """In-memory GitHub used with fake models when no token is configured."""

    def __init__(self) -> None:
        self.reviews: list[tuple[str, int, str]] = []
        self.merged: list[tuple[str, int]] = []
        self.checks = "success"

    async def get_pr_diff(self, repo: str, number: int, max_bytes: int) -> str:
        return f"diff --git a/fake.txt b/fake.txt\n+fake change for {repo}#{number}\n"[:max_bytes]

    async def post_review_comment(self, repo: str, number: int, body: str) -> None:
        self.reviews.append((repo, number, body))

    async def head_sha(self, repo: str, number: int) -> str:
        return "0" * 40

    async def checks_state(self, repo: str, sha: str) -> str:
        return self.checks

    async def merge_pr(self, repo: str, number: int, sha: str) -> None:
        self.merged.append((repo, number))

    async def aclose(self) -> None:
        return None
