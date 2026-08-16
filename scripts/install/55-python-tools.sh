#!/usr/bin/env bash
# The V_* variables below are assigned by scripts/lib/versions.sh via eval, which
# static analysis cannot follow.
# shellcheck disable=SC2154
# -----------------------------------------------------------------------------
# DEVBOX IMAGE — Python-based CLIs.
#
# Every one of these is a *tool*, not a library: it gets its own isolated
# environment via `uv tool install`, so checkov's pinned urllib3 can never fight
# with semgrep's. Nothing is installed into the system interpreter.
#
# Classification:
#   ruff        REQUIRED    lint + import sort + formatter, one fast binary
#   black       RECOMMENDED still the house format in many existing repos
#   mypy        REQUIRED    static typing
#   pytest      REQUIRED    test runner
#   yamllint    REQUIRED    the only linter that catches YAML style/duplicate keys
#   pre-commit  REQUIRED    the local gate that mirrors CI
#   checkov     REQUIRED    IaC policy depth (also Helm/K8s/Dockerfile)
#   semgrep     RECOMMENDED cross-language SAST
#   ansible-lint OPTIONAL   FEATURE_ANSIBLE=1
# -----------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"

export UV_TOOL_DIR="${UV_TOOL_DIR:-/opt/devbox/uv-tools}"
export UV_TOOL_BIN_DIR="${UV_TOOL_BIN_DIR:-/opt/devbox/uv-tools/bin}"
mkdir -p "$UV_TOOL_DIR" "$UV_TOOL_BIN_DIR"

uv_tool() {
  local spec="$1"; shift
  log "uv tool install ${spec}"
  # PyPI times out often enough that an un-retried install is a coin flip on a
  # long build. Three attempts with backoff turns that into a non-event.
  retry 3 uv tool install --quiet "$spec" "$@"
}

section "Python CLIs (uv tool)"
uv_tool "ruff==${V_tools_ruff}"
uv_tool "black==${V_tools_black}"
uv_tool "mypy==${V_tools_mypy}"
uv_tool "pytest==${V_tools_pytest}"
uv_tool "yamllint==${V_tools_yamllint}"
uv_tool "pre-commit==${V_tools_pre_commit}"
uv_tool "checkov==${V_iac_checkov}"
uv_tool "semgrep==${V_security_semgrep}"

if [ "${FEATURE_ANSIBLE:-0}" = "1" ]; then
  uv_tool "ansible-lint==${V_tools_ansible_lint}"
fi

# uv caches wheels aggressively; the image does not need them.
uv cache clean >/dev/null 2>&1 || true
ok "Python CLIs installed"
