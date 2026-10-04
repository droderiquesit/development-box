from __future__ import annotations

import json
import re
import time
from collections.abc import Callable
from typing import Any

import httpx
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from google.auth import crypt, jwt
from pydantic import ValidationError

from foreman.auth import IAP_CERTS_URL, IAP_ISSUER
from foreman.config import Settings

AUDIENCE = "/projects/123/global/backendServices/456"


class FakeCertsRequest:
    """google-auth transport stand-in serving IAP's public-key document."""

    def __init__(self, keys: dict[str, str]) -> None:
        self.keys = keys
        self.urls: list[str] = []

    def __call__(self, url: str, method: str = "GET", **_: Any) -> Any:
        self.urls.append(url)
        return type("Resp", (), {"status": 200, "data": json.dumps(self.keys).encode(), "headers": {}})()


@pytest.fixture
def iap_key() -> tuple[crypt.Signer, str]:
    private = ec.generate_private_key(ec.SECP256R1())
    pem = private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                serialization.NoEncryption())
    public = private.public_key().public_bytes(serialization.Encoding.PEM,
                                               serialization.PublicFormat.SubjectPublicKeyInfo).decode()
    return crypt.ES256Signer.from_string(pem, key_id="k1"), public


def iap_jwt(signer: crypt.Signer, **overrides: Any) -> str:
    now = int(time.time())
    claims = {"iss": IAP_ISSUER, "aud": AUDIENCE, "iat": now, "exp": now + 600, "sub": "accounts.google.com:1",
              "email": "dev@example.com", **overrides}
    return jwt.encode(signer, claims).decode()


@pytest.fixture
def gcp_settings(tmp_path: Any) -> Settings:
    return Settings(mode="gcp", host="0.0.0.0", iap_audience=AUDIENCE, service_token="s3cret",  # noqa: S104
                    gcp_project="proj", db_path=str(tmp_path / "f.db"), executor="simulated",
                    url="https://foreman.example.com")


@pytest.fixture
def gcp_client(make_app: Callable[..., Any], gcp_settings: Settings, iap_key: tuple[crypt.Signer, str]) -> Any:
    request = FakeCertsRequest({"k1": iap_key[1]})
    app = make_app(gcp_settings, iap_request=request)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app, raise_app_exceptions=False),
                             base_url="https://foreman.example.com"), request


async def test_gcp_requires_valid_iap_jwt(gcp_client: Any, iap_key: tuple[crypt.Signer, str]) -> None:
    client, request = gcp_client
    signer = iap_key[0]
    async with client:
        assert (await client.get("/api/runs")).status_code == 401
        assert (await client.get("/api/runs", headers={"x-goog-iap-jwt-assertion": "garbage"})).status_code == 401
        bad_aud = iap_jwt(signer, aud="/projects/other")
        assert (await client.get("/api/runs", headers={"x-goog-iap-jwt-assertion": bad_aud})).status_code == 401
        bad_iss = iap_jwt(signer, iss="https://accounts.google.com")
        assert (await client.get("/api/runs", headers={"x-goog-iap-jwt-assertion": bad_iss})).status_code == 401
        expired = iap_jwt(signer, iat=int(time.time()) - 7200, exp=int(time.time()) - 3600)
        assert (await client.get("/api/runs", headers={"x-goog-iap-jwt-assertion": expired})).status_code == 401
        good = {"x-goog-iap-jwt-assertion": iap_jwt(signer)}
        assert (await client.get("/api/runs", headers=good)).status_code == 200
        resp = await client.post("/api/runs", headers=good,
                                 json={"blueprint_md": "# x\n## y", "repo": "acme/todo"})
        assert resp.json()["created_by"] == "dev@example.com"
        assert "strict-transport-security" in resp.headers
    assert request.urls and all(u == IAP_CERTS_URL for u in request.urls)


async def test_gcp_other_key_rejected(gcp_client: Any) -> None:
    client, _ = gcp_client
    other = ec.generate_private_key(ec.SECP256R1()).private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    forged = iap_jwt(crypt.ES256Signer.from_string(other, key_id="k1"))
    async with client:
        assert (await client.get("/", headers={"x-goog-iap-jwt-assertion": forged})).status_code == 401


async def test_gcp_mcp_and_worker_paths(gcp_client: Any) -> None:
    client, _ = gcp_client
    async with client:
        assert (await client.post("/mcp", json={})).status_code == 401
        assert (await client.post("/mcp", json={}, headers={"Authorization": "Bearer wrong"})).status_code == 401
        # Correct token passes auth (the transport itself then answers; not 401).
        resp = await client.post("/mcp", json={}, headers={"Authorization": "Bearer s3cret"})
        assert resp.status_code != 401
        # Worker routes skip IAP but need a task token.
        assert (await client.get("/api/worker/task")).status_code == 401
        assert (await client.get("/api/worker/task", headers={"Authorization": "Bearer a.b.c"})).status_code == 401
        assert (await client.get("/healthz")).status_code == 200


def test_local_mode_refuses_public_bind() -> None:
    with pytest.raises(ValidationError, match="only allowed when"):
        Settings(mode="local", host="0.0.0.0")  # noqa: S104


def test_gcp_mode_requires_auth_settings() -> None:
    with pytest.raises(ValidationError, match="FOREMAN_IAP_AUDIENCE"):
        Settings(mode="gcp", host="0.0.0.0", gcp_project="p", service_token="t")  # noqa: S104
    with pytest.raises(ValidationError, match="FAKE_MODELS"):
        Settings(mode="gcp", iap_audience="a", service_token="t", gcp_project="p", fake_models=True)


async def test_local_mode_refuses_non_loopback_socket(app: Any) -> None:
    sent: list[dict[str, Any]] = []
    scope = {"type": "http", "method": "GET", "path": "/healthz", "headers": [], "server": ("10.0.0.5", 8080),
             "client": ("10.0.0.9", 1234), "query_string": b"", "root_path": "", "scheme": "http",
             "http_version": "1.1"}

    async def receive() -> dict[str, Any]:
        return {"type": "http.request", "body": b""}

    async def send(message: dict[str, Any]) -> None:
        sent.append(message)

    await app(scope, receive, send)
    assert sent[0]["status"] == 401


async def test_csrf_on_forms_and_actions(client: httpx.AsyncClient) -> None:
    page = await client.get("/runs/new")
    token = re.search(r'name="csrf_token" value="([^"]+)"', page.text)
    assert token
    form = {"blueprint_md": "# Blueprint\n## Part", "repo": "acme/todo", "base_branch": "main",
            "max_agents": "3", "plan_only": "on"}
    assert (await client.post("/runs", data=form)).status_code == 403
    assert (await client.post("/runs", data={**form, "csrf_token": "wrong"})).status_code == 403
    resp = await client.post("/runs", data={**form, "csrf_token": token.group(1)})
    assert resp.status_code == 303 and resp.headers["location"].startswith("/runs/")
    # HTMX-style action: header token instead of form field.
    run_id = resp.headers["location"].rsplit("/", 1)[1]
    assert (await client.post(f"/api/runs/{run_id}/cancel")).status_code == 403
    ok = await client.post(f"/api/runs/{run_id}/cancel", headers={"X-CSRF-Token": token.group(1), "HX-Request": "1"})
    assert ok.status_code == 200 and ok.headers["HX-Trigger"] == "foreman-changed"
    cross = await client.post("/api/runs", json={"blueprint_md": "x", "repo": "a/b"},
                              headers={"Origin": "https://evil.example"})
    assert cross.status_code == 403


async def test_security_headers_and_nonce(client: httpx.AsyncClient) -> None:
    resp = await client.get("/")
    csp = resp.headers["content-security-policy"]
    nonce = re.search(r"'nonce-([^']+)'", csp)
    assert nonce and f'nonce="{nonce.group(1)}"' in resp.text
    assert "unsafe-inline" not in csp and "unsafe-eval" not in csp
    assert "frame-ancestors 'none'" in csp
    assert resp.headers["x-content-type-options"] == "nosniff"
    assert "HttpOnly" in resp.headers["set-cookie"] and "SameSite=Strict" in resp.headers["set-cookie"]
    # Every <script> is either external or carries the nonce.
    for tag in re.findall(r"<script[^>]*>", resp.text):
        assert "src=" in tag or f'nonce="{nonce.group(1)}"' in tag
    assert " style=" not in resp.text
