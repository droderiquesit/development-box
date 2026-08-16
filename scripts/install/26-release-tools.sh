#!/usr/bin/env bash
# shellcheck disable=SC2154
# -----------------------------------------------------------------------------
# DEVBOX IMAGE — BUILDER STAGE. Tools installed from signed/checksummed release
# artefacts rather than `go install`.
#
# WHY THESE THREE ARE DIFFERENT
#   terragrunt, infracost and flux all publish a go.mod containing `replace`
#   directives. Go refuses `go install module@version` for such modules by
#   design — the replaced dependency graph would differ from what the module
#   author builds and tests, so the checksum database cannot vouch for the
#   result. That is Go being careful, not Go being broken, and working around it
#   (vendoring, GOFLAGS=-mod=mod, cloning and building) would give up exactly the
#   verification `go install` was chosen for in 25-go-tools.sh.
#
#   So for these we take the vendor's published release binary and verify it
#   against the vendor's published SHA-256 checksums file, fetched over TLS from
#   the same release. Different mechanism, same principle: nothing is installed
#   that we have not verified, and there is no `curl | bash` anywhere.
#
# Classification:
#   terragrunt  RECOMMENDED  DRY multi-environment root modules
#   infracost   RECOMMENDED  cost delta on a plan; drives the cost-agent
#   flux        RECOMMENDED  GitOps CLI (CLI only; installs nothing in a cluster)
# -----------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"

: "${GOBIN:?GOBIN must be set for the builder stage}"
mkdir -p "$GOBIN"
EFFECTIVE_GOBIN="$(go env GOBIN)"
[ "$EFFECTIVE_GOBIN" = "$GOBIN" ] || die "go env GOBIN is '${EFFECTIVE_GOBIN}', expected '${GOBIN}'"
ARCH="$(devbox_arch)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# checksum_for <checksums-file> <asset-name>
# Reads a `<sha256>  <filename>` list and returns the digest for one asset.
checksum_for() {
  awk -v want="$2" '$2 == want || $2 == "*" want { print $1; exit }' "$1"
}

# ---------------------------------------------------------------- terragrunt --
section "Terragrunt ${V_iac_terragrunt}"
TG_ASSET="terragrunt_linux_${ARCH}"
TG_BASE="https://github.com/gruntwork-io/terragrunt/releases/download/${V_iac_terragrunt}"
fetch "${TG_BASE}/SHA256SUMS" "${TMP}/tg.sums"
TG_SHA="$(checksum_for "${TMP}/tg.sums" "$TG_ASSET")"
[ -n "$TG_SHA" ] || die "no checksum published for ${TG_ASSET}"
fetch_verified "${TG_BASE}/${TG_ASSET}" "${TMP}/terragrunt" "$TG_SHA"
install -m 0755 "${TMP}/terragrunt" "${GOBIN}/terragrunt"
ok "terragrunt installed"

# ----------------------------------------------------------------- infracost --
section "Infracost ${V_iac_infracost}"
IC_ASSET="infracost-linux-${ARCH}.tar.gz"
IC_BASE="https://github.com/infracost/infracost/releases/download/${V_iac_infracost}"
fetch "${IC_BASE}/${IC_ASSET}.sha256" "${TMP}/ic.sum"
# Infracost publishes a bare digest, not a `digest  filename` list.
IC_SHA="$(awk '{print $1; exit}' "${TMP}/ic.sum")"
fetch_verified "${IC_BASE}/${IC_ASSET}" "${TMP}/${IC_ASSET}" "$IC_SHA"
tar -C "$TMP" -xzf "${TMP}/${IC_ASSET}"
install -m 0755 "${TMP}/infracost-linux-${ARCH}" "${GOBIN}/infracost"
ok "infracost installed"

# ---------------------------------------------------------------------- flux --
section "Flux ${V_kubernetes_flux}"
FLUX_V="${V_kubernetes_flux#v}"
FLUX_ASSET="flux_${FLUX_V}_linux_${ARCH}.tar.gz"
FLUX_BASE="https://github.com/fluxcd/flux2/releases/download/${V_kubernetes_flux}"
fetch "${FLUX_BASE}/flux_${FLUX_V}_checksums.txt" "${TMP}/flux.sums"
FLUX_SHA="$(checksum_for "${TMP}/flux.sums" "$FLUX_ASSET")"
[ -n "$FLUX_SHA" ] || die "no checksum published for ${FLUX_ASSET}"
fetch_verified "${FLUX_BASE}/${FLUX_ASSET}" "${TMP}/${FLUX_ASSET}" "$FLUX_SHA"
tar -C "$TMP" -xzf "${TMP}/${FLUX_ASSET}" flux
install -m 0755 "${TMP}/flux" "${GOBIN}/flux"
ok "flux installed"

section "Release-artefact tools installed"
ls -1 "${GOBIN}/terragrunt" "${GOBIN}/infracost" "${GOBIN}/flux"
