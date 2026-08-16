# shellcheck shell=bash
# -----------------------------------------------------------------------------
# DevBox environment — the CONSUMER layer's drop-in.
#
# The base image (Base Image Factory, ai-engineering) owns the generic
# environment: TLS trust, locale, Go/Node/Python/uv roots and their PATH
# entries, all in ITS /etc/devbox/shell.d/00-env.sh. This file adds only what
# the DevBox layer itself installs and configures — IaC, Kubernetes, the AI
# platform, and the devbox/ai/mcp CLIs — via the base's documented extension
# mechanism: drop a file into /etc/devbox/shell.d/ and it is sourced after
# the base's, in name order. The Containerfile also symlinks this file into
# /etc/profile.d/ so non-interactive login shells (`bash -lc`, CI run-steps)
# see it exactly the way they see the base's env.
# -----------------------------------------------------------------------------

export DEVBOX_HOME="${DEVBOX_HOME:-/opt/devbox}"
export DEVBOX_WORKSPACE="${DEVBOX_WORKSPACE:-/workspace}"
export DEVBOX_CONFIG="${DEVBOX_CONFIG:-$HOME/.config/devbox}"

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
# The devbox/ai/mcp CLIs. The base's env already placed the language tool
# roots; this prepend puts the DevBox's own CLIs ahead of them, matching the
# image's baked ENV PATH ordering.
devbox_path_prepend() {
  case ":${PATH}:" in *":$1:"*) ;; *) PATH="$1:${PATH}" ;; esac
}
devbox_path_prepend /opt/devbox/bin
devbox_path_prepend "$HOME/.local/bin"
export PATH
