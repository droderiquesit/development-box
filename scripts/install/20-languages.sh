#!/usr/bin/env bash
# The V_* variables below are assigned by scripts/lib/versions.sh via eval, which
# static analysis cannot follow.
# shellcheck disable=SC2154
# -----------------------------------------------------------------------------
# BASE IMAGE — language runtimes: Go, Node.js, Python tooling entrypoint (uv).
#
# Acquisition strategy per runtime (see docs/decisions.md):
#   Go     REQUIRED  official go.dev tarball; SHA-256 taken from go.dev's signed
#                    release index over TLS and verified before extraction.
#   Node   REQUIRED  NodeSource signed apt repo, pinned to the current LTS major.
#                    Chosen over nvm: no per-shell shim, no runtime download.
#   Python REQUIRED  Ubuntu's system CPython 3.12 (LTS-supported until 2029).
#                    uv provides per-project interpreters when a project needs a
#                    different one — that is where a version manager earns its
#                    keep, not in the image.
#   uv     REQUIRED  the single installer for every Python CLI in the image.
# -----------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"
require_root

ARCH="$(devbox_arch)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------------ Go --------
section "Go ${V_languages_go}"

GO_TARBALL="go${V_languages_go}.linux-${ARCH}.tar.gz"
# go.dev publishes per-file SHA-256 in its release index; fetch it over TLS and
# use it as the authority rather than hardcoding a checksum per architecture.
fetch "https://go.dev/dl/?mode=json&include=all" "${TMP}/go-index.json"
GO_SHA="$(jq -r --arg v "go${V_languages_go}" --arg f "$GO_TARBALL" \
      '.[] | select(.version==$v) | .files[] | select(.filename==$f) | .sha256' \
      "${TMP}/go-index.json" | head -n1)"
[ -n "$GO_SHA" ] && [ "$GO_SHA" != "null" ] || die "could not resolve SHA-256 for ${GO_TARBALL}"

fetch_verified "https://go.dev/dl/${GO_TARBALL}" "${TMP}/go.tar.gz" "$GO_SHA"
rm -rf /usr/local/go
tar -C /usr/local -xzf "${TMP}/go.tar.gz"
ln -sf /usr/local/go/bin/go     /usr/local/bin/go
ln -sf /usr/local/go/bin/gofmt  /usr/local/bin/gofmt
/usr/local/go/bin/go version
ok "Go installed"

# --------------------------------------------------------------- Node.js ------
section "Node.js ${V_languages_node_major}.x (LTS)"

apt_add_repo nodesource \
  "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
  "deb [signed-by=@KEY@] https://deb.nodesource.com/node_${V_languages_node_major}.x nodistro main"
apt_update
apt_install nodejs
node --version
npm --version

# Global npm packages land in a world-readable prefix owned by the dev user so
# `npm i -g` works without sudo and without polluting /usr/lib.
install -d -m 0775 -o "${DEV_UID:-1000}" -g "${DEV_GID:-1000}" /opt/devbox/npm-global
npm config set prefix /opt/devbox/npm-global --global
# corepack ships with Node and manages pnpm/yarn without a second installer.
corepack enable --install-directory /usr/local/bin || warn "corepack enable failed (non-fatal)"
apt_cleanup
ok "Node.js installed"

# ------------------------------------------------------------------ uv --------
section "uv ${V_languages_uv} (Python package/tool manager)"

# Ubuntu 24.04 enforces PEP 668, so we give uv its own venv rather than fighting
# --break-system-packages. Every other Python CLI is then installed by uv into
# its own isolated environment (`uv tool install`), which is the whole point.
python3 -m venv /opt/devbox/uv-venv
/opt/devbox/uv-venv/bin/pip install --quiet --no-cache-dir --upgrade pip
/opt/devbox/uv-venv/bin/pip install --quiet --no-cache-dir "uv==${V_languages_uv}"
ln -sf /opt/devbox/uv-venv/bin/uv  /usr/local/bin/uv
ln -sf /opt/devbox/uv-venv/bin/uvx /usr/local/bin/uvx
uv --version

# pipx is kept as a REQUIRED companion only because several ecosystems still
# document `pipx install`; it shares uv's venv rather than getting its own.
/opt/devbox/uv-venv/bin/pip install --quiet --no-cache-dir pipx
ln -sf /opt/devbox/uv-venv/bin/pipx /usr/local/bin/pipx

# Shared, group-writable tool root so uv-installed CLIs are on PATH for all users.
install -d -m 0775 -o "${DEV_UID:-1000}" -g "${DEV_GID:-1000}" \
  /opt/devbox/uv-tools /opt/devbox/uv-tools/bin
ok "uv installed"
