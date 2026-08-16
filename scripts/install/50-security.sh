#!/usr/bin/env bash
# The V_* variables below are assigned by scripts/lib/versions.sh via eval, which
# static analysis cannot follow.
# shellcheck disable=SC2154
# -----------------------------------------------------------------------------
# DEVBOX IMAGE — security, policy and software supply chain.
#
# Classification:
#   trivy      REQUIRED   one scanner covering IaC misconfig, container CVEs,
#                         filesystem CVEs, secrets and SBOM. Absorbed tfsec, so
#                         installing tfsec as well would be pure duplication.
#   gitleaks   REQUIRED   git-history secret detection; Trivy only scans a tree
#   opa        REQUIRED   the Rego engine itself (policy unit tests: `opa test`)
#   conftest   REQUIRED   applies Rego to plan JSON / YAML / Helm output
#   syft       REQUIRED   SBOM generation (SPDX + CycloneDX)
#   grype      REQUIRED   scans the SBOM rather than re-walking the filesystem
#   cosign     RECOMMENDED image signing + verification (keyless OIDC in CI)
#   semgrep    RECOMMENDED cross-language SAST; the one thing Trivy does not do
#   checkov    (installed by 30-iac.sh — IaC-specific policy depth Trivy lacks)
#   snyk       REJECTED   commercial licence + telemetry; overlaps Trivy/Grype
#   tfsec      REJECTED   upstream-merged into Trivy
# -----------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"
require_root

section "Trivy ${V_security_trivy} (apt)"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
apt_add_repo trivy \
  "https://aquasecurity.github.io/trivy-repo/deb/public.key" \
  "deb [signed-by=@KEY@] https://aquasecurity.github.io/trivy-repo/deb ${CODENAME} main"
apt_update
apt_install trivy
apt_cleanup
trivy --version | head -1

ok "Trivy installed (the Go-based security tools come from the builder stage)"
