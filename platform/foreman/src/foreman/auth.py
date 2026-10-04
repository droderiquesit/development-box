"""Authentication, CSRF and security headers.

* gcp mode: every browser/API request carries an IAP JWT
  (``X-Goog-IAP-JWT-Assertion``) verified against IAP's public keys and
  ``FOREMAN_IAP_AUDIENCE``; ``/mcp`` takes ``Bearer <FOREMAN_SERVICE_TOKEN>``;
  ``/api/worker/*`` takes per-task tokens (checked in the route).
* local mode: no authentication, which ``Settings`` only allows on a loopback
  bind; requests arriving on a non-loopback socket are refused here as well.
"""

from __future__ import annotations

import hashlib
import hmac
import ipaddress
import logging
import secrets
import threading
import time
from collections.abc import Mapping
from http.cookies import SimpleCookie
from typing import Any
from urllib.parse import urlsplit

import anyio.to_thread
import google.auth.transport.requests
from fastapi import HTTPException, Request
from google.oauth2 import id_token
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from foreman.config import Settings

log = logging.getLogger(__name__)

IAP_CERTS_URL = "https://www.gstatic.com/iap/verify/public_key"
IAP_ISSUER = "https://cloud.google.com/iap"
IAP_HEADER = "x-goog-iap-jwt-assertion"
SAFE_METHODS = {"GET", "HEAD", "OPTIONS"}


class CachedRequest(google.auth.transport.requests.Request):
    """google-auth transport that caches GET responses (IAP keys) for ``ttl_s``."""

    def __init__(self, ttl_s: float = 3600.0) -> None:
        super().__init__()
        self._ttl_s = ttl_s
        self._cache: dict[str, tuple[float, Any]] = {}
        self._lock = threading.Lock()

    def __call__(self, url: str, method: str = "GET", body: Any = None, headers: Any = None,
                 timeout: Any = None, **kwargs: Any) -> Any:
        if method != "GET":
            return super().__call__(url, method, body, headers, timeout, **kwargs)
        with self._lock:
            hit = self._cache.get(url)
            if hit and time.monotonic() - hit[0] < self._ttl_s:
                return hit[1]
        response = super().__call__(url, method, body, headers, timeout, **kwargs)
        if response.status == 200:
            with self._lock:
                self._cache[url] = (time.monotonic(), response)
        return response


def verify_iap_jwt(assertion: str, audience: str, request: Any) -> str:
    """Return the caller's email from a valid IAP assertion; raise ValueError otherwise."""
    claims: Mapping[str, Any] = id_token.verify_token(assertion, request, audience=audience,
                                                      certs_url=IAP_CERTS_URL)
    if claims.get("iss") != IAP_ISSUER:
        raise ValueError("wrong issuer")
    email = claims.get("email")
    if not email:
        raise ValueError("no email claim")
    return str(email)


def bearer(headers: Mapping[str, str]) -> str | None:
    value = headers.get("authorization", "")
    scheme, _, token = value.partition(" ")
    return token.strip() if scheme.lower() == "bearer" and token.strip() else None


def token_matches(token: str | None, expected_sha256: bytes | None) -> bool:
    if not token or expected_sha256 is None:
        return False
    return hmac.compare_digest(hashlib.sha256(token.encode()).digest(), expected_sha256)


def _is_non_loopback_ip(host: str) -> bool:
    try:
        return not ipaddress.ip_address(host).is_loopback
    except ValueError:  # not an IP (e.g. a test client name)
        return False


class SecurityMiddleware:
    """Authentication + per-request CSP nonce + CSRF cookie + security headers."""

    def __init__(self, app: ASGIApp, settings: Settings, iap_request: Any | None = None) -> None:
        self.app = app
        self.settings = settings
        self.iap_request = iap_request or CachedRequest()
        self.csrf_cookie = "__Host-foreman_csrf" if settings.mode == "gcp" else "foreman_csrf"

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        headers = {k.decode("latin-1"): v.decode("latin-1") for k, v in scope["headers"]}
        path: str = scope["path"]
        state: dict[str, Any] = scope.setdefault("state", {})

        user = await self._authenticate(scope, path, headers)
        if user is None:
            await _plain(send, 401, "unauthorized")
            return
        state["user"] = user
        nonce = secrets.token_urlsafe(16)
        state["csp_nonce"] = nonce
        cookies = SimpleCookie(headers.get("cookie", ""))
        existing = cookies[self.csrf_cookie].value if self.csrf_cookie in cookies else None
        state["csrf_cookie"] = existing
        state["csrf_token"] = existing or secrets.token_urlsafe(32)

        async def send_wrapper(message: Message) -> None:
            if message["type"] == "http.response.start":
                out = list(message.get("headers", []))
                out += [(k.encode(), v.encode()) for k, v in self._headers(nonce).items()]
                if existing is None and not path.startswith(("/api/worker/", "/mcp", "/static/")):
                    secure = "; Secure" if self.settings.mode == "gcp" else ""
                    cookie = f"{self.csrf_cookie}={state['csrf_token']}; Path=/; HttpOnly; SameSite=Strict{secure}"
                    out.append((b"set-cookie", cookie.encode()))
                message["headers"] = out
            await send(message)

        await self.app(scope, receive, send_wrapper)

    async def _authenticate(self, scope: Scope, path: str, headers: dict[str, str]) -> str | None:
        if not self.settings.auth_enabled:
            server = scope.get("server")
            if server and _is_non_loopback_ip(server[0]):
                log.error("local mode request on non-loopback socket %s refused", server[0])
                return None
            return "local"
        if path == "/healthz" or path.startswith("/api/worker/"):
            return "anonymous"  # worker routes check their task token themselves
        if path == "/mcp" or path.startswith("/mcp/"):
            return "hermes" if token_matches(bearer(headers), self.settings.service_token_sha256) else None
        assertion = headers.get(IAP_HEADER)
        if not assertion or not self.settings.iap_audience:
            return None
        try:
            return await anyio.to_thread.run_sync(
                verify_iap_jwt, assertion, self.settings.iap_audience, self.iap_request
            )
        except Exception as exc:  # noqa: BLE001 - any verification failure is a 401
            log.warning("IAP assertion rejected: %s", exc)
            return None

    def _headers(self, nonce: str) -> dict[str, str]:
        csp = (
            "default-src 'self'; "
            f"script-src 'self' 'nonce-{nonce}'; "
            "style-src 'self'; img-src 'self' data:; connect-src 'self'; font-src 'self'; "
            "manifest-src 'self'; worker-src 'self'; object-src 'none'; base-uri 'none'; "
            "form-action 'self'; frame-ancestors 'none'"
        )
        headers = {
            "content-security-policy": csp,
            "x-content-type-options": "nosniff",
            "x-frame-options": "DENY",
            "referrer-policy": "same-origin",
            "permissions-policy": "camera=(), microphone=(), geolocation=(), payment=()",
            "cross-origin-opener-policy": "same-origin",
        }
        if self.settings.mode == "gcp":
            headers["strict-transport-security"] = "max-age=31536000; includeSubDomains"
        return headers


async def _plain(send: Send, status: int, text: str) -> None:
    await send({"type": "http.response.start", "status": status,
                "headers": [(b"content-type", b"text/plain; charset=utf-8")]})
    await send({"type": "http.response.body", "body": text.encode()})


async def require_csrf(request: Request) -> None:
    """Unsafe browser requests must echo the CSRF cookie (header or form field).
    JSON bodies are exempt: browsers cannot send them cross-site without CORS,
    which Foreman never enables."""
    if request.method in SAFE_METHODS:
        return
    origin = request.headers.get("origin")
    if origin is not None and urlsplit(origin).netloc != request.headers.get("host"):
        raise HTTPException(403, "cross-origin request refused")
    if request.headers.get("content-type", "").split(";")[0].strip() == "application/json":
        return
    expected = request.state.csrf_cookie
    supplied = request.headers.get("x-csrf-token")
    if supplied is None and request.headers.get("content-type", "").startswith(
            ("application/x-www-form-urlencoded", "multipart/form-data")):
        value = (await request.form()).get("csrf_token")
        supplied = value if isinstance(value, str) else None
    if not expected or not supplied or not hmac.compare_digest(expected, supplied):
        raise HTTPException(403, "missing or invalid CSRF token")


def current_user(request: Request) -> str:
    return request.state.user
