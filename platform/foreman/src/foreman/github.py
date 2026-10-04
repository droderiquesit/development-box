"""The handful of GitHub REST calls Foreman needs."""

from __future__ import annotations

import re
from typing import Any, Protocol

import httpx

PR_URL = re.compile(r"^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/(\d+)/?$")
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_FAILED = {"failure", "timed_out", "cancelled", "action_required", "startup_failure"}


class GitHubError(RuntimeError):
    pass


def parse_pr_url(url: str, expected_repo: str) -> int:
    """Return the PR number, refusing URLs outside the run's repository."""
    match = PR_URL.match(url)
    if not match or match.group(1).lower() != expected_repo.lower():
        raise GitHubError(f"PR URL {url!r} is not a pull request in {expected_repo}")
    return int(match.group(2))


class GitHub(Protocol):
    async def get_pr_diff(self, repo: str, number: int, max_bytes: int) -> str: ...
    async def post_review_comment(self, repo: str, number: int, body: str) -> None: ...
    async def head_sha(self, repo: str, number: int) -> str: ...
    async def checks_state(self, repo: str, sha: str) -> str: ...
    async def merge_pr(self, repo: str, number: int, sha: str) -> None: ...
    async def aclose(self) -> None: ...


class GitHubClient:
    def __init__(self, token: str, api_url: str = "https://api.github.com",
                 transport: httpx.AsyncBaseTransport | None = None) -> None:
        self._client = httpx.AsyncClient(
            base_url=api_url,
            transport=transport,
            timeout=30.0,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "foreman",
            },
        )

    async def _json(self, method: str, path: str, **kwargs: Any) -> Any:
        resp = await self._client.request(method, path, **kwargs)
        if resp.status_code >= 400:
            message = resp.json().get("message", "") if resp.headers.get("content-type", "").startswith(
                "application/json") else resp.text[:200]
            raise GitHubError(f"GitHub {method} {path} -> {resp.status_code}: {message}")
        return resp.json() if resp.content else None

    async def get_pr_diff(self, repo: str, number: int, max_bytes: int) -> str:
        headers = {"Accept": "application/vnd.github.diff"}
        async with self._client.stream("GET", f"/repos/{repo}/pulls/{number}", headers=headers) as resp:
            if resp.status_code >= 400:
                raise GitHubError(f"GitHub diff {repo}#{number} -> {resp.status_code}")
            chunks: list[bytes] = []
            size = 0
            async for chunk in resp.aiter_bytes():
                chunks.append(chunk)
                size += len(chunk)
                if size > max_bytes:
                    break
        diff = b"".join(chunks)
        if len(diff) > max_bytes:
            return diff[:max_bytes].decode("utf-8", "replace") + f"\n[diff truncated at {max_bytes} bytes]\n"
        return diff.decode("utf-8", "replace")

    async def post_review_comment(self, repo: str, number: int, body: str) -> None:
        # COMMENT only: approving is a human decision.
        await self._json("POST", f"/repos/{repo}/pulls/{number}/reviews", json={"event": "COMMENT", "body": body})

    async def head_sha(self, repo: str, number: int) -> str:
        pr = await self._json("GET", f"/repos/{repo}/pulls/{number}")
        if pr.get("state") != "open":
            raise GitHubError(f"{repo}#{number} is not open")
        return pr["head"]["sha"]

    async def checks_state(self, repo: str, sha: str) -> str:
        """``success``, ``pending`` or ``failure`` across check runs and commit statuses."""
        runs = await self._json("GET", f"/repos/{repo}/commits/{sha}/check-runs", params={"per_page": 100})
        status = await self._json("GET", f"/repos/{repo}/commits/{sha}/status")
        check_runs = runs.get("check_runs", [])
        if any(r.get("conclusion") in _FAILED for r in check_runs) or status.get("state") in {"failure", "error"}:
            return "failure"
        # The combined status is "pending" when no statuses exist at all; only count real ones.
        if any(r.get("status") != "completed" for r in check_runs) or (
            status.get("total_count", 0) > 0 and status.get("state") == "pending"
        ):
            return "pending"
        return "success"

    async def merge_pr(self, repo: str, number: int, sha: str) -> None:
        await self._json("PUT", f"/repos/{repo}/pulls/{number}/merge", json={"merge_method": "squash", "sha": sha})

    async def aclose(self) -> None:
        await self._client.aclose()
