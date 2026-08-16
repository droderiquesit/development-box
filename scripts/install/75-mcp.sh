#!/usr/bin/env bash
# The V_* variables below are assigned by scripts/lib/versions.sh via eval, which
# static analysis cannot follow.
# shellcheck disable=SC2154
# -----------------------------------------------------------------------------
# DEVBOX IMAGE — Model Context Protocol servers.
#
# THE RULE HERE IS RESTRAINT. An MCP server is code with a tool surface that an
# LLM can invoke. Installing thirty of them is not a feature, it is thirty pieces
# of attack surface plus a context window full of tool definitions the model has
# to reason about. Every server below is either an official first-party server or
# a widely adopted one, and every one of them is disabled by default unless
# mcp/servers.yaml says otherwise.
#
# Classification (full reasoning in docs/mcp.md):
#   filesystem   REQUIRED    official; path-scoped to /workspace by policy
#   git          REQUIRED    official; local repo history without shelling out
#   github       REQUIRED    official GitHub server; runs as an OCI container so
#                            the token never enters the DevBox process tree
#   fetch        RECOMMENDED official; HTTP retrieval with a domain allowlist
#   time         RECOMMENDED official; tiny, removes a whole class of date bugs
#   memory       RECOMMENDED official; cross-session notes, stored in a volume
#   sequential-thinking RECOMMENDED official; structured decomposition
#   context7     RECOMMENDED version-accurate library docs — directly fixes the
#                            "invented provider attribute" failure mode
#   terraform    RECOMMENDED HashiCorp's official registry server (OCI container)
#   kubernetes   OPTIONAL    off by default, trust=restricted. A cluster-admin
#                            kubeconfig handed to an LLM is the single most
#                            dangerous integration in this repo.
#   playwright   OPTIONAL    browser research; heavy, pulls a browser runtime
#   aws/azure/gcp OPTIONAL   cloud MCP servers; off by default for the same
#                            reason as kubernetes — they inherit real credentials
#   "awesome-mcp" lists  REJECTED  unvetted third-party servers do not go in an
#                            image that also holds cloud credentials.
# -----------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"

export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX:-/opt/devbox/npm-global}"
# See 55-python-tools.sh: 30 s is not enough behind a proxy, and all three
# retries then fail on the same timeout rather than on anything real.
export UV_HTTP_TIMEOUT="${UV_HTTP_TIMEOUT:-180}"
export UV_CONCURRENT_DOWNLOADS="${UV_CONCURRENT_DOWNLOADS:-4}"
export UV_TOOL_DIR="${UV_TOOL_DIR:-/opt/devbox/uv-tools}"
export UV_TOOL_BIN_DIR="${UV_TOOL_BIN_DIR:-/opt/devbox/uv-tools/bin}"

npm_global() {
  local pkg="$1" ver="${2:-latest}"
  log "npm install -g ${pkg}@${ver}"
  retry 3 npm install -g --no-fund --no-audit --loglevel=error "${pkg}@${ver}"
}

section "MCP servers (Node)"
npm_global "@modelcontextprotocol/server-filesystem" "${V_mcp_filesystem}"
npm_global "@modelcontextprotocol/server-memory" "${V_mcp_memory}"
npm_global "@modelcontextprotocol/server-sequential-thinking" "${V_mcp_sequential_thinking}"
npm_global "@upstash/context7-mcp" "${V_mcp_context7}"

if [ "${FEATURE_MCP_BROWSER:-0}" = "1" ]; then
  npm_global "@playwright/mcp" "${V_mcp_playwright}"
fi
if [ "${FEATURE_MCP_KUBERNETES:-0}" = "1" ]; then
  npm_global "kubernetes-mcp-server" "${V_mcp_kubernetes}"
fi

section "MCP servers (Python)"
retry 3 uv tool install --quiet "mcp-server-git==${V_mcp_git}"
retry 3 uv tool install --quiet "mcp-server-fetch==${V_mcp_fetch}"
retry 3 uv tool install --quiet "mcp-server-time==${V_mcp_time}"

# The GitHub and Terraform MCP servers deliberately run as OCI containers rather
# than in-image processes: it keeps their dependency trees out of this image and,
# more importantly, lets the GitHub token be scoped to one short-lived container
# instead of living in the DevBox environment. `mcp enable github` prints the
# exact `podman run` the client is configured to use.
section "Container-based MCP servers"
log "github:    ${V_mcp_github_image} (pulled on first use)"
log "terraform: ${V_mcp_terraform_image} (pulled on first use)"

npm cache clean --force >/dev/null 2>&1 || true
uv cache clean >/dev/null 2>&1 || true
ok "MCP servers installed"
