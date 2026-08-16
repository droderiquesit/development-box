#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# podman-build.sh — build an image with registry-backed layer caching.
#
#   podman-build.sh <containerfile> <local-tag> [extra podman build args...]
#
# Environment:
#   CACHE_REPO   ghcr.io repository to read/write the layer cache from/to.
#                Unset disables caching entirely (the build still works).
#   CACHE_PUSH   1 to write the cache back. Off by default: a pull request from
#                a fork has no package:write, and a PR must never be able to
#                poison the cache that main builds from.
#
# WHY THIS EXISTS
# A cold build of the DevBox image is ~25 minutes, most of it compiling 18 Go
# tools that change only when versions.yaml changes. Without a shared cache
# every CI run pays that in full, because runners are ephemeral and start with
# an empty local store. `--cache-from` pulls the layers that are still valid;
# only the layers below an actual change get rebuilt.
#
# The cache is keyed by the registry repo, not by branch, so a feature branch
# that touches only prompts reuses main's toolchain layers. That is safe: cache
# entries are content-addressed by the instruction and its inputs, so a changed
# instruction simply misses rather than returning something stale.
# -----------------------------------------------------------------------------
set -euo pipefail

containerfile="${1:?usage: podman-build.sh <containerfile> <tag> [args...]}"
tag="${2:?usage: podman-build.sh <containerfile> <tag> [args...]}"
shift 2

args=(--file "$containerfile" --tag "$tag")

if [ -n "${CACHE_REPO:-}" ]; then
  # --layers is what makes intermediate layers cacheable at all; podman does not
  # enable it for `build` by default the way BuildKit does.
  args+=(--layers --cache-from "$CACHE_REPO")
  if [ "${CACHE_PUSH:-0}" = "1" ]; then
    # 8h TTL: long enough that weekday builds always hit, short enough that a
    # layer referencing a yanked upstream package ages out on its own.
    args+=(--cache-to "$CACHE_REPO" --cache-ttl 8h)
    echo "layer cache: read+write ${CACHE_REPO}"
  else
    echo "layer cache: read-only ${CACHE_REPO} (no write access on this event)"
  fi
else
  echo "layer cache: disabled (CACHE_REPO unset)"
fi

set -x
podman build "${args[@]}" "$@" .
