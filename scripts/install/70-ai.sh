#!/usr/bin/env bash
# The V_* variables below are assigned by scripts/lib/versions.sh via eval, which
# static analysis cannot follow.
# shellcheck disable=SC2154
# -----------------------------------------------------------------------------
# DEVBOX IMAGE — the AI engineering platform.
#
# Classification (the reasoning matters more than the list — see docs/ai.md):
#
#   Claude Code   REQUIRED    npm @anthropic-ai/claude-code. First-class agentic
#                             coding CLI with native MCP support and a real
#                             permission model, which is what makes the
#                             governance layer in this repo enforceable.
#   Codex CLI     REQUIRED    npm @openai/codex. Second opinion from a different
#                             model family; the review workflows depend on the
#                             two disagreeing.
#   Gemini CLI    RECOMMENDED npm @google/gemini-cli. Very large context window,
#                             which is the right tool for whole-repo research.
#   LiteLLM       REQUIRED    the provider abstraction. One OpenAI-compatible
#                             endpoint in front of Anthropic / OpenAI / Gemini /
#                             Bedrock / Vertex / Azure OpenAI / Ollama, so
#                             `ai use <provider>` is a config change and not a
#                             new integration. Runs as a sidecar, not in-image.
#   llm           RECOMMENDED pypi `llm`. Scriptable one-shot prompting that
#                             pipes cleanly in shell — the agentic CLIs are the
#                             wrong shape for `cat plan.json | ai ask ...`.
#   Ollama client REQUIRED    for local models we install ONLY the client path
#                             (an OpenAI-compatible base URL). The inference
#                             server stays on the host or in its own container:
#                             a 6 GB model runtime has no business inside a dev
#                             container. See §36 of docs/ai.md.
#   Aider         OPTIONAL    FEATURE_AI_EXTRA=1. Excellent, but overlaps Claude
#                             Code/Codex for the same job.
#   OpenCode      OPTIONAL    FEATURE_AI_EXTRA=1. Same overlap.
#   Continue/Cline REJECTED   both are VS Code extensions, not CLIs. They are
#                             listed in .vscode/extensions.json where they
#                             belong; installing them into the image is a
#                             category error.
# -----------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"

export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX:-/opt/devbox/npm-global}"
# uv defaults to a 30 s HTTP timeout, which is fine on a fast direct link and
# marginal behind a corporate TLS-inspecting proxy — exactly the environment
# this image is built for. A large wheel (litellm, checkov's transitive tree)
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
npm_global "@openai/codex" "${V_ai_codex}"

if [ "${FEATURE_AI_GEMINI:-1}" = "1" ]; then
  npm_global "@google/gemini-cli" "${V_ai_gemini_cli}"
fi

if [ "${FEATURE_AI_EXTRA:-0}" = "1" ]; then
  section "Additional AI clients (FEATURE_AI_EXTRA)"
  npm_global "opencode-ai" "${V_ai_opencode}"
  retry 3 uv tool install --quiet "aider-chat==${V_ai_aider}"
fi

section "Model router + scriptable client"
# LiteLLM's *client library and proxy CLI* live here so `devbox ai` can talk to,
# and health-check, the router. The router itself runs as the `model-router`
# service in compose.yaml — see docs/ai.md.
retry 3 uv tool install --quiet "litellm[proxy]==${V_ai_litellm}"
retry 3 uv tool install --quiet "llm==${V_ai_llm}"

# `llm` plugins give the same binary a uniform interface across providers.
# Failures here are non-fatal: a missing optional plugin must not fail an image
# build, and `devbox doctor` reports which providers are actually wired up.
for plugin in llm-anthropic llm-gemini llm-ollama; do
  uv tool install --quiet --with "$plugin" "llm==${V_ai_llm}" 2>/dev/null ||
    warn "optional llm plugin unavailable: ${plugin}"
done

npm cache clean --force >/dev/null 2>&1 || true
uv cache clean >/dev/null 2>&1 || true

section "Installed AI clients"
claude --version 2>/dev/null || warn "claude not on PATH"
codex --version 2>/dev/null || warn "codex not on PATH"
ok "AI platform installed"
