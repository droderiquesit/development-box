"""Environment-driven settings. Every variable is prefixed ``FOREMAN_``."""

from __future__ import annotations

import hashlib
from functools import cached_property
from typing import Literal

from pydantic import SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

LOOPBACK_HOSTS = {"127.0.0.1", "::1"}
MODEL_NAMES = ("architect", "coder", "fast")


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="FOREMAN_", extra="ignore")

    mode: Literal["local", "gcp"] = "local"
    host: str = "127.0.0.1"
    port: int = 8080
    # URL workers use to reach Foreman (passed to them as FOREMAN_URL).
    url: str = "http://127.0.0.1:8080"

    # OpenAI-compatible model endpoints, one per role.
    planner_base_url: str = "http://127.0.0.1:8000/v1"
    planner_model: str = "architect"
    reviewer_base_url: str = "http://127.0.0.1:8000/v1"
    reviewer_model: str = "architect"
    worker_base_url: str = "http://127.0.0.1:8001/v1"
    worker_model: str = "coder"
    model_api_key: SecretStr | None = None
    model_timeout_s: float = 300.0
    fake_models: bool = False

    github_token: SecretStr | None = None
    github_api_url: str = "https://api.github.com"

    # Persistence: sqlite in local mode, firestore in gcp mode.
    db_path: str = "foreman.db"
    gcp_project: str | None = None
    firestore_database: str = "(default)"

    # Execution.
    executor: Literal["podman", "cloudrun", "simulated"] | None = None
    worker_image: str | None = None
    worker_job: str = "foreman-worker"
    region: str = "us-central1"
    podman_network: str = "host"
    worker_max_turns: int = 60
    worker_timeout_s: int = 3600

    # Scheduling.
    max_concurrency: int = 10
    dependency_gate: Literal["reviewed", "merged"] = "reviewed"
    heartbeat_timeout_s: int = 300
    scheduler_interval_s: float = 2.0
    review_max_diff_bytes: int = 60_000

    # GPU model VMs (devbox-model-{architect,coder,fast}).
    models_zone: str = "us-central1-a"
    model_cost_per_hour: dict[str, float] = {"architect": 0.0, "coder": 0.0, "fast": 0.0}

    # Auth.
    iap_audience: str | None = None
    service_token: SecretStr | None = None

    @model_validator(mode="after")
    def _check(self) -> Settings:
        if self.mode == "local" and self.host not in LOOPBACK_HOSTS:
            raise ValueError(
                "FOREMAN_MODE=local disables authentication and is only allowed when "
                "FOREMAN_HOST is 127.0.0.1 or ::1"
            )
        if self.mode == "gcp":
            missing = [
                name
                for name, value in (
                    ("FOREMAN_IAP_AUDIENCE", self.iap_audience),
                    ("FOREMAN_SERVICE_TOKEN", self.service_token),
                    ("FOREMAN_GCP_PROJECT", self.gcp_project),
                )
                if not value
            ]
            if missing:
                raise ValueError(f"FOREMAN_MODE=gcp requires {', '.join(missing)}")
            if self.fake_models:
                raise ValueError("FOREMAN_FAKE_MODELS is not allowed in gcp mode")
        return self

    @property
    def auth_enabled(self) -> bool:
        return self.mode == "gcp"

    @property
    def executor_kind(self) -> str:
        return self.executor or ("cloudrun" if self.mode == "gcp" else "podman")

    @cached_property
    def service_token_sha256(self) -> bytes | None:
        if self.service_token is None:
            return None
        return hashlib.sha256(self.service_token.get_secret_value().encode()).digest()
