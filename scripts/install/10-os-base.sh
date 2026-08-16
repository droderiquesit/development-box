#!/usr/bin/env bash
# The V_* variables below are assigned by scripts/lib/versions.sh via eval, which
# static analysis cannot follow.
# shellcheck disable=SC2154
# -----------------------------------------------------------------------------
# BASE IMAGE — operating system packages and the non-root development user.
#
# Everything here comes from the signed Ubuntu archive. No third-party repos,
# no downloads. This is the slowest-changing layer in the whole stack.
# -----------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root

DEV_USER="${DEV_USER:-dev}"
DEV_UID="${DEV_UID:-1000}"
DEV_GID="${DEV_GID:-1000}"

section "OS packages"

# Prefer HTTPS transport for the Ubuntu archive. Two reasons: it keeps the
# package list off the wire in plain text, and a great many corporate egress
# proxies only forward CONNECT (HTTPS) and reject plain HTTP outright — which
# otherwise fails the very first apt call with an opaque 405.
#
# Ordering matters: the stock ubuntu image has no trust store, so we can only
# switch *before* the first apt call when a CA bundle was already seeded (the
# corporate-proxy case). Otherwise we install ca-certificates over HTTP first
# and switch afterwards, so every later layer still uses HTTPS.
# Set APT_USE_HTTPS=0 if your mirror is HTTP-only.
apt_switch_to_https() {
  [ "${APT_USE_HTTPS:-1}" = "1" ] || return 0
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    sed -i -E 's#http://(archive|security|[a-z]{2}\.archive)\.ubuntu\.com#https://\1.ubuntu.com#g' "$f"
  done
  ok "apt archive using HTTPS"
}

if [ -s /etc/ssl/certs/ca-certificates.crt ]; then
  apt_switch_to_https
  SWITCHED_EARLY=1
else
  log "no trust store yet — bootstrapping over the archive's default transport"
  SWITCHED_EARLY=0
fi

apt_update
apt_install \
  ca-certificates curl wget gnupg gpg-agent apt-transport-https \
  git git-lfs openssh-client rsync \
  build-essential pkg-config \
  python3 python3-venv python3-pip python3-dev \
  jq less tree file xz-utils unzip zip tar gzip bzip2 \
  vim nano tmux \
  bash-completion man-db locales procps psmisc lsof \
  ripgrep fd-find bat \
  shellcheck just direnv \
  dnsutils iproute2 iputils-ping netcat-openbsd socat \
  htop sudo uidmap \
  make

# Now that the real ca-certificates package is in place, make the seeded
# corporate roots canonical and (if we had to bootstrap over HTTP) move the
# archive to HTTPS for every subsequent layer.
update-ca-certificates >/dev/null
if [ "$SWITCHED_EARLY" = "0" ]; then
  apt_switch_to_https
  apt_update
fi

# Debian renames these binaries to avoid clashes; restore the upstream names so
# muscle memory and every tutorial on the internet keep working.
ln -sf /usr/bin/batcat /usr/local/bin/bat
ln -sf /usr/bin/fdfind /usr/local/bin/fd

# UTF-8 everywhere. A surprising number of CLIs (and every AI CLI) render boxes
# and emoji, which silently break under the POSIX locale.
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8

apt_cleanup
ok "OS packages installed"

section "Non-root development user: ${DEV_USER} (${DEV_UID}:${DEV_GID})"

# ubuntu:24.04 ships a stock `ubuntu` account already sitting on uid 1000.
# Reclaim that id so bind-mounted host files are owned correctly under
# `podman run --userns=keep-id`.
if id -u ubuntu >/dev/null 2>&1 && [ "$(id -u ubuntu)" = "1000" ] && [ "$DEV_UID" = "1000" ]; then
  userdel -r ubuntu 2>/dev/null || userdel ubuntu
fi

getent group "$DEV_GID" >/dev/null 2>&1 || groupadd --gid "$DEV_GID" "$DEV_USER"
id -u "$DEV_USER" >/dev/null 2>&1 ||
  useradd --uid "$DEV_UID" --gid "$DEV_GID" --create-home --shell /bin/bash "$DEV_USER"

# Passwordless sudo is a deliberate, documented tradeoff: this is a rootless
# container, so "root" inside it is an unprivileged uid on the host. Developers
# need apt/package access; a container without sudo just gets rebuilt constantly.
# Set FEATURE_SUDO=0 to drop it entirely (see docs/security.md).
if [ "${FEATURE_SUDO:-1}" = "1" ]; then
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$DEV_USER" >"/etc/sudoers.d/90-${DEV_USER}"
  chmod 0440 "/etc/sudoers.d/90-${DEV_USER}"
else
  rm -f "/etc/sudoers.d/90-${DEV_USER}"
fi

# Directory layout owned by the dev user. /workspace is the bind-mount target;
# the rest are named-volume mount points so caches survive container replacement.
install -d -m 0755 -o "$DEV_UID" -g "$DEV_GID" \
  /workspace \
  /opt/devbox \
  "/home/${DEV_USER}/.cache" \
  "/home/${DEV_USER}/.config" \
  "/home/${DEV_USER}/.local/bin" \
  "/home/${DEV_USER}/.local/share"

ok "user ${DEV_USER} created"
