"""Minimal OpenAI-compatible chat client with structured-output support.

``complete_json`` first asks for ``response_format: {type: json_schema}``
(OpenAI structured outputs; vLLM implements it with guided decoding). If the
server rejects that, or the reply does not validate, it retries once in plain
text and extracts the JSON object from the reply.
"""

from __future__ import annotations

import json
import re
from collections.abc import Callable
from typing import Any, Protocol

import httpx
from pydantic import BaseModel, ValidationError

from foreman.models import Usage

Message = dict[str, str]


class ModelError(RuntimeError):
    pass


class ChatModel(Protocol):
    name: str

    async def chat(self, messages: list[Message], json_schema: dict[str, Any] | None) -> tuple[str, Usage]:
        """Return the assistant text and token usage. ``json_schema`` = {name, schema}."""
        ...


class OpenAICompatModel:
    def __init__(self, base_url: str, name: str, api_key: str | None, timeout_s: float = 300.0,
                 transport: httpx.AsyncBaseTransport | None = None) -> None:
        self.name = name
        headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        self._client = httpx.AsyncClient(base_url=base_url.rstrip("/"), headers=headers,
                                         timeout=timeout_s, transport=transport)

    async def chat(self, messages: list[Message], json_schema: dict[str, Any] | None) -> tuple[str, Usage]:
        body: dict[str, Any] = {"model": self.name, "messages": messages, "temperature": 0.2}
        if json_schema is not None:
            body["response_format"] = {"type": "json_schema", "json_schema": {**json_schema, "strict": True}}
        resp = await self._client.post("/chat/completions", json=body)
        if resp.status_code >= 400:
            raise ModelError(f"model {self.name} returned HTTP {resp.status_code}: {resp.text[:300]}")
        data = resp.json()
        try:
            content = data["choices"][0]["message"]["content"] or ""
        except (KeyError, IndexError, TypeError) as exc:
            raise ModelError(f"malformed completion from {self.name}") from exc
        usage = Usage.model_validate(data.get("usage") or {})
        return content, usage

    async def aclose(self) -> None:
        await self._client.aclose()


def strict_schema(model: type[BaseModel]) -> dict[str, Any]:
    """Pydantic JSON schema tightened for strict structured outputs:
    every object closes ``additionalProperties`` and requires all its properties."""
    schema = model.model_json_schema()

    def walk(node: Any) -> None:
        if isinstance(node, dict):
            if node.get("type") == "object" and "properties" in node:
                node["additionalProperties"] = False
                node["required"] = list(node["properties"])
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(schema)
    return schema


_FENCE = re.compile(r"```(?:json)?\s*(.*?)```", re.DOTALL)


def extract_json(text: str) -> Any:
    """Parse the first JSON object in ``text`` (bare, or inside a code fence)."""
    candidates = [m.group(1) for m in _FENCE.finditer(text)] + [text]
    decoder = json.JSONDecoder()
    for candidate in candidates:
        start = candidate.find("{")
        while start != -1:
            try:
                obj, _ = decoder.raw_decode(candidate, start)
                return obj
            except json.JSONDecodeError:
                start = candidate.find("{", start + 1)
    raise ValueError("no JSON object found in model reply")


async def complete_json[T: BaseModel](
    model: ChatModel,
    messages: list[Message],
    output: type[T],
    check: Callable[[T], list[str]] | None = None,
) -> tuple[T, Usage]:
    """Structured completion with one plain-text retry. ``check`` returns semantic errors."""
    usage = Usage()
    schema = {"name": output.__name__, "schema": strict_schema(output)}
    error: str
    try:
        text, used = await model.chat(messages, schema)
        usage.add(used)
        result, error = _parse(text, output, check)
        if result is not None:
            return result, usage
    except ModelError as exc:  # e.g. server without response_format support
        error = str(exc)
        text = ""

    retry = [
        *messages,
        *([{"role": "assistant", "content": text}] if text else []),
        {
            "role": "user",
            "content": (
                f"Your previous answer was not usable: {error[:1500]}\n"
                "Reply with ONLY one JSON object matching this JSON schema, no prose:\n"
                + json.dumps(schema["schema"])
            ),
        },
    ]
    text, used = await model.chat(retry, None)
    usage.add(used)
    result, error = _parse(text, output, check)
    if result is None:
        raise ModelError(f"{model.name} did not produce a valid {output.__name__}: {error[:500]}")
    return result, usage


def _parse[T: BaseModel](text: str, output: type[T], check: Callable[[T], list[str]] | None) -> tuple[T | None, str]:
    try:
        result = output.model_validate(extract_json(text))
    except (ValueError, ValidationError) as exc:
        return None, str(exc)
    problems = check(result) if check else []
    if problems:
        return None, "; ".join(problems)
    return result, ""
