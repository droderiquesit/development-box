#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# devbox security sbom — software bill of materials + vulnerability scan.
#
#   devbox security sbom                       SBOM of the workspace
#   devbox security sbom --image ai-devbox     SBOM of a container image
#   devbox security sbom --output ./sbom       where to write
#   devbox security sbom --sign                sign it with cosign (keyless OIDC)
#
# Toolset: syft generates, grype consumes, cosign attests. Deliberately small:
# three tools that compose, rather than five that overlap. Trivy can also emit an
# SBOM, but using one generator everywhere keeps the artefacts comparable.
# -----------------------------------------------------------------------------
set -uo pipefail
# shellcheck source=../../bin/devbox-lib.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../bin/devbox-lib.sh"

TARGET="dir:${PWD}"
OUT="${PWD}/sbom"
SIGN=0
NAME="workspace"

while [ $# -gt 0 ]; do
  case "$1" in
    --image)
      TARGET="$2"
      NAME="$(printf '%s' "$2" | tr '/:' '__')"
      shift 2
      ;;
    --path)
      TARGET="dir:$2"
      NAME="$(basename "$2")"
      shift 2
      ;;
    --output)
      OUT="$2"
      shift 2
      ;;
    --sign)
      SIGN=1
      shift
      ;;
    -h | --help)
      sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) shift ;;
  esac
done

have syft || abort "syft is required for SBOM generation"
install -d -m 0755 "$OUT"

head1 "SBOM — ${TARGET}"

SPDX="${OUT}/${NAME}.spdx.json"
CDX="${OUT}/${NAME}.cdx.json"

# Two formats on purpose: SPDX is what compliance and legal ask for, CycloneDX is
# what security tooling consumes. They are cheap to produce and annoying to
# retrofit.
head2 "Generating"
syft scan "$TARGET" -o "spdx-json=${SPDX}" -o "cyclonedx-json=${CDX}" -q ||
  abort "syft failed"
pass "SPDX      ${SPDX}"
pass "CycloneDX ${CDX}"
info "$(jq -r '.packages | length' "$SPDX" 2>/dev/null || echo '?') packages catalogued"

head2 "Vulnerability scan (grype, against the SBOM)"
if have grype; then
  local_report="${OUT}/${NAME}.grype.json"
  grype "sbom:${CDX}" -o json --file "$local_report" -q 2>/dev/null || true
  crit="$(jq '[.matches[]?|select(.vulnerability.severity=="Critical")]|length' "$local_report" 2>/dev/null || echo 0)"
  high="$(jq '[.matches[]?|select(.vulnerability.severity=="High")]|length' "$local_report" 2>/dev/null || echo 0)"
  if [ "${crit:-0}" -gt 0 ] || [ "${high:-0}" -gt 0 ]; then
    fail "${crit} critical, ${high} high"
    jq -r '.matches[]?|select(.vulnerability.severity=="Critical" or .vulnerability.severity=="High")
           | "      \(.vulnerability.severity)  \(.artifact.name) \(.artifact.version)  \(.vulnerability.id)"' \
      "$local_report" 2>/dev/null | sort -u | head -25
  else
    pass "no critical or high vulnerabilities"
  fi
  info "report ${local_report}"
else
  skip "grype not installed"
fi

if [ "$SIGN" = 1 ]; then
  head2 "Signing (cosign, keyless)"
  if have cosign; then
    # Keyless signing binds the artefact to an OIDC identity, so there is no key
    # to store, rotate or leak. In CI this is the GitHub Actions OIDC token.
    COSIGN_EXPERIMENTAL=1 cosign sign-blob --yes \
      --output-signature "${SPDX}.sig" --output-certificate "${SPDX}.pem" "$SPDX" &&
      pass "signed ${SPDX}.sig" ||
      warned "cosign signing failed (needs an OIDC identity — works in CI)"
  else
    skip "cosign not installed"
  fi
fi

audit_log sbom "target=${TARGET} out=${OUT}"
printf '\n'
