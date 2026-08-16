#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# DEVBOX IMAGE — GitHub CLI (signed apt repo).
#
# The Go-based developer tools (yq, task, actionlint, fzf, lazygit) are compiled
# in the builder stage — see 25-go-tools.sh.
#
# Classification:
#   gh          REQUIRED   auth / repo / pr / issue / workflow / run — the whole
#                          GitHub loop, and the transport the github-agent uses
#   act         REJECTED   local GitHub Actions runner. It needs a container
#                          socket inside the DevBox and its runner images drift
#                          from GitHub-hosted ones often enough to produce false
#                          confidence. `actionlint` for static errors plus a real
#                          `gh workflow run` on a throwaway branch is cheaper and
#                          more truthful. Revisit if you move to self-hosted
#                          runners built from the same image. See docs/decisions.md.
# -----------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"
require_root

section "GitHub CLI (apt)"
apt_add_repo githubcli \
  "https://cli.github.com/packages/githubcli-archive-keyring.gpg" \
  "deb [arch=$(devbox_arch) signed-by=@KEY@] https://cli.github.com/packages stable main"
apt_update
apt_install gh
apt_cleanup
gh --version | head -1
ok "gh installed"
