#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Point Hermes at the active model backend and apply the DevBox limits. Run by
# the entrypoint on every start and by `ai up`. Idempotent: only the keys below
# are written; everything else in Hermes' config stays yours.
#
#   vertex       Vertex AI managed open models in your project (default)
#   selfhosted   vLLM `coder` behind the IAP tunnel `ai up` opened
#   ollama_cloud OLLAMA_API_KEY → ollama.com; no key → host Ollama daemon
# -----------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=../../bin/devbox-lib.sh
. /opt/devbox/bin/devbox-lib.sh

set_key() { hermes config set "$1" "$2" >/dev/null; }
backend="$(state_get active-provider "$(yqr '.default_provider' "$MODELS_FILE" selfhosted)")"
ctx="$(yqr '.profiles.balanced.max_context_tokens' "$PROFILES_FILE" 65536)"

case "$backend" in
  vertex)
    # Native Vertex provider: Hermes mints and refreshes OAuth tokens from
    # Application Default Credentials (`gcloud auth application-default
    # login` once inside the box, or the VM's service account on GCP).
    # Asking gcloud would create ~/.config/gcloud in a box nobody has signed
    # in to yet; only consult it once that directory already exists.
    project="${DEVBOX_GCP_PROJECT:-${GOOGLE_CLOUD_PROJECT:-}}"
    if [ -z "$project" ] && [ -d "$HOME/.config/gcloud" ]; then
      project="$(gcloud config get-value project 2>/dev/null || true)"
    fi
    set_key model.provider vertex
    set_key model.default "$(yqr '.providers.vertex.aliases.coder' "$MODELS_FILE" zai-org/glm-5.2-maas)"
    set_key vertex.region "$(yqr '.providers.vertex.location' "$MODELS_FILE" global)"
    [ -n "$project" ] && set_key vertex.project_id "$project"
    ;;
  selfhosted)
    port="$(yqr '.providers.selfhosted.endpoints.coder.local_port' "$MODELS_FILE" 18002)"
    set_key model.provider custom
    set_key model.default coder
    set_key model.base_url "http://127.0.0.1:${port}/v1"
    # The key file is written by `ai up` from Secret Manager; Hermes needs the
    # value in its own config (HERMES_HOME is on a private volume).
    key_file="$(state_dir)/models-api-key"
    if [ -n "${DEVBOX_MODELS_API_KEY:-}" ]; then
      set_key model.api_key "$DEVBOX_MODELS_API_KEY"
    elif [ -s "$key_file" ]; then
      set_key model.api_key "$(cat "$key_file")"
    fi
    ;;
  ollama_cloud)
    alias_model() { yqr ".providers.ollama_cloud.aliases.$1" "$MODELS_FILE" "$2"; }
    cloud_name() { case "$1" in *:*) printf '%s-cloud' "$1" ;; *) printf '%s:cloud' "$1" ;; esac }
    primary="$(alias_model coder gpt-oss:120b)"
    if [ -n "${OLLAMA_API_KEY:-}" ]; then
      # Hermes reads OLLAMA_API_KEY from the environment; it is not written here.
      set_key model.provider ollama-cloud
      set_key model.default "$primary"
      set_key model.base_url "${OLLAMA_CLOUD_URL:-https://ollama.com}/v1"
    else
      base="${OLLAMA_BASE_URL:-$(yqr '.providers.ollama_cloud.proxy_url_default' "$MODELS_FILE" http://host.containers.internal:11434)}"
      set_key model.provider custom
      set_key model.default "$(cloud_name "$primary")"
      set_key model.base_url "${base}/v1"
      set_key model.api_key ollama # the daemon ignores it; Hermes requires a value
    fi
    ;;
  *) exit 0 ;; # a native-CLI backend: Hermes is not the agent for it
esac

# Bounded autonomy (policy.yaml → limits): an agent that loops burns GPU
# hours (self-hosted) or the shared monthly allowance (Ollama Cloud).
set_key agent.max_turns 60
set_key delegation.max_iterations 30
set_key tool_loop_guardrails.hard_stop_enabled true
set_key code_execution.timeout 300
set_key terminal.cwd /workspace
set_key terminal.timeout 180

# Token economy: compact long sessions well before the model's window.
set_key compression.enabled true
set_key compression.threshold_tokens "$ctx"

# The image pins Hermes; it must not update itself or phone home.
set_key updates.check false
set_key telemetry.shared_metrics.enabled false
set_key telemetry.shared_metrics.send false
