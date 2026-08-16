#!/usr/bin/env bash
# shellcheck shell=bash
# This file is sourced. Nearly every variable it defines is consumed by the
# devbox/ai/mcp entrypoints rather than here, and static analysis cannot follow
# that across files.
# shellcheck disable=SC2034
# -----------------------------------------------------------------------------
# Shared runtime library for the devbox / ai / mcp CLIs.
#
# Kept deliberately small. These three commands exist to make the toolchain
# *consistent*, not to wrap it: `claude`, `codex`, `terraform` and `kubectl`
# remain fully available and unwrapped. Every function here is either output
# formatting, config lookup, or a policy check — never business logic that
# duplicates a tool that already exists.
# -----------------------------------------------------------------------------
set -uo pipefail

DEVBOX_ROOT="${DEVBOX_ROOT:-/opt/devbox}"
DEVBOX_WORKSPACE="${DEVBOX_WORKSPACE:-/workspace}"
DEVBOX_CONFIG="${DEVBOX_CONFIG:-$HOME/.config/devbox}"
DEVBOX_AI_CONFIG="${DEVBOX_AI_CONFIG:-$DEVBOX_CONFIG/ai}"
DEVBOX_MCP_CONFIG="${DEVBOX_MCP_CONFIG:-$DEVBOX_CONFIG/mcp}"
DEVBOX_STATE="${DEVBOX_AI_STATE:-$HOME/.local/state/devbox}"
DEVBOX_VERSION_FILE="${DEVBOX_ROOT}/versions.yaml"

# ------------------------------- output --------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${DEVBOX_PLAIN:-0}" != "1" ]; then
  R=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'
else
  R=''; B=''; D=''; RED=''; GRN=''; YLW=''; CYN=''
fi

say()   { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }
head2() { printf '\n%s%s%s\n' "$CYN" "$*" "$R"; }
pass()  { printf '  %s✓%s %s\n' "$GRN" "$R" "$*"; }
fail()  { printf '  %s✗%s %s\n' "$RED" "$R" "$*"; }
skip()  { printf '  %s–%s %s%s%s\n' "$D" "$R" "$D" "$*" "$R"; }
warned(){ printf '  %s!%s %s\n' "$YLW" "$R" "$*"; }
info()  { printf '  %s%s%s\n' "$D" "$*" "$R"; }
err()   { printf '%serror:%s %s\n' "$RED" "$R" "$*" >&2; }
abort() { err "$*"; exit 1; }

# ------------------------------- config --------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# yq is the only YAML reader used at runtime. It is a REQUIRED tool in the image,
# so a missing yq is a broken image, not a condition to work around.
yqr() {
  local expr="$1" file="$2" default="${3:-}"
  if ! have yq; then printf '%s' "$default"; return 1; fi
  local out
  out="$(yq -r "$expr" "$file" 2>/dev/null)" || { printf '%s' "$default"; return 1; }
  case "$out" in ''|null) printf '%s' "$default" ;; *) printf '%s' "$out" ;; esac
}

# Resolve a config file: a user copy under ~/.config/devbox wins over the
# image default under /opt/devbox. That is what makes the image disposable —
# your customisations live in a volume, not in a layer.
cfg_file() {
  local rel="$1"
  if [ -f "${DEVBOX_CONFIG}/${rel}" ]; then printf '%s' "${DEVBOX_CONFIG}/${rel}"
  elif [ -f "${DEVBOX_ROOT}/${rel}" ]; then printf '%s' "${DEVBOX_ROOT}/${rel}"
  else return 1; fi
}

POLICY_FILE="$(cfg_file ai/policies/policy.yaml || true)"
MODELS_FILE="$(cfg_file ai/models/models.yaml || true)"
PROFILES_FILE="$(cfg_file ai/models/profiles.yaml || true)"
ROUTING_FILE="$(cfg_file ai/models/routing.yaml || true)"
MCP_SERVERS_FILE="$(cfg_file mcp/servers.yaml || true)"
MCP_POLICY_FILE="$(cfg_file mcp/policies.yaml || true)"
MCP_PROFILES_FILE="$(cfg_file mcp/profiles.yaml || true)"

state_dir() { install -d -m 0700 "$DEVBOX_STATE" 2>/dev/null || true; printf '%s' "$DEVBOX_STATE"; }

state_get() {
  local key="$1" default="${2:-}"
  local f="${DEVBOX_STATE}/${key}"
  [ -r "$f" ] && cat "$f" || printf '%s' "$default"
}

state_set() {
  local key="$1" value="$2"
  state_dir >/dev/null
  printf '%s' "$value" > "${DEVBOX_STATE}/${key}"
}

# ------------------------------- versions ------------------------------------
# `installed_version <cmd> <version-args...>` prints a one-line version, or fails.
#
# Deliberately NOT `cmd | head -1`: under `pipefail`, head exiting after the
# first line sends SIGPIPE to a tool that prints several (make, tflint, opa,
# cosign), the pipeline reports 141, and `devbox doctor` cheerfully declares an
# installed tool missing. Capture first, trim after.
installed_version() {
  local cmd="$1"; shift
  have "$cmd" || return 1
  local out first
  out="$("$cmd" "$@" 2>/dev/null)" || return 1
  first="${out%%$'\n'*}"          # first line, no pipeline, no SIGPIPE
  printf '%s' "${first%$'\r'}"    # strip a trailing CR if the tool emits one
}

# ------------------------------- secrets -------------------------------------
# Report whether a credential is PRESENT. Never its value. Every code path in
# these CLIs that touches a credential goes through this function.
credential_state() {
  local var="$1"
  local val="${!var:-}"
  if [ -n "$val" ]; then printf 'set'; else printf 'unset'; fi
}

# Redact anything credential-shaped from arbitrary text before it is printed or
# sent to a model. Best-effort by nature — see docs/security.md.
redact() {
  sed -E \
    -e 's/(gh[pousr]_)[A-Za-z0-9]{16,}/\1<redacted>/g' \
    -e 's/(sk-ant-)[A-Za-z0-9_-]{16,}/\1<redacted>/g' \
    -e 's/(sk-)[A-Za-z0-9_-]{16,}/\1<redacted>/g' \
    -e 's/(AKIA)[0-9A-Z]{16}/\1<redacted>/g' \
    -e 's/(-----BEGIN [A-Z ]*PRIVATE KEY-----).*/\1<redacted>/g' \
    -e 's/([Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])([[:space:]]*[:=][[:space:]]*)[^[:space:],;"'"'"']+/\1\2<redacted>/g'
}

# ------------------------------- guardrails ----------------------------------
# Classify a command against ai/policies/policy.yaml.
# Prints one of: SAFE | REVIEW_REQUIRED | APPROVAL_REQUIRED | BLOCKED
# This is the single implementation; `ai run` and the generated client configs
# both derive from it, so there is exactly one place the rules live.
classify_command() {
  local cmd="$1"
  [ -n "$POLICY_FILE" ] || { printf 'APPROVAL_REQUIRED'; return; }
  local class pattern
  # BLOCKED is checked first and wins over everything.
  for class in BLOCKED APPROVAL_REQUIRED REVIEW_REQUIRED SAFE; do
    while IFS= read -r pattern; do
      [ -n "$pattern" ] || continue
      # shellcheck disable=SC2254  # glob match is intentional
      case "$cmd" in $pattern) printf '%s' "$class"; return ;; esac
    done < <(yq -r ".execution.${class}[]?" "$POLICY_FILE" 2>/dev/null)
  done
  yqr '.execution.default' "$POLICY_FILE" 'APPROVAL_REQUIRED'
}

guard_or_die() {
  local cmd="$1" class
  class="$(classify_command "$cmd")"
  case "$class" in
    BLOCKED)
      err "BLOCKED by ai/policies/policy.yaml: ${cmd}"
      info "This command is never run by DevBox tooling. Run it yourself if you truly intend to."
      return 1 ;;
    APPROVAL_REQUIRED)
      if [ "${DEVBOX_ASSUME_YES:-0}" = "1" ]; then
        warned "APPROVAL_REQUIRED, auto-approved via DEVBOX_ASSUME_YES: ${cmd}"
        return 0
      fi
      printf '%s%s%s %s\n' "$YLW" "APPROVAL REQUIRED:" "$R" "$cmd"
      read -r -p "  run it? [y/N] " reply
      case "$reply" in y|Y|yes|YES) return 0 ;; *) say "  skipped."; return 1 ;; esac ;;
    *) return 0 ;;
  esac
}

# ------------------------------- audit ---------------------------------------
# Append-only JSONL. Never contains a credential value — only names and states.
audit_log() {
  local event="$1"; shift
  local logf="${DEVBOX_STATE}/audit.jsonl"
  state_dir >/dev/null
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local details=""
  if [ "$#" -gt 0 ]; then details="$(printf '%s' "$*" | redact | sed 's/"/\\"/g')"; fi
  printf '{"ts":"%s","event":"%s","user":"%s","details":"%s"}\n' \
    "$ts" "$event" "${USER:-unknown}" "$details" >> "$logf"
}

# ------------------------------- misc ----------------------------------------
in_git_repo() { git rev-parse --git-dir >/dev/null 2>&1; }

repo_root() {
  if in_git_repo; then git rev-parse --show-toplevel; else pwd; fi
}

# List directories containing *.tf, excluding vendored/cached paths.
terraform_dirs() {
  find "${1:-.}" -type f -name '*.tf' \
    -not -path '*/.terraform/*' \
    -not -path '*/.git/*' \
    -not -path '*/node_modules/*' \
    -printf '%h\n' 2>/dev/null | sort -u
}
