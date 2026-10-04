"""Start/stop/status of the GPU model VMs ``devbox-model-{architect,coder,fast}``."""

from __future__ import annotations

import asyncio
from typing import Any, Protocol

from pydantic import BaseModel

from foreman.config import MODEL_NAMES


class ModelVM(BaseModel):
    name: str
    instance: str
    status: str  # Compute Engine status (RUNNING, TERMINATED, ...) or STUB
    cost_per_hour: float

    @property
    def running(self) -> bool:
        return self.status in {"RUNNING", "PROVISIONING", "STAGING"}


class UnknownModel(ValueError):
    pass


def instance_name(name: str) -> str:
    if name not in MODEL_NAMES:
        raise UnknownModel(f"unknown model {name!r}; expected one of {', '.join(MODEL_NAMES)}")
    return f"devbox-model-{name}"


class Fleet(Protocol):
    async def status(self) -> list[ModelVM]: ...
    async def start(self, name: str) -> None: ...
    async def stop(self, name: str) -> None: ...


class StubFleet:
    """Local mode: no VMs exist; remembers the requested state so the UI can be exercised."""

    def __init__(self, costs: dict[str, float]) -> None:
        self.costs = costs
        self.states: dict[str, str] = dict.fromkeys(MODEL_NAMES, "TERMINATED")

    async def status(self) -> list[ModelVM]:
        return [ModelVM(name=n, instance=instance_name(n), status=f"STUB:{self.states[n]}",
                        cost_per_hour=self.costs.get(n, 0.0)) for n in MODEL_NAMES]

    async def start(self, name: str) -> None:
        instance_name(name)
        self.states[name] = "RUNNING"

    async def stop(self, name: str) -> None:
        instance_name(name)
        self.states[name] = "TERMINATED"


class ComputeFleet:
    """gcp mode: google-cloud-compute InstancesClient (sync REST client, run in a thread).
    start/stop return once the operation is accepted; the UI polls status."""

    def __init__(self, project: str, zone: str, costs: dict[str, float], client: Any = None) -> None:
        from google.cloud import compute_v1

        self.project = project
        self.zone = zone
        self.costs = costs
        self._client = client or compute_v1.InstancesClient()

    async def _status_one(self, name: str) -> ModelVM:
        try:
            instance = await asyncio.to_thread(
                self._client.get, project=self.project, zone=self.zone, instance=instance_name(name)
            )
            status = instance.status
        except Exception as exc:  # noqa: BLE001 - surfaced to the UI, e.g. NotFound / permission
            status = f"UNKNOWN ({type(exc).__name__})"
        return ModelVM(name=name, instance=instance_name(name), status=status, cost_per_hour=self.costs.get(name, 0.0))

    async def status(self) -> list[ModelVM]:
        return list(await asyncio.gather(*(self._status_one(n) for n in MODEL_NAMES)))

    async def start(self, name: str) -> None:
        await asyncio.to_thread(self._client.start, project=self.project, zone=self.zone,
                                instance=instance_name(name))

    async def stop(self, name: str) -> None:
        await asyncio.to_thread(self._client.stop, project=self.project, zone=self.zone,
                                instance=instance_name(name))
