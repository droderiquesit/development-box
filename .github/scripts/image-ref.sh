#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# image-ref.sh — resolve the canonical registry references for this repository.
#
#   image-ref.sh base            -> the pinned EXTERNAL base image ref
#                                   (repo:version from versions.yaml `base:`,
#                                   @digest instead when a digest is pinned)
#   image-ref.sh base-repo       -> the base image repository
#   image-ref.sh base-version    -> the pinned base version
#   image-ref.sh devbox-repo     -> ghcr.io/<owner>/<repo>
#   image-ref.sh devbox-version  -> the DevBox version from versions.yaml
#
# One place computes these, so a workflow, a compose file and a developer's
# `make pull` can never disagree about which image is meant.
#
# The base is an EXTERNAL dependency: a published release of the Base Image
# Factory (droderiquesit/ai-devbox), named fully — repo, version and, when
# pinned, digest — in versions.yaml's `base:` section. It is never derived
# from this repository's own identity, because it isn't this repository's
# image. Moving to a new base is an explicit, reviewable edit to that file.
#
# Environment:
#   GITHUB_REPOSITORY  owner/repo (set by Actions; falls back to the git remote)
#   REGISTRY           default ghcr.io (devbox refs only; the base carries its own)
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

yaml_get() { # yaml_get <section> <key> — two-level lookup in versions.yaml
  local section="$1" key="$2" root v
  root="$(git rev-parse --show-toplevel 2>/dev/null || printf '.')"
  if command -v yq >/dev/null 2>&1; then
    v="$(yq -r ".${section}.${key}" "${root}/versions.yaml")"
  else
    # yq is not guaranteed on a bare runner before the tool cache is restored.
    # This reads the same two lines and nothing else.
    v="$(awk -v s="^${section}:" -v k="  ${key}:" \
      '$0~s{r=1;next} r&&$0~"^"k{sub(/[ \t]+#.*$/,"");gsub(/.*: *"?|"$/,"");print;exit} r&&/^[^ ]/{exit}' \
      "${root}/versions.yaml")"
  fi
  [ "$v" = null ] && v=""
  printf '%s' "$v"
}

require() { # require <value> <what>
  [ -n "$1" ] || {
    echo "image-ref: ${2} missing from versions.yaml" >&2
    exit 1
  }
  printf '%s' "$1"
}

slug="$(repo_slug)"
slug="${slug,,}" # registries reject upper case in a path

case "${1:-}" in
  base-repo) require "$(yaml_get base repo)" base.repo ; printf '\n' ;;
  base-version) require "$(yaml_get base version)" base.version ; printf '\n' ;;
  base)
    brepo="$(require "$(yaml_get base repo)" base.repo)"
    bver="$(require "$(yaml_get base version)" base.version)"
    bdigest="$(yaml_get base digest)"
    # A digest names EXACTLY one artefact; a tag names whatever the registry
    # says it names today. Prefer the digest whenever one is pinned.
    if [ -n "$bdigest" ]; then
      printf '%s@%s\n' "$brepo" "$bdigest"
    else
      printf '%s:%s\n' "$brepo" "$bver"
    fi
    ;;
  devbox-repo) printf '%s/%s\n' "$REGISTRY" "$slug" ;;
  devbox-version) require "$(yaml_get release devbox)" release.devbox ; printf '\n' ;;
  *)
    echo "usage: image-ref.sh base|base-repo|base-version|devbox-repo|devbox-version" >&2
    exit 2
    ;;
esac
