"""Run each worker as an execution of one pre-created Cloud Run Job (gcp mode).

The Job definition owns the image, service account, resources and the secrets
(model key, GitHub token mounted from Secret Manager). Foreman only overrides
TASK_ID, TASK_TOKEN and FOREMAN_URL per execution.
"""

from __future__ import annotations

from google.cloud import run_v2

from foreman.executors.base import ExecState
from foreman.models import Task


class CloudRunJobExecutor:
    def __init__(self, project: str, region: str, job: str,
                 jobs: run_v2.JobsAsyncClient | None = None,
                 executions: run_v2.ExecutionsAsyncClient | None = None) -> None:
        self.job_name = f"projects/{project}/locations/{region}/jobs/{job}"
        self._jobs = jobs or run_v2.JobsAsyncClient()
        self._executions = executions or run_v2.ExecutionsAsyncClient()

    @staticmethod
    def request(job_name: str, env: dict[str, str]) -> run_v2.RunJobRequest:
        override = run_v2.RunJobRequest.Overrides.ContainerOverride(
            env=[run_v2.EnvVar(name=k, value=v) for k, v in sorted(env.items())]
        )
        return run_v2.RunJobRequest(
            name=job_name,
            overrides=run_v2.RunJobRequest.Overrides(container_overrides=[override], task_count=1),
        )

    async def launch(self, task: Task, env: dict[str, str]) -> str:
        operation = await self._jobs.run_job(request=self.request(self.job_name, env))
        # The long-running operation's metadata is the Execution being created.
        execution = operation.metadata
        if execution is None or not execution.name:
            raise RuntimeError("Cloud Run did not return an execution name")
        return execution.name

    async def status(self, handle: str) -> ExecState:
        execution = await self._executions.get_execution(name=handle)
        return ExecState.exited if execution.completion_time else ExecState.running

    async def cancel(self, handle: str) -> None:
        await self._executions.cancel_execution(name=handle)
