#!/usr/bin/env bash
# The V_* variables below are assigned by scripts/lib/versions.sh via eval, which
# static analysis cannot follow.
# shellcheck disable=SC2154
# -----------------------------------------------------------------------------
# DEVBOX IMAGE — Hermes Agent (Nous Research), the primary agent.
#
# Mirrors the official installer's managed path (scripts/install.sh at the same
# tag): clone the release tag, create a venv, `uv sync --locked` against the
# project's hash-pinned uv.lock. What we skip is everything that installer does
# for a personal machine — its own uv/Node copies, Playwright browsers,
# messaging gateways, shell rc edits. Extras are limited to what an engineering
# agent uses: MCP client support and a PTY for interactive commands.
#
# Code lives in the image (/opt/devbox/hermes-agent, read-only to the agent);
# state lives in $HERMES_HOME on a volume (see Containerfile).
# -----------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"

export UV_HTTP_TIMEOUT="${UV_HTTP_TIMEOUT:-180}"
HERMES_DIR=/opt/devbox/hermes-agent
BIN_DIR="${UV_TOOL_BIN_DIR:-/opt/devbox/uv-tools/bin}"

section "Hermes Agent ${V_ai_hermes}"
retry 3 git clone --quiet --depth 1 --branch "${V_ai_hermes}" \
  https://github.com/NousResearch/hermes-agent "$HERMES_DIR"

# A tag can be moved; the commit cannot. Refuse anything but the pinned commit.
actual="$(git -C "$HERMES_DIR" rev-parse HEAD)"
[ "$actual" = "${V_ai_hermes_commit}" ] ||
  die "hermes ${V_ai_hermes} resolved to ${actual}, expected ${V_ai_hermes_commit}"
rm -rf "$HERMES_DIR/.git"

cd "$HERMES_DIR"
retry 3 env UV_PROJECT_ENVIRONMENT="$HERMES_DIR/venv" \
  uv sync --quiet --locked --no-dev --extra mcp --extra pty
ln -sf "$HERMES_DIR/venv/bin/hermes" "$BIN_DIR/hermes"

uv cache clean >/dev/null 2>&1 || true
HERMES_HOME="$(mktemp -d)" hermes --version
ok "hermes installed"
