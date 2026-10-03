#!/usr/bin/env bash
# The V_* variables below are assigned by scripts/lib/versions.sh via eval, which
# static analysis cannot follow.
# shellcheck disable=SC2154
# -----------------------------------------------------------------------------
# DEVBOX IMAGE — the AI engineering platform.
#
# Classification — the box runs on FREE cloud inference (Ollama Cloud), so
# every client here must be able to use it or be the free fallback:
#
#   Hermes        REQUIRED    the primary agent; installed by 72-hermes.sh.
#   Claude Code   REQUIRED    npm @anthropic-ai/claude-code. Runs free against
#                             Ollama's Anthropic-compatible API (`ai claude`);
#                             real permission model + MCP + LSP plugins.
#   Gemini CLI    RECOMMENDED npm @google/gemini-cli. Free-tier fallback when
#                             the Ollama monthly allowance is spent.
#   Codex, Aider, OpenCode
#                 OPTIONAL    FEATURE_AI_EXTRA=1. Overlap the above.
#
# Removed: LiteLLM and `llm`. `ai ask` speaks the OpenAI-compatible API to
# Ollama Cloud directly with curl, so a router hop and a plugin system bought
# nothing but another failure mode. No model runtime is installed: inference
# never happens on this machine.
# -----------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"

export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX:-/opt/devbox/npm-global}"
# uv defaults to a 30 s HTTP timeout, which is fine on a fast direct link and
# marginal behind a corporate TLS-inspecting proxy — exactly the environment
# this image is built for. A large wheel (checkov's transitive tree)
# then fails mid-download and burns all three retries on the same timeout.
# Raise it; the retry loop stays as the backstop for genuine failures.
export UV_HTTP_TIMEOUT="${UV_HTTP_TIMEOUT:-180}"
export UV_CONCURRENT_DOWNLOADS="${UV_CONCURRENT_DOWNLOADS:-4}"
export UV_TOOL_DIR="${UV_TOOL_DIR:-/opt/devbox/uv-tools}"
export UV_TOOL_BIN_DIR="${UV_TOOL_BIN_DIR:-/opt/devbox/uv-tools/bin}"

npm_global() {
  local pkg="$1" ver="$2"
  local spec="$pkg"
  [ "$ver" != "latest" ] && spec="${pkg}@${ver}" || spec="${pkg}@latest"
  log "npm install -g ${spec}"
  retry 3 npm install -g --no-fund --no-audit --loglevel=error "$spec"
}

section "Agentic AI CLIs"
npm_global "@anthropic-ai/claude-code" "${V_ai_claude_code}"

if [ "${FEATURE_AI_GEMINI:-1}" = "1" ]; then
  npm_global "@google/gemini-cli" "${V_ai_gemini_cli}"
fi

if [ "${FEATURE_AI_EXTRA:-0}" = "1" ]; then
  section "Additional AI clients (FEATURE_AI_EXTRA)"
  npm_global "@openai/codex" "${V_ai_codex}"
  npm_global "opencode-ai" "${V_ai_opencode}"
  retry 3 uv tool install --quiet "aider-chat==${V_ai_aider}"
fi

npm cache clean --force >/dev/null 2>&1 || true
uv cache clean >/dev/null 2>&1 || true

section "Installed AI clients"
claude --version 2>/dev/null || warn "claude not on PATH"
ok "AI platform installed"
