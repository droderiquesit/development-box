# shellcheck shell=bash
# -----------------------------------------------------------------------------
# Prompt: context you actually need in an infra shell — git branch, kube context,
# active AI profile, and a red marker when the last command failed. No external
# prompt framework, no startup latency.
# -----------------------------------------------------------------------------
[ -z "${PS1:-}" ] && return 0

__devbox_git() {
  local b
  b="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || \
  b="$(git rev-parse --short HEAD 2>/dev/null)" || return 0
  local dirty=''
  git diff --quiet --ignore-submodules HEAD >/dev/null 2>&1 || dirty='*'
  printf ' \001\033[35m\002(%s%s)\001\033[0m\002' "$b" "$dirty"
}

__devbox_kube() {
  [ "${DEVBOX_PROMPT_KUBE:-1}" = "1" ] || return 0
  [ -r "${KUBECONFIG:-$HOME/.kube/config}" ] || return 0
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null)" || return 0
  [ -n "$ctx" ] && printf ' \001\033[36m\002⎈%s\001\033[0m\002' "$ctx"
}

__devbox_ai() {
  local p="${DEVBOX_AI_STATE:-$HOME/.local/state/devbox}/active-profile"
  [ -r "$p" ] || return 0
  printf ' \001\033[33m\002◆%s\001\033[0m\002' "$(cat "$p" 2>/dev/null)"
}

__devbox_ps1() {
  local rc=$?
  local mark='\001\033[32m\002❯\001\033[0m\002'
  [ $rc -ne 0 ] && mark='\001\033[31m\002❯\001\033[0m\002'
  PS1="\001\033[2m\002devbox\001\033[0m\002 \001\033[34m\002\w\001\033[0m\002$(__devbox_git)$(__devbox_kube)$(__devbox_ai)\n${mark} "
}

PROMPT_COMMAND='__devbox_ps1'

# Shell history is persisted to a named volume; keep it big and de-duplicated.
export HISTSIZE=100000
export HISTFILESIZE=200000
export HISTCONTROL=ignoreboth:erasedups
# Never persist a line that looks like it carries a secret. Cheap, imperfect,
# and far better than nothing — see docs/security.md.
export HISTIGNORE='*API_KEY*:*APIKEY*:*SECRET*:*TOKEN*:*PASSWORD*:*ghp_*:*sk-*:* --password *'
shopt -s histappend cmdhist checkwinsize 2>/dev/null || true
