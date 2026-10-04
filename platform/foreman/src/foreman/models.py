"""Domain entities shared by every module."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from enum import StrEnum
from typing import Literal

from pydantic import BaseModel, Field


def utcnow() -> datetime:
    return datetime.now(UTC)


def new_id() -> str:
    return uuid.uuid4().hex


class RunStatus(StrEnum):
    planning = "planning"
    awaiting_approval = "awaiting_approval"
    running = "running"
    completed = "completed"
    failed = "failed"
    cancelled = "cancelled"


class TaskStatus(StrEnum):
    pending = "pending"
    ready = "ready"
    running = "running"
    pr_open = "pr_open"
    reviewed = "reviewed"
    failed = "failed"
    cancelled = "cancelled"
    merged = "merged"


TERMINAL_TASK = {TaskStatus.failed, TaskStatus.cancelled, TaskStatus.merged}
ACTIVE_RUN = {RunStatus.planning, RunStatus.awaiting_approval, RunStatus.running}
MAX_ATTEMPTS = 2  # one initial attempt plus one retry


class Usage(BaseModel):
    prompt_tokens: int = 0
    completion_tokens: int = 0

    def add(self, other: Usage | None) -> None:
        if other is not None:
            self.prompt_tokens += max(0, other.prompt_tokens)
            self.completion_tokens += max(0, other.completion_tokens)

    @property
    def total(self) -> int:
        return self.prompt_tokens + self.completion_tokens


class RunUsage(BaseModel):
    planner: Usage = Field(default_factory=Usage)
    reviewer: Usage = Field(default_factory=Usage)
    workers: Usage = Field(default_factory=Usage)

    @property
    def total(self) -> int:
        return self.planner.total + self.reviewer.total + self.workers.total


TASK_ID_PATTERN = r"^[a-z0-9][a-z0-9-]{0,39}$"


class PlannedTask(BaseModel):
    id: str = Field(pattern=TASK_ID_PATTERN, description="short kebab-case id, unique in the plan")
    title: str = Field(min_length=1, max_length=120)
    description: str = Field(min_length=1, max_length=4000)
    acceptance: list[str] = Field(min_length=1, max_length=10)
    tests: list[str] = Field(default_factory=list, max_length=10)
    files_hint: list[str] = Field(default_factory=list, max_length=20)
    depends_on: list[str] = Field(default_factory=list)


class Plan(BaseModel):
    summary: str = Field(min_length=1, max_length=2000)
    tasks: list[PlannedTask] = Field(min_length=1)


class Finding(BaseModel):
    severity: Literal["blocker", "major", "minor", "nit"]
    file: str | None = None
    line: int | None = None
    message: str = Field(min_length=1, max_length=2000)


class ReviewResult(BaseModel):
    verdict: Literal["approve", "request_changes"]
    summary: str = Field(max_length=4000)
    findings: list[Finding] = Field(default_factory=list, max_length=30)


class Run(BaseModel):
    id: str = Field(default_factory=new_id)
    blueprint_md: str
    repo: str
    base_branch: str = "main"
    status: RunStatus = RunStatus.planning
    max_agents: int = 5
    plan_only: bool = True
    created_by: str = "unknown"
    created_at: datetime = Field(default_factory=utcnow)
    updated_at: datetime = Field(default_factory=utcnow)
    plan: Plan | None = None
    error: str | None = None
    usage: RunUsage = Field(default_factory=RunUsage)


class Task(BaseModel):
    id: str
    run_id: str
    position: int = 0
    title: str
    description: str
    acceptance: list[str] = Field(default_factory=list)
    tests: list[str] = Field(default_factory=list)
    files_hint: list[str] = Field(default_factory=list)
    depends_on: list[str] = Field(default_factory=list)
    status: TaskStatus = TaskStatus.pending
    branch: str | None = None
    pr_url: str | None = None
    attempts: int = 0
    log_tail: list[str] = Field(default_factory=list)
    usage: Usage = Field(default_factory=Usage)
    token_hash: str | None = None
    handle: str | None = None
    last_heartbeat: datetime | None = None
    feedback: str = ""
    review: ReviewResult | None = None
    review_attempts: int = 0
    error: str | None = None
    merged_by: str | None = None
    updated_at: datetime = Field(default_factory=utcnow)

    def log(self, line: str, keep: int = 50) -> None:
        self.log_tail.append(line[:2000])
        del self.log_tail[:-keep]


class Event(BaseModel):
    id: str = Field(default_factory=new_id)
    run_id: str
    task_id: str | None = None
    type: str
    message: str = ""
    created_at: datetime = Field(default_factory=utcnow)
