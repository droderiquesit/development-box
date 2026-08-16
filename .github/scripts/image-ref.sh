#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# image-ref.sh — resolve the canonical registry references for this repository.
#
#   image-ref.sh base            -> ghcr.io/<owner>/<repo>-base:<pinned base version>
#   image-ref.sh base-repo       -> ghcr.io/<owner>/<repo>-base
#   image-ref.sh devbox-repo     -> ghcr.io/<owner>/<repo>
#   image-ref.sh base-version    -> the pinned base version from versions.yaml
#   image-ref.sh devbox-version  -> the DevBox version from versions.yaml
#
# One place computes these, so a workflow, a compose file and a developer's
# `make pull` can never disagree about which image is meant.
#
# The base version comes from versions.yaml, NOT from the branch or the run.
# That is what makes the base a dependency rather than a side effect: a DevBox
# build consumes a base release that already exists and was already tested, and
# moving to a new base is an explicit, reviewable edit to that file.
#
# Environment:
#   GITHUB_REPOSITORY  owner/repo (set by Actions; falls back to the git remote)
#   REGISTRY           default ghcr.io
# -----------------------------------------------------------------------------
set -euo pipefail

REGISTRY="${REGISTRY:-ghcr.io}"

repo_slug() {
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    printf '%s' "$GITHUB_REPOSITORY"
    return
  fi
  # Local use: derive from the origin remote so this works outside CI too.
  local url
  url="$(git config --get remote.origin.url 2>/dev/null || true)"
  [ -n "$url" ] || {
    echo "image-ref: no GITHUB_REPOSITORY and no git remote" >&2
    exit 1
  }
  url="${url%.git}"
  printf '%s' "${url#*github.com[:/]}" | sed 's#^.*github\.com[:/]##'
}

version_of() { # version_of base|devbox
  local key="$1" root
  root="$(git rev-parse --show-toplevel 2>/dev/null || printf '.')"
  local v
  if command -v yq >/dev/null 2>&1; then
    v="$(yq -r ".release.${key}" "${root}/versions.yaml")"
  else
    # yq is not guaranteed on a bare runner before the tool cache is restored.
    # This reads the same two lines and nothing else.
    v="$(awk -v k="  ${key}:" '/^release:/{r=1;next} r&&$0~"^"k{gsub(/.*: *"?|"$/,"");print;exit} r&&/^[^ ]/{exit}' "${root}/versions.yaml")"
  fi
  [ -n "$v" ] && [ "$v" != null ] || {
    echo "image-ref: release.${key} missing from versions.yaml" >&2
    exit 1
  }
  printf '%s' "$v"
}

slug="$(repo_slug)"
slug="${slug,,}" # registries reject upper case in a path

case "${1:-}" in
  base-repo) printf '%s/%s-base\n' "$REGISTRY" "$slug" ;;
  devbox-repo) printf '%s/%s\n' "$REGISTRY" "$slug" ;;
  base-version)
    version_of base
    printf '\n'
    ;;
  devbox-version)
    version_of devbox
    printf '\n'
    ;;
  base) printf '%s/%s-base:%s\n' "$REGISTRY" "$slug" "$(version_of base)" ;;
  *)
    echo "usage: image-ref.sh base|base-repo|devbox-repo|base-version|devbox-version" >&2
    exit 2
    ;;
esac
