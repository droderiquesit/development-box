#!/usr/bin/env bash
# The V_* variables below are assigned by scripts/lib/versions.sh via eval, which
# static analysis cannot follow.
# shellcheck disable=SC2154
# -----------------------------------------------------------------------------
# DEVBOX IMAGE — BUILDER STAGE. Compiles every Go-based tool into $GOBIN.
#
# WHY `go install` RATHER THAN GITHUB RELEASE BINARIES
#   * Every fetch is verified end-to-end against the Go checksum database
#     (sum.golang.org) and the module proxy's immutable @v/<ver>.ziphash. That is
#     real supply-chain verification, not "we downloaded a tarball over TLS".
#   * One code path and one pin per tool, instead of a SHA-256 table per tool per
#     architecture that nobody remembers to update.
#   * arm64 works for free — several of these tools ship no arm64 release asset.
#   * No `curl | bash` anywhere, which is an explicit requirement of this repo.
#
#   The cost is build time and disk. That is exactly why this runs in a throwaway
#   builder stage — none of the Go cache reaches the final image — and why the
#   cache is reclaimed between groups (see `reclaim` below).
#
# Everything here is pinned in versions.yaml and updated by Renovate.
# -----------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"

: "${GOBIN:?GOBIN must be set for the builder stage}"
mkdir -p "$GOBIN"
# Assert the toolchain agrees. RUN steps execute as login shells, so a sourced
# profile could silently redirect GOBIN and scatter the binaries somewhere the
# next COPY cannot find them — which fails much later and much less clearly.
EFFECTIVE_GOBIN="$(go env GOBIN)"
[ "$EFFECTIVE_GOBIN" = "$GOBIN" ] || die "go env GOBIN is '${EFFECTIVE_GOBIN}', expected '${GOBIN}'"
export CGO_ENABLED=0            # static binaries; the runtime stage has no cgo deps
export GOFLAGS="-trimpath"      # reproducible paths in the emitted binaries

# DISK BUDGET
# Building ~18 independent Go programs accumulates well over 20 GB of module and
# build cache, because these tools share almost no dependencies (cosign alone
# pulls the AWS, Azure and GCP SDKs). The builder stage discards all of it, but
# *peak* usage still has to fit on the disk — and a standard GitHub-hosted runner
# has roughly 14 GB free.
#
# So we reclaim whenever the cache crosses a threshold, rather than at fixed
# points: it is self-tuning, it keeps the high-water mark bounded regardless of
# how the tool list grows, and the only cost is re-downloading some modules,
# which is network-bound and cheap.
GO_CACHE_BUDGET_MB="${GO_CACHE_BUDGET_MB:-3500}"

# NOTE on the `|| true`: `go clean -modcache` deletes GOMODCACHE outright, so a
# follow-up `du` exits non-zero. Under `set -euo pipefail` that would kill the
# build with no diagnostic at all — exactly the kind of silent failure that costs
# an hour to find.
cache_size_mb() {
  { du -sm "$GOMODCACHE" "$GOCACHE" 2>/dev/null || true; } | awk '{s+=$1} END{print s+0}'
}

reclaim() {
  local before after
  before="$(cache_size_mb)"
  go clean -cache -modcache 2>/dev/null || true
  after="$(cache_size_mb)"
  log "reclaimed $(( before - after )) MB of Go cache (was ${before} MB)"
}

# Reclaim only when the cache has actually grown past the budget.
reclaim_if_needed() {
  local size; size="$(cache_size_mb)"
  [ "$size" -lt "$GO_CACHE_BUDGET_MB" ] && return 0
  log "Go cache at ${size} MB (budget ${GO_CACHE_BUDGET_MB} MB)"
  reclaim
}

# tool <module> <version> <binary> — go_install plus the disk budget check.
# Deliberately not named `install`: that would shadow coreutils install, which
# install_bin() in common.sh relies on.
tool() {
  go_install "$@"
  reclaim_if_needed
}

section "IaC tools"
# terragrunt and infracost carry `replace` directives in go.mod, which `go
# install` refuses by design. They are installed from checksum-verified release
# artefacts in 26-release-tools.sh instead.
tool github.com/hashicorp/terraform-ls               "${V_iac_terraform_ls}"     terraform-ls
tool github.com/terraform-docs/terraform-docs        "${V_iac_terraform_docs}"   terraform-docs
tool github.com/terraform-linters/tflint             "${V_iac_tflint}"           tflint

section "Kubernetes tools"
tool sigs.k8s.io/kustomize/kustomize/v5              "${V_kubernetes_kustomize}" kustomize
tool github.com/derailed/k9s                         "${V_kubernetes_k9s}"       k9s
tool github.com/stern/stern                          "${V_kubernetes_stern}"     stern
tool github.com/ahmetb/kubectx/cmd/kubectx           "${V_kubernetes_kubectx}"   kubectx
tool github.com/ahmetb/kubectx/cmd/kubens            "${V_kubernetes_kubectx}"   kubens
# flux also uses `replace` directives — see 26-release-tools.sh.

section "Security / supply-chain tools"
tool github.com/zricethezav/gitleaks/v8              "${V_security_gitleaks}"    gitleaks
tool github.com/open-policy-agent/opa                "${V_security_opa}"         opa
tool github.com/open-policy-agent/conftest           "${V_security_conftest}"    conftest
tool github.com/anchore/syft/cmd/syft                "${V_security_syft}"        syft
tool github.com/anchore/grype/cmd/grype              "${V_security_grype}"       grype
tool github.com/sigstore/cosign/v2/cmd/cosign        "${V_security_cosign}"      cosign

section "Developer tools"
tool github.com/mikefarah/yq/v4                      "${V_tools_yq}"             yq
tool github.com/go-task/task/v3/cmd/task             "${V_tools_task}"           task
tool github.com/rhysd/actionlint/cmd/actionlint      "${V_tools_actionlint}"     actionlint
tool github.com/junegunn/fzf                         "${V_tools_fzf}"            fzf

if [ "${FEATURE_EXTRA_TUI:-1}" = "1" ]; then
  tool github.com/jesseduffield/lazygit              "${V_tools_lazygit}"        lazygit
fi

if [ "${FEATURE_K8S_LOCAL:-0}" = "1" ]; then
  section "kind (local clusters — FEATURE_K8S_LOCAL)"
  tool sigs.k8s.io/kind                              "${V_kubernetes_kind}"      kind
fi

reclaim

section "Builder output"
ls -1 "$GOBIN" | sort
printf '%s built %s binaries\n' "$DEVBOX_LOG_PREFIX" "$(ls -1 "$GOBIN" | wc -l)" >&2
