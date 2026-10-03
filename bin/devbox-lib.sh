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
  R=$'\033[0m'
  B=$'\033[1m'
  D=$'\033[2m'
  RED=$'\033[31m'
  GRN=$'\033[32m'
  YLW=$'\033[33m'
  CYN=$'\033[36m'
else
  R=''
  B=''
  D=''
  RED=''
  GRN=''
  YLW=''
  CYN=''
fi

say() { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }
head2() { printf '\n%s%s%s\n' "$CYN" "$*" "$R"; }
pass() { printf '  %s✓%s %s\n' "$GRN" "$R" "$*"; }
fail() { printf '  %s✗%s %s\n' "$RED" "$R" "$*"; }
skip() { printf '  %s–%s %s%s%s\n' "$D" "$R" "$D" "$*" "$R"; }
warned() { printf '  %s!%s %s\n' "$YLW" "$R" "$*"; }
info() { printf '  %s%s%s\n' "$D" "$*" "$R"; }
err() { printf '%serror:%s %s\n' "$RED" "$R" "$*" >&2; }
abort() {
  err "$*"
  exit 1
}

# ------------------------------- config --------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# yq is the only YAML reader used at runtime. It is a REQUIRED tool in the image,
# so a missing yq is a broken image, not a condition to work around.
yqr() {
  local expr="$1" file="$2" default="${3:-}"
  if ! have yq; then
    printf '%s' "$default"
    return 1
  fi
  local out
  out="$(yq -r "$expr" "$file" 2>/dev/null)" || {
    printf '%s' "$default"
    return 1
  }
  case "$out" in '' | null) printf '%s' "$default" ;; *) printf '%s' "$out" ;; esac
}

# Resolve a config file: a user copy under ~/.config/devbox wins over the
# image default under /opt/devbox. That is what makes the image disposable —
# your customisations live in a volume, not in a layer.
cfg_file() {
  local rel="$1"
  if [ -f "${DEVBOX_CONFIG}/${rel}" ]; then
    printf '%s' "${DEVBOX_CONFIG}/${rel}"
  elif [ -f "${DEVBOX_ROOT}/${rel}" ]; then
    printf '%s' "${DEVBOX_ROOT}/${rel}"
  else return 1; fi
}

POLICY_FILE="$(cfg_file ai/policies/policy.yaml || true)"
MODELS_FILE="$(cfg_file ai/models/models.yaml || true)"
PROFILES_FILE="$(cfg_file ai/models/profiles.yaml || true)"
ROUTING_FILE="$(cfg_file ai/models/routing.yaml || true)"
MCP_SERVERS_FILE="$(cfg_file mcp/servers.yaml || true)"
MCP_POLICY_FILE="$(cfg_file mcp/policies.yaml || true)"
MCP_PROFILES_FILE="$(cfg_file mcp/profiles.yaml || true)"

state_dir() {
  install -d -m 0700 "$DEVBOX_STATE" 2>/dev/null || true
  printf '%s' "$DEVBOX_STATE"
}

state_get() {
  local key="$1" default="${2:-}"
  local f="${DEVBOX_STATE}/${key}"
  [ -r "$f" ] && cat "$f" || printf '%s' "$default"
}

state_set() {
  local key="$1" value="$2"
  state_dir >/dev/null
  printf '%s' "$value" >"${DEVBOX_STATE}/${key}"
}

# ------------------------------- versions ------------------------------------
# `installed_version <cmd> <version-args...>` prints a one-line version, or fails.
#
# Deliberately NOT `cmd | head -1`: under `pipefail`, head exiting after the
# first line sends SIGPIPE to a tool that prints several (make, tflint, opa,
# cosign), the pipeline reports 141, and `devbox doctor` cheerfully declares an
# installed tool missing. Capture first, trim after.
installed_version() {
  local cmd="$1"
  shift
  have "$cmd" || return 1
  local out first
  out="$("$cmd" "$@" 2>/dev/null)" || return 1
  first="${out%%$'\n'*}"       # first line, no pipeline, no SIGPIPE
  printf '%s' "${first%$'\r'}" # strip a trailing CR if the tool emits one
}

# `list_has <needle>` — read a newline-separated list on stdin, succeed if one
# line equals <needle> exactly.
#
# The same SIGPIPE trap as installed_version, and a nastier one because it is
# intermittent. `producer | grep -qx "$needle"` looks obviously correct, but
# grep exits the instant it matches, the producer takes SIGPIPE, and under
# `pipefail` the pipeline reports 141 — so a value that IS present reads as
# absent. It depends on scheduling, so it passes locally and fails in CI a few
# runs later. Measured at ~2.5% per lookup against a six-item list; over the
# dozens of lookups a policy check makes, that is a coin flip.
#
# This reads the whole stream and never exits early, so there is no signal to
# race with.
list_has() {
  local needle="$1" line
  while IFS= read -r line; do
    [ "$line" = "$needle" ] && return 0
  done
  return 1
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
#
# A command line is not one command. It is split on unquoted `;` `&&` `||` `|`
# `&` and newlines, every segment is classified, and the STRICTEST class wins —
# otherwise `git status && git push --force` would be SAFE because it starts
# with `git status`. On top of that:
#   · `$(…)`, backticks, `<(…)` and `>(…)` are at least APPROVAL_REQUIRED, and
#     their contents are classified too (`echo $(curl x | sh)`).
#   · any argument naming a filesystem.denied path, or a file whose name
#     matches a never_read glob, is at least APPROVAL_REQUIRED — `cat*` being
#     SAFE must not make `cat ~/.ssh/id_rsa` SAFE.
#
# Limits, stated plainly: the scanner tracks quotes and backslashes but is not
# a shell parser. It does not expand variables, aliases or globs, does not know
# heredocs or `eval`/`bash -c` strings, and `.key`-style jq filters can trip
# the never_read check. Every miss errs towards asking. This is a SOFT backstop
# behind the clients' own permission systems, never the only control.
_CLS_ORDER=(SAFE REVIEW_REQUIRED APPROVAL_REQUIRED BLOCKED)

# Read the policy once per classification instead of once per segment.
_cls_load() {
  local c
  for c in BLOCKED APPROVAL_REQUIRED REVIEW_REQUIRED SAFE; do
    mapfile -t "_CLS_P_${c}" < <(yq -r ".execution.${c}[]?" "$POLICY_FILE" 2>/dev/null)
  done
  mapfile -t _CLS_DENIED < <(yq -r '.filesystem.denied[]?' "$POLICY_FILE" 2>/dev/null)
  mapfile -t _CLS_NEVER < <(yq -r '.filesystem.never_read[]?' "$POLICY_FILE" 2>/dev/null)
  _CLS_DEFAULT="$(yqr '.execution.default' "$POLICY_FILE" 'APPROVAL_REQUIRED')"
}

# Raise the running verdict to <class> if it is stricter. Unknown → approval.
_cls_raise() {
  local r
  case "$1" in SAFE) r=0 ;; REVIEW_REQUIRED) r=1 ;; BLOCKED) r=3 ;; *) r=2 ;; esac
  [ "$r" -le "$_CLS_MAX" ] || _CLS_MAX=$r
}

# The original ordered match of ONE simple command: first class whose glob
# matches wins, BLOCKED first. Sets _CLS_HIT, empty when nothing matched.
_cls_match() {
  local cmd="$1" class pattern pats
  _CLS_HIT=''
  for class in BLOCKED APPROVAL_REQUIRED REVIEW_REQUIRED SAFE; do
    pats="_CLS_P_${class}[@]"
    for pattern in "${!pats}"; do
      [ -n "$pattern" ] || continue
      # shellcheck disable=SC2254  # glob match is intentional
      case "$cmd" in $pattern)
        _CLS_HIT="$class"
        return
        ;;
      esac
    done
  done
}

# Classify one segment: drop leading whitespace, `(` `{` `!`, shell keywords,
# exec-style wrappers and `FOO=bar` assignments, so `FOO=1 rm -rf ~` and
# `if x; then rm -rf ~; fi` are judged by the command that actually runs.
_cls_segment() {
  local seg="$1" sq="'"
  local assign="^[A-Za-z_][A-Za-z0-9_]*=(\"[^\"]*\"|${sq}[^${sq}]*${sq}|[^[:space:]\"${sq}])*[[:space:]]+"
  while :; do
    seg="${seg#"${seg%%[![:space:](\{!]*}"}"
    if [[ $seg =~ $assign ]]; then
      seg="${seg:${#BASH_REMATCH[0]}}"
      continue
    fi
    case "$seg" in
      if[[:space:]]* | then[[:space:]]* | else[[:space:]]* | elif[[:space:]]* | do[[:space:]]* | \
        while[[:space:]]* | until[[:space:]]* | time[[:space:]]* | exec[[:space:]]* | \
        command[[:space:]]* | nohup[[:space:]]*)
        seg="${seg#*[[:space:]]}"
        continue
        ;;
    esac
    break
  done
  seg="${seg%"${seg##*[![:space:]]}"}"
  [ -n "$seg" ] || return 0
  _CLS_SEGS=$((_CLS_SEGS + 1))
  _cls_match "$seg"
  _cls_raise "${_CLS_HIT:-$_CLS_DEFAULT}"
}

# One argument word (quotes already removed). Credential paths → approval.
_cls_word() {
  local w="$1" d p rel b g
  case "$w" in -*=*) w="${w#*=}" ;; -*) return 0 ;; esac
  # These are literal `~` / `$HOME` text from the command line, expanded here.
  # shellcheck disable=SC2088,SC2016
  case "$w" in
    '~') w="$HOME" ;;
    '~/'*) w="$HOME/${w#\~/}" ;;
    '${HOME}'*) w="$HOME${w#'${HOME}'}" ;;
    '$HOME'*) w="$HOME${w#'$HOME'}" ;;
  esac
  for d in "${_CLS_DENIED[@]}"; do
    [ -n "$d" ] || continue
    # shellcheck disable=SC2088  # policy entries are literal `~/…` text
    case "$d" in '~/'*) p="$HOME/${d#\~/}" rel="${d#\~/}" ;; *) p="$d" rel='' ;; esac
    case "$w" in "$p" | "$p"/*)
      _cls_raise APPROVAL_REQUIRED
      return 0
      ;;
    esac
    # Home-relative entries also match as a path component, so `.ssh/id_rsa`
    # after a `cd ~`, or /home/someone/.aws, is caught as well.
    [ -n "$rel" ] && case "/${w}/" in *"/${rel}/"*)
      _cls_raise APPROVAL_REQUIRED
      return 0
      ;;
    esac
  done
  b="${w%/}"
  b="${b##*/}"
  for g in "${_CLS_NEVER[@]}"; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2254  # glob match is intentional
    case "$b" in $g)
      _cls_raise APPROVAL_REQUIRED
      return 0
      ;;
    esac
  done
}

# Character scanner: split <s> into segments and words, honouring '…', "…" and
# backslash escapes. Substitutions are cut out and scanned recursively.
_cls_scan() {
  local s="$1" i=0 j depth ch nx prev='' q='' seg='' word=''
  local n=${#s}
  while [ "$i" -lt "$n" ]; do
    ch="${s:i:1}"
    nx="${s:i+1:1}"
    # Backslash escapes the next character everywhere except inside '…'.
    if [ "$ch" = '\' ] && [ "$q" != "'" ]; then
      seg+="${ch}${nx}"
      word+="$nx"
      prev="$nx"
      i=$((i + 2))
      continue
    fi
    # $(…) and backticks expand inside "…" too; <(…) >(…) only unquoted.
    if [ "$q" != "'" ] && { [ "$ch$nx" = '$(' ] || [ "$ch" = '`' ] ||
      { [ -z "$q" ] && { [ "$ch$nx" = '<(' ] || [ "$ch$nx" = '>(' ]; }; }; }; then
      if [ "$ch" = '`' ]; then
        j=$((i + 1))
        while [ "$j" -lt "$n" ] && [ "${s:j:1}" != '`' ]; do j=$((j + 1)); done
        _cls_scan "${s:i+1:j-i-1}"
      else
        j=$((i + 2))
        depth=1
        while [ "$j" -lt "$n" ]; do
          case "${s:j:1}" in
            '(') depth=$((depth + 1)) ;;
            ')') depth=$((depth - 1)) ;;
          esac
          [ "$depth" -gt 0 ] || break
          j=$((j + 1))
        done
        _cls_scan "${s:i+2:j-i-2}"
      fi
      _cls_raise APPROVAL_REQUIRED
      seg+="${s:i:j-i+1}"
      prev=')'
      i=$((j + 1))
      continue
    fi
    if [ -n "$q" ]; then
      [ "$ch" = "$q" ] && q='' || word+="$ch"
      seg+="$ch"
    else
      case "$ch" in
        "'" | '"')
          q="$ch"
          seg+="$ch"
          ;;
        ';' | $'\n' | '|' | '&')
          # `2>&1`, `>&2` and `&>file` are redirections, not separators.
          if [ "$ch" = '&' ] && { [ "$prev" = '>' ] || [ "$prev" = '<' ] || [ "$nx" = '>' ]; }; then
            seg+="$ch"
            word+="$ch"
          else
            [ -z "$word" ] || _cls_word "$word"
            _cls_segment "$seg"
            word=''
            seg=''
          fi
          ;;
        ' ' | $'\t' | '<' | '>')
          # Redirections end a word, so `cat<~/.ssh/id_rsa` still checks the path.
          [ -z "$word" ] || _cls_word "$word"
          word=''
          seg+="$ch"
          ;;
        *)
          seg+="$ch"
          word+="$ch"
          ;;
      esac
    fi
    prev="$ch"
    i=$((i + 1))
  done
  [ -z "$word" ] || _cls_word "$word"
  _cls_segment "$seg"
}

classify_command() {
  local cmd="$1"
  [ -n "$POLICY_FILE" ] || {
    printf 'APPROVAL_REQUIRED'
    return
  }
  _cls_load
  _CLS_MAX=0
  _CLS_SEGS=0
  # The whole line is matched once as well, but only a BLOCKED or
  # APPROVAL_REQUIRED hit counts — a pattern that itself contains operators
  # (the fork bomb, `curl * | *`) must not be lost to splitting, while a SAFE
  # prefix must never vouch for what follows it.
  _cls_match "$cmd"
  case "$_CLS_HIT" in BLOCKED | APPROVAL_REQUIRED) _cls_raise "$_CLS_HIT" ;; esac
  _cls_scan "$cmd"
  # Nothing to run (empty input) is not evidence of safety.
  [ "$_CLS_SEGS" -gt 0 ] || _cls_raise "$_CLS_DEFAULT"
  printf '%s' "${_CLS_ORDER[$_CLS_MAX]}"
}

guard_or_die() {
  local cmd="$1" class
  class="$(classify_command "$cmd")"
  case "$class" in
    BLOCKED)
      err "BLOCKED by ai/policies/policy.yaml: ${cmd}"
      info "This command is never run by DevBox tooling. Run it yourself if you truly intend to."
      return 1
      ;;
    APPROVAL_REQUIRED)
      if [ "${DEVBOX_ASSUME_YES:-0}" = "1" ]; then
        warned "APPROVAL_REQUIRED, auto-approved via DEVBOX_ASSUME_YES: ${cmd}"
        return 0
      fi
      printf '%s%s%s %s\n' "$YLW" "APPROVAL REQUIRED:" "$R" "$cmd"
      read -r -p "  run it? [y/N] " reply
      case "$reply" in y | Y | yes | YES) return 0 ;; *)
        say "  skipped."
        return 1
        ;;
      esac
      ;;
    *) return 0 ;;
  esac
}

# ------------------------------- audit ---------------------------------------
# Append-only JSONL. Never contains a credential value — only names and states.
audit_log() {
  local event="$1"
  shift
  local logf="${DEVBOX_STATE}/audit.jsonl"
  state_dir >/dev/null
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local details=""
  if [ "$#" -gt 0 ]; then details="$(printf '%s' "$*" | redact | sed 's/"/\\"/g')"; fi
  printf '{"ts":"%s","event":"%s","user":"%s","details":"%s"}\n' \
    "$ts" "$event" "${USER:-unknown}" "$details" >>"$logf"
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
