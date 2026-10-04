from __future__ import annotations

import json

import httpx
import pytest

from foreman.fake import FakeModel
from foreman.llm import ModelError, OpenAICompatModel, extract_json, strict_schema
from foreman.models import Plan
from foreman.planner import SYSTEM_PROMPT, plan_blueprint, validate_plan

from .conftest import BLUEPRINT, ScriptedModel, plan_json


def make_plan(*tasks: tuple[str, list[str]]) -> Plan:
    return Plan.model_validate_json(plan_json(*tasks))


def test_validate_plan_accepts_dag() -> None:
    assert validate_plan(make_plan(("a", []), ("b", ["a"]), ("c", ["a", "b"])), 5) == []


@pytest.mark.parametrize(
    ("tasks", "limit", "expected"),
    [
        ((("a", ["b"]), ("b", ["a"])), 5, "cycle"),
        ((("a", ["a"]),), 5, "depends on itself"),
        ((("a", ["zzz"]),), 5, "unknown task zzz"),
        ((("a", []), ("a", [])), 5, "not unique"),
        ((("a", []), ("b", []), ("c", [])), 2, "maximum is 2"),
        ((("a", ["c"]), ("b", ["a"]), ("c", ["b"]), ("d", [])), 5, "cycle"),
    ],
)
def test_validate_plan_rejects(tasks: tuple[tuple[str, list[str]], ...], limit: int, expected: str) -> None:
    problems = validate_plan(make_plan(*tasks), limit)
    assert any(expected in p for p in problems), problems


async def test_plan_uses_structured_output_and_prompt_rules() -> None:
    model = ScriptedModel(plan_json(("api", []), ("ui", ["api"])))
    plan, usage = await plan_blueprint(model, BLUEPRINT, "acme/todo", "main", 5)
    assert [t.id for t in plan.tasks] == ["api", "ui"]
    assert usage.total == 15
    schema = model.schemas[0]
    assert schema is not None and schema["name"] == "Plan"
    assert schema["schema"]["additionalProperties"] is False
    assert "Read only what is needed" in model.messages[0][0]["content"]
    assert "Maximum tasks: 5" in model.messages[0][1]["content"]


async def test_plan_retries_once_with_errors_when_dag_invalid() -> None:
    model = ScriptedModel(plan_json(("a", ["b"]), ("b", ["a"])), "Sure!\n```json\n" + plan_json(("a", [])) + "\n```")
    plan, usage = await plan_blueprint(model, BLUEPRINT, "acme/todo", "main", 5)
    assert [t.id for t in plan.tasks] == ["a"]
    assert model.schemas[1] is None  # retry is plain text
    assert "cycle" in model.messages[1][-1]["content"]
    assert usage.total == 30


async def test_plan_falls_back_when_server_rejects_response_format() -> None:
    model = ScriptedModel(ModelError("HTTP 400 response_format unsupported"), "noise " + plan_json(("a", [])))
    plan, _ = await plan_blueprint(model, BLUEPRINT, "acme/todo", "main", 5)
    assert plan.tasks[0].id == "a"


async def test_plan_gives_up_after_one_retry() -> None:
    model = ScriptedModel("not json", "still not json")
    with pytest.raises(ModelError, match="valid Plan"):
        await plan_blueprint(model, BLUEPRINT, "acme/todo", "main", 5)


async def test_plan_respects_max_tasks_with_fake_model() -> None:
    plan, _ = await plan_blueprint(FakeModel(), BLUEPRINT, "acme/todo", "main", 2)
    assert len(plan.tasks) == 2
    assert validate_plan(plan, 2) == []


def test_extract_json_variants() -> None:
    assert extract_json('{"a": 1}') == {"a": 1}
    assert extract_json('text {broken then {"b": 2} tail') == {"b": 2}
    assert extract_json('```json\n{"c": [1]}\n```') == {"c": [1]}
    with pytest.raises(ValueError):
        extract_json("nothing here")


def test_strict_schema_closes_nested_objects() -> None:
    schema = strict_schema(Plan)
    task = schema["$defs"]["PlannedTask"]
    assert task["additionalProperties"] is False
    assert set(task["required"]) == set(task["properties"])


async def test_openai_compat_request_shape() -> None:
    seen: dict[str, object] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        seen["auth"] = request.headers.get("authorization")
        seen["body"] = json.loads(request.content)
        return httpx.Response(200, json={"choices": [{"message": {"content": "{}"}}],
                                         "usage": {"prompt_tokens": 3, "completion_tokens": 4, "total_tokens": 7}})

    model = OpenAICompatModel("http://vllm:8000/v1/", "architect", "k", transport=httpx.MockTransport(handler))
    text, usage = await model.chat([{"role": "user", "content": "hi"}], {"name": "Plan", "schema": {"type": "object"}})
    await model.aclose()
    assert text == "{}" and usage.total == 7
    assert seen["url"] == "http://vllm:8000/v1/chat/completions"
    assert seen["auth"] == "Bearer k"
    body = seen["body"]
    assert isinstance(body, dict)
    assert body["model"] == "architect"
    assert body["response_format"] == {
        "type": "json_schema", "json_schema": {"name": "Plan", "schema": {"type": "object"}, "strict": True}}


async def test_openai_compat_http_error_is_model_error() -> None:
    model = OpenAICompatModel("http://x/v1", "m", None,
                              transport=httpx.MockTransport(lambda r: httpx.Response(400, text="bad format")))
    with pytest.raises(ModelError, match="HTTP 400"):
        await model.chat([], None)
    await model.aclose()


def test_system_prompt_mentions_one_pr_per_task() -> None:
    assert "ONE" in SYSTEM_PROMPT and "acyclic" in SYSTEM_PROMPT
