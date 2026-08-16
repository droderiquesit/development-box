#!/usr/bin/env bash
# The V_* variables below are assigned by scripts/lib/versions.sh via eval, which
# static analysis cannot follow.
# shellcheck disable=SC2154
# -----------------------------------------------------------------------------
# DEVBOX IMAGE — Terraform and OpenTofu from their vendors' signed apt repos.
#
# The Go-based IaC tools (terragrunt, tflint, terraform-docs, terraform-ls,
# infracost) are compiled in the builder stage — see 25-go-tools.sh.
#
# Classification:
#   terraform       REQUIRED     the industry default
#   opentofu        REQUIRED     drop-in fork; many orgs run both, and a devbox
#                                that forces the choice is the wrong tool
#   tfsec           REJECTED     upstream-merged into Trivy, which is installed.
#                                Two scanners reporting the same finding is a
#                                cost with no benefit.
#   terraform apply REJECTED     as an alias/task. Deliberate: see
#                                ai/policies/guardrails.yaml.
# -----------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"
require_root

CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

section "HashiCorp apt repository"
apt_add_repo hashicorp \
  "https://apt.releases.hashicorp.com/gpg" \
  "deb [arch=$(devbox_arch) signed-by=@KEY@] https://apt.releases.hashicorp.com ${CODENAME} main"

section "OpenTofu apt repository"
apt_add_repo opentofu \
  "https://packages.opentofu.org/opentofu/tofu/gpgkey" \
  "deb [signed-by=@KEY@] https://packages.opentofu.org/opentofu/tofu/any/ any main"

apt_update

section "Terraform ${V_iac_terraform} / OpenTofu ${V_iac_opentofu}"
apt_install "terraform=${V_iac_terraform}-*"
apt_install "tofu=${V_iac_opentofu}"
# Hold both: an incidental `apt upgrade` inside a long-lived container must not
# silently move a developer onto a different minor line mid-project.
apt-mark hold terraform tofu >/dev/null
apt_cleanup

terraform version
tofu version
ok "Terraform + OpenTofu installed"
