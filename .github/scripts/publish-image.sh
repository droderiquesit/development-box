#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# publish-image.sh — push one built image to a registry under a semver ladder.
#
#   publish-image.sh <local-image> <dest-repo> <version> [extra-tag...]
#
# For version 1.2.3 this publishes 1.2.3, 1.2, 1, and latest.
#
# WHY THE LADDER
# A consumer picks the precision they want to be surprised at. Pinning :1.2.3
# never moves. Tracking :1.2 gets patch fixes — which for the BASE image is
# exactly the OS security patching path, with no API change. Tracking :1 gets
# minor releases too. `latest` is for people trying the thing out, and for
# nothing that matters.
#
# Writes `digest=` to $GITHUB_OUTPUT when running under Actions: everything
# downstream (signing, attestation, the release notes) must refer to the
# immutable digest, never to a tag that can be moved out from under it.
# -----------------------------------------------------------------------------
set -euo pipefail

src="${1:?usage: publish-image.sh <local-image> <dest-repo> <version> [extra-tag...]}"
dest="${2:?missing destination repository}"
version="${3:?missing version}"
shift 3

# Reject anything that is not a plain semver: a malformed version would publish
# a garbage ladder ("v1.2.3", "1.2.3-rc1" -> major tag "1") over the good tags.
if ! printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "publish-image: '$version' is not a bare MAJOR.MINOR.PATCH version" >&2
  exit 1
fi

major="${version%%.*}"
minor="${version%.*}"

tags=("$version" "$minor" "$major" latest "$@")

echo "publishing ${src}"
echo "        -> ${dest}"
printf '   tags: %s\n' "${tags[*]}"

for t in "${tags[@]}"; do
  [ -n "$t" ] || continue
  podman tag "$src" "${dest}:${t}"
  podman push "${dest}:${t}"
done

# Resolve the digest from the version tag specifically. Reading it from
# `latest` would be a race the moment two releases overlap.
digest="$(podman inspect --format '{{index .RepoDigests 0}}' "${dest}:${version}")"
echo "digest: ${digest}"
[ -z "${GITHUB_OUTPUT:-}" ] || echo "digest=${digest}" >>"$GITHUB_OUTPUT"
