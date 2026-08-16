#!/usr/bin/env bash
# shellcheck shell=bash
# -----------------------------------------------------------------------------
# Shared helpers for every install / configure / health script.
#
# Design notes
#   * No curl | bash anywhere. Downloads are either (a) from a GPG-signed apt
#     repository, or (b) a pinned URL whose SHA-256 we verify before use.
#   * Go-based tools are installed with `go install` at a pinned version, which
#     is transparently verified against the Go checksum database (sum.golang.org).
#     That is stronger than hand-maintaining a SHA table per tool per arch.
#   * Every network fetch retries with backoff so a flaky mirror does not fail
#     a 20-minute image build.
# -----------------------------------------------------------------------------
set -euo pipefail

DEVBOX_LOG_PREFIX="${DEVBOX_LOG_PREFIX:-devbox}"

# ------------------------------- logging -------------------------------------
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''
fi
export C_RESET C_DIM C_RED C_GREEN C_YELLOW C_BLUE C_BOLD

log()   { printf '%s[%s]%s %s\n' "$C_BLUE" "$DEVBOX_LOG_PREFIX" "$C_RESET" "$*" >&2; }
ok()    { printf '%s[%s]%s %s✓%s %s\n' "$C_BLUE" "$DEVBOX_LOG_PREFIX" "$C_RESET" "$C_GREEN" "$C_RESET" "$*" >&2; }
warn()  { printf '%s[%s]%s %swarn%s %s\n' "$C_BLUE" "$DEVBOX_LOG_PREFIX" "$C_RESET" "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%s[%s]%s %serror%s %s\n' "$C_BLUE" "$DEVBOX_LOG_PREFIX" "$C_RESET" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# ------------------------------- platform ------------------------------------
devbox_arch() {           # go/OCI style: amd64 | arm64
  case "$(uname -m)" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}
devbox_arch_alt() {       # release-asset style: x86_64 | aarch64
  case "$(uname -m)" in
    x86_64|amd64)  echo x86_64 ;;
    aarch64|arm64) echo aarch64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------- fetching ------------------------------------
# fetch <url> <dest>  — retrying, fail-on-error download.
fetch() {
  local url="$1" dest="$2" attempt=1 max=5 delay=2
  while :; do
    if curl --fail --silent --show-error --location \
            --retry 0 --connect-timeout 20 --max-time 900 \
            -o "$dest" "$url"; then
      return 0
    fi
    [ "$attempt" -ge "$max" ] && die "download failed after ${max} attempts: $url"
    warn "download attempt ${attempt}/${max} failed, retrying in ${delay}s: $url"
    sleep "$delay"; delay=$(( delay * 2 )); attempt=$(( attempt + 1 ))
  done
}

# verify_sha256 <file> <expected>
verify_sha256() {
  local file="$1" expected="$2" actual
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || die "checksum mismatch for $file: expected $expected, got $actual"
  ok "checksum verified: $(basename "$file")"
}

# fetch_verified <url> <dest> <sha256|"">
# An empty checksum is allowed ONLY when the checksum is derived from a
# signed/authoritative sidecar fetched over TLS in the caller (e.g. Go's
# official SHA256 file, or dl.k8s.io's .sha256 companion).
fetch_verified() {
  local url="$1" dest="$2" sum="${3:-}"
  fetch "$url" "$dest"
  if [ -n "$sum" ]; then verify_sha256 "$dest" "$sum"; fi
}

# retry <attempts> <command...> — exponential backoff.
# Package registries time out. A twenty-minute image build must not be lost to
# one slow response from PyPI, so every network-touching install goes through
# this. It is deliberately *not* used for checksum verification: a bad checksum
# is a hard failure, not something to retry into submission.
retry() {
  local max="$1"; shift
  local attempt=1 delay=3
  while :; do
    if "$@"; then return 0; fi
    [ "$attempt" -ge "$max" ] && { warn "failed after ${max} attempts: $*"; return 1; }
    warn "attempt ${attempt}/${max} failed, retrying in ${delay}s: $1 $2"
    sleep "$delay"; delay=$(( delay * 2 )); attempt=$(( attempt + 1 ))
  done
}

# ------------------------------- apt -----------------------------------------
export DEBIAN_FRONTEND=noninteractive

apt_update()  { apt-get update -qq; }
apt_install() { apt-get install -y --no-install-recommends "$@"; }
apt_cleanup() { apt-get clean; rm -rf /var/lib/apt/lists/*; }

# apt_add_repo <name> <key-url> <repo-line-with-@KEY@>
# Adds a third-party apt repository using a dearmored keyring under
# /etc/apt/keyrings and a signed-by= entry. No apt-key, no unsigned repos.
apt_add_repo() {
  local name="$1" key_url="$2" repo_line="$3"
  local keyring="/etc/apt/keyrings/${name}.gpg" tmp
  install -d -m 0755 /etc/apt/keyrings
  tmp="$(mktemp)"
  fetch "$key_url" "$tmp"
  # Accept both armoured and binary keys.
  if gpg --batch --dearmor < "$tmp" > "${keyring}.tmp" 2>/dev/null; then
    mv "${keyring}.tmp" "$keyring"
  else
    mv "$tmp" "$keyring"
  fi
  chmod 0644 "$keyring"
  rm -f "$tmp" "${keyring}.tmp" 2>/dev/null || true
  printf '%s\n' "${repo_line//@KEY@/$keyring}" > "/etc/apt/sources.list.d/${name}.list"
  ok "apt repo added: ${name}"
}

# ------------------------------- go tools ------------------------------------
# go_install <module-path> <version> [binary-name]
# Installs into $GOBIN. Verified end-to-end by the Go checksum database.
go_install() {
  local module="$1" version="$2" bin="${3:-}"
  have go || die "go toolchain not found (needed to install ${module})"
  log "go install ${module}@${version}"
  GOFLAGS="${GOFLAGS:-} -trimpath" go install "${module}@${version}"
  if [ -n "$bin" ] && [ ! -x "${GOBIN:-$HOME/go/bin}/${bin}" ]; then
    die "go install ${module}@${version} did not produce ${bin}"
  fi
}

# ------------------------------- misc ----------------------------------------
# install_bin <src> <name> — place an executable on PATH with sane perms.
install_bin() {
  local src="$1" name="${2:-$(basename "$1")}"
  install -m 0755 "$src" "${DEVBOX_BIN_DIR:-/usr/local/bin}/${name}"
}

# require_root — install scripts must not run as the unprivileged dev user.
require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root"; }

# section <title> — pretty build-log separator.
section() {
  printf '\n%s══ %s %s%s\n' "$C_BOLD" "$*" "$(printf '═%.0s' $(seq 1 $(( 60 - ${#1} > 0 ? 60 - ${#1} : 3 ))))" "$C_RESET" >&2
}
