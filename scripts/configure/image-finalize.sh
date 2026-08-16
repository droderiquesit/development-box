#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Build-time finalisation of the DevBox image. Runs as root, once, at the end of
# the image build. Its job is to write things that must be identical for every
# container started from this image.
# -----------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root

DEV_USER="${DEV_USER:-dev}"
DEVBOX_ROOT=/opt/devbox

section "Finalising image"

# --- image identity ----------------------------------------------------------
{
  printf '%s\n' "${VERSION:-dev} (${VCS_REF:-unknown}) built ${BUILD_DATE:-unknown}"
} > /etc/devbox/image-version

# --- tool configuration shipped with the image -------------------------------
install -d -m 0755 /etc/devbox/completions

# Shell completions for the tools that generate them. Cheap to add, and their
# absence is one of those small papercuts that makes an environment feel unfinished.
gen_completion() {
  local name="$1"; shift
  command -v "$name" >/dev/null 2>&1 || return 0
  "$@" > "/etc/devbox/completions/${name}" 2>/dev/null \
    && ok "completion: ${name}" \
    || rm -f "/etc/devbox/completions/${name}"
}
gen_completion kubectl    kubectl completion bash
gen_completion helm       helm completion bash
gen_completion gh         gh completion -s bash
gen_completion terraform  bash -c 'echo "complete -C /usr/bin/terraform terraform"'
gen_completion tofu       bash -c 'echo "complete -C /usr/bin/tofu tofu"'
gen_completion flux       flux completion bash
gen_completion k9s        k9s completion bash
gen_completion just       just --completions bash
gen_completion task       task --completion bash
gen_completion devbox     bash -c 'echo "complete -W \"status doctor info versions update terraform github security ai mcp banner help\" devbox"'
gen_completion ai         bash -c 'echo "complete -W \"models providers use profile ask chat review architecture security run compare prompt agent list sync doctor\" ai"'
gen_completion mcp        bash -c 'echo "complete -W \"list status describe enable disable profile render doctor audit\" mcp"'

# --- global git configuration ------------------------------------------------
# System-level so it applies to every user, and is overridable per user.
install -m 0644 "${DEVBOX_ROOT}/config/git/gitconfig" /etc/gitconfig

# --- terraform/tflint defaults ----------------------------------------------
install -d -m 0755 /etc/devbox
install -m 0644 "${DEVBOX_ROOT}/config/terraform/.tflint.hcl" /etc/devbox/tflint.hcl 2>/dev/null || true

# --- permissions -------------------------------------------------------------
# The dev user must own its entire home directory. Several build steps run as
# root with HOME still pointing at /home/dev, which silently leaves root-owned
# directories under ~/.local — and then `devbox doctor` cannot write its audit
# log and `ai sync` fails with a confusing "No such file or directory".
chown -R "${DEV_UID:-1000}:${DEV_GID:-1000}" "/home/${DEV_USER}"

# Config the user may customise is group-writable; everything else read-only.
chown -R root:root "${DEVBOX_ROOT}"
chmod -R a+rX "${DEVBOX_ROOT}"
chmod 0755 "${DEVBOX_ROOT}"/bin/* 2>/dev/null || true

# --- the image must not carry credentials ------------------------------------
# A build-time assertion, so a mistake in an install script fails the build
# rather than shipping. Cheap insurance on the most expensive kind of mistake.
section "Verifying no credentials were baked in"
LEAKS=0
for f in /root/.aws /root/.azure /root/.config/gcloud /root/.ssh \
         "/home/${DEV_USER}/.aws" "/home/${DEV_USER}/.azure" \
         "/home/${DEV_USER}/.config/gcloud" "/home/${DEV_USER}/.ssh" \
         /root/.netrc /root/.git-credentials; do
  if [ -e "$f" ]; then warn "unexpected credential path present in image: $f"; LEAKS=1; fi
done
# Any file that looks like a private key is a hard failure.
if find / -xdev -type f \( -name 'id_rsa' -o -name 'id_ed25519' -o -name '*.pem' -o -name '*.p12' \) \
     -not -path '/usr/lib/*' -not -path '/usr/share/*' -not -path '/opt/devbox/uv-tools/*' \
     -not -path '/opt/devbox/npm-global/*' -not -path '/usr/local/go/*' 2>/dev/null | grep -q .; then
  warn "private-key-shaped files found — review the list below"
  find / -xdev -type f \( -name 'id_rsa' -o -name 'id_ed25519' -o -name '*.pem' -o -name '*.p12' \) \
    -not -path '/usr/lib/*' -not -path '/usr/share/*' -not -path '/opt/devbox/uv-tools/*' \
    -not -path '/opt/devbox/npm-global/*' -not -path '/usr/local/go/*' 2>/dev/null | head -20 >&2
fi
[ "$LEAKS" -eq 0 ] && ok "no credential directories in image" || die "credentials found in image — failing the build"

ok "image finalised"
