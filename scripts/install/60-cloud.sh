#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# DEVBOX IMAGE — cloud provider CLIs. All three are OPTIONAL modules.
#
# They are opt-in because together they add roughly 1.5 GB and almost nobody
# needs all three on the same day. Enable exactly what you use:
#
#   podman build --build-arg FEATURE_CLOUD_AWS=1 --build-arg FEATURE_CLOUD_AZURE=1 ...
#
# Credentials are NEVER baked in. These install the client only; authentication
# happens at runtime through mounted credential stores, environment injection or
# (preferably) OIDC / workload identity. See docs/security.md.
# -----------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"
require_root

ARCH_ALT="$(devbox_arch_alt)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
INSTALLED_ANY=0

# ------------------------------------------------------------------- AWS -----
if [ "${FEATURE_CLOUD_AWS:-0}" = "1" ]; then
  section "AWS CLI v2"
  # AWS publishes a detached PGP signature for the installer zip. Verify it —
  # this is the one vendor that makes real signature verification easy.
  fetch "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH_ALT}.zip" "${TMP}/awscliv2.zip"
  fetch "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH_ALT}.zip.sig" "${TMP}/awscliv2.sig"
  cp "$(dirname "${BASH_SOURCE[0]}")/../../security/allowlists/aws-cli-public-key.asc" "${TMP}/aws.key"
  export GNUPGHOME="${TMP}/gnupg"
  install -d -m 0700 "$GNUPGHOME"
  gpg --batch --quiet --import "${TMP}/aws.key"
  # Bind trust to the fingerprint AWS publishes, not merely to whatever key
  # happens to sit in the repo — otherwise the allowlist file is the weak link.
  AWS_FPR_EXPECTED="FB5DB77FD5C118B80511ADA8A6310ACC4672475C"
  AWS_FPR_ACTUAL="$(gpg --batch --with-colons --fingerprint aws-cli@amazon.com |
    awk -F: '/^fpr:/{print $10; exit}')"
  [ "$AWS_FPR_ACTUAL" = "$AWS_FPR_EXPECTED" ] ||
    die "AWS CLI signing key fingerprint mismatch: got ${AWS_FPR_ACTUAL}"
  gpg --batch --verify "${TMP}/awscliv2.sig" "${TMP}/awscliv2.zip" ||
    die "AWS CLI signature verification FAILED"
  ok "AWS CLI signature verified"
  unzip -q "${TMP}/awscliv2.zip" -d "$TMP"
  "${TMP}/aws/install" --update >/dev/null
  aws --version
  INSTALLED_ANY=1
fi

# ----------------------------------------------------------------- Azure -----
if [ "${FEATURE_CLOUD_AZURE:-0}" = "1" ]; then
  section "Azure CLI"
  apt_add_repo microsoft \
    "https://packages.microsoft.com/keys/microsoft.asc" \
    "deb [arch=$(devbox_arch) signed-by=@KEY@] https://packages.microsoft.com/repos/azure-cli/ ${CODENAME} main"
  apt_update
  apt_install azure-cli
  # Telemetry off by default; an engineering workstation should not phone home
  # about every command a developer runs. Re-enable per user if you want it.
  install -d -m 0755 /etc/azure
  az config set core.collect_telemetry=false --only-show-errors 2>/dev/null || true
  az version --output tsv 2>/dev/null | head -1 || az --version | head -1
  INSTALLED_ANY=1
fi

# ------------------------------------------------------------------- GCP -----
if [ "${FEATURE_CLOUD_GCP:-0}" = "1" ]; then
  section "Google Cloud CLI"
  apt_add_repo google-cloud \
    "https://packages.cloud.google.com/apt/doc/apt-key.gpg" \
    "deb [signed-by=@KEY@] https://packages.cloud.google.com/apt cloud-sdk main"
  apt_update
  # gke-gcloud-auth-plugin is mandatory for kubectl against GKE since 1.26.
  apt_install google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin
  gcloud config set core/disable_usage_reporting true --installation 2>/dev/null || true
  gcloud --version | head -1
  INSTALLED_ANY=1
fi

if [ "$INSTALLED_ANY" = "1" ]; then
  apt_cleanup
  ok "cloud CLIs installed"
else
  log "no cloud modules enabled (FEATURE_CLOUD_AWS/AZURE/GCP all 0)"
fi
