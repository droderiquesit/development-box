#!/usr/bin/env bash
# The V_* variables below are assigned by scripts/lib/versions.sh via eval, which
# static analysis cannot follow.
# shellcheck disable=SC2154
# -----------------------------------------------------------------------------
# DEVBOX IMAGE — Kubernetes, Helm and GitOps tooling.
#
# Classification:
#   kubectl    REQUIRED     dl.k8s.io tarball + published .sha256
#   helm       REQUIRED     get.helm.sh tarball + published .sha256sum
#   kustomize  REQUIRED     go install; standalone binary still needed for
#                           `kustomize build` outside kubectl's vendored copy
#   k9s        RECOMMENDED  the single highest-leverage cluster debugging TUI
#   stern      RECOMMENDED  multi-pod log tailing; `kubectl logs` cannot do it
#   kubectx    RECOMMENDED  context/namespace switching (kubectx + kubens)
#   flux       RECOMMENDED  GitOps; CLI only, no cluster components installed
#   argocd     OPTIONAL     FEATURE_GITOPS_ARGO=1. Not both by default — pick the
#                           GitOps engine you actually run; installing both is
#                           two ways to do one job.
#   kind       OPTIONAL     FEATURE_K8S_LOCAL=1. Needs a container runtime socket
#                           inside the DevBox; see docs/decisions.md before
#                           enabling. Rootless Podman works but is not free.
#   k3d        REJECTED     duplicates kind and additionally requires a Docker
#                           socket specifically; kind speaks Podman natively.
# -----------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"
require_root

ARCH="$(devbox_arch)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

section "kubectl ${V_kubernetes_kubectl}"
KURL="https://dl.k8s.io/release/${V_kubernetes_kubectl}/bin/linux/${ARCH}/kubectl"
fetch "$KURL" "${TMP}/kubectl"
fetch "${KURL}.sha256" "${TMP}/kubectl.sha256"
verify_sha256 "${TMP}/kubectl" "$(tr -d ' \n' <"${TMP}/kubectl.sha256")"
install_bin "${TMP}/kubectl" kubectl
kubectl version --client=true --output=yaml | head -3
ok "kubectl installed"

section "Helm ${V_kubernetes_helm}"
HTAR="helm-${V_kubernetes_helm}-linux-${ARCH}.tar.gz"
fetch "https://get.helm.sh/${HTAR}" "${TMP}/${HTAR}"
fetch "https://get.helm.sh/${HTAR}.sha256sum" "${TMP}/${HTAR}.sha256sum"
verify_sha256 "${TMP}/${HTAR}" "$(awk '{print $1}' "${TMP}/${HTAR}.sha256sum")"
tar -C "$TMP" -xzf "${TMP}/${HTAR}"
install_bin "${TMP}/linux-${ARCH}/helm" helm
helm version --short
ok "Helm installed"

ok "kubectl + Helm installed (Go-based k8s tools come from the builder stage)"
