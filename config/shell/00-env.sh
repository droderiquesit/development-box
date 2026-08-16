# shellcheck shell=bash
# -----------------------------------------------------------------------------
# DevBox environment. Sourced by both interactive and non-interactive shells so
# `podman exec devbox tf-check` behaves the same as a terminal.
# -----------------------------------------------------------------------------

export DEVBOX_HOME="${DEVBOX_HOME:-/opt/devbox}"
export DEVBOX_WORKSPACE="${DEVBOX_WORKSPACE:-/workspace}"
export DEVBOX_CONFIG="${DEVBOX_CONFIG:-$HOME/.config/devbox}"

# ------------------------------------------------------------- TLS trust -----
# Several toolchains ship their own CA bundle and ignore the OS trust store:
# uv and cargo use webpki, Node has a compiled-in list, and Python's requests
# uses certifi. Behind a TLS-inspecting corporate proxy that means a root CA you
# correctly installed into /usr/local/share/ca-certificates still produces
# "UnknownIssuer" from half the tools in the image.
#
# Pointing all of them at the system bundle fixes that once, here, rather than
# per-tool at the point of failure. See config/ca-certificates/README.md.
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
export SSL_CERT_DIR="${SSL_CERT_DIR:-/etc/ssl/certs}"
export CURL_CA_BUNDLE="${CURL_CA_BUNDLE:-$SSL_CERT_FILE}"
export REQUESTS_CA_BUNDLE="${REQUESTS_CA_BUNDLE:-$SSL_CERT_FILE}"
export NODE_EXTRA_CA_CERTS="${NODE_EXTRA_CA_CERTS:-$SSL_CERT_FILE}"
export UV_NATIVE_TLS="${UV_NATIVE_TLS:-true}"
export GIT_SSL_CAINFO="${GIT_SSL_CAINFO:-$SSL_CERT_FILE}"

export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export EDITOR="${EDITOR:-vim}"
export PAGER="${PAGER:-less}"
export LESS="${LESS:--R}"

# ----------------------------------------------------------------- Go --------
# Every value here honours an existing setting. This file is sourced by login
# shells, and image builds run RUN steps as login shells — so an unconditional
# assignment would silently overwrite a build-stage GOBIN and scatter binaries
# somewhere the next COPY cannot find them.
export GOPATH="${GOPATH:-$HOME/go}"
export GOROOT=/usr/local/go
export GOBIN="${GOBIN:-$GOPATH/bin}"
export GOMODCACHE="${GOMODCACHE:-$HOME/.cache/go/mod}"
export GOCACHE="${GOCACHE:-$HOME/.cache/go/build}"

# --------------------------------------------------------------- Node --------
export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX:-/opt/devbox/npm-global}"
export NPM_CONFIG_CACHE="${NPM_CONFIG_CACHE:-$HOME/.cache/npm}"
export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"

# ------------------------------------------------------------- Python --------
export UV_TOOL_DIR="${UV_TOOL_DIR:-/opt/devbox/uv-tools}"
export UV_TOOL_BIN_DIR="${UV_TOOL_BIN_DIR:-/opt/devbox/uv-tools/bin}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$HOME/.cache/pip}"
export PYTHONDONTWRITEBYTECODE=1

# ---------------------------------------------------------- Terraform --------
# Persistent provider cache: providers are downloaded once per version, not once
# per `terraform init`. Backed by a named volume (see compose.yaml).
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.cache/terraform/plugins}"
# Terraform >= 1.7 can safely populate the cache concurrently; without this a
# parallel `init` races and corrupts the cache directory.
export TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=false
export TF_CLI_CONFIG_FILE="${TF_CLI_CONFIG_FILE:-$HOME/.terraformrc}"
export TF_IN_AUTOMATION=1
export TF_DATA_DIR="${TF_DATA_DIR:-.terraform}"
# OpenTofu honours its own variables; keep both in lockstep.
export TOFU_PLUGIN_CACHE_DIR="$TF_PLUGIN_CACHE_DIR"
export TG_PROVIDER_CACHE=1
export TG_PROVIDER_CACHE_DIR="$TF_PLUGIN_CACHE_DIR"

# -------------------------------------------------------- Kubernetes --------
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export HELM_CACHE_HOME="${HELM_CACHE_HOME:-$HOME/.cache/helm}"

# ----------------------------------------------------------------- AI --------
export DEVBOX_AI_CONFIG="${DEVBOX_AI_CONFIG:-$HOME/.config/devbox/ai}"
export DEVBOX_MCP_CONFIG="${DEVBOX_MCP_CONFIG:-$HOME/.config/devbox/mcp}"
export DEVBOX_AI_STATE="${DEVBOX_AI_STATE:-$HOME/.local/state/devbox}"

# --------------------------------------------------------------- PATH --------
# Deliberate order: user overrides > devbox CLIs > tool roots > system.
devbox_path_prepend() {
  case ":${PATH}:" in *":$1:"*) ;; *) PATH="$1:${PATH}" ;; esac
}
devbox_path_prepend /usr/local/go/bin
devbox_path_prepend "$GOBIN"
devbox_path_prepend "$UV_TOOL_BIN_DIR"
devbox_path_prepend "$NPM_CONFIG_PREFIX/bin"
devbox_path_prepend "$PNPM_HOME"
devbox_path_prepend /opt/devbox/bin
devbox_path_prepend "$HOME/.local/bin"
export PATH
