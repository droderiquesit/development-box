#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# One Hermes agent on Cloud Run.
#
# Cloud Run's disk is wiped whenever the instance stops (scale to zero, new
# revision), and Hermes keeps its state in SQLite, which must not live on a
# GCS FUSE mount. So: restore state from the agent's bucket prefix on start,
# snapshot it back every $BACKUP_INTERVAL seconds and on SIGTERM (Cloud Run
# allows 10 s), and serve the dashboard meanwhile. Unpushed work younger than
# one interval can be lost if the instance dies hard — agents push branches.
#
# Env (set by infra/gcp-agents): AGENT_NAME, AGENT_STATE_BUCKET,
#   GOOGLE_CLOUD_PROJECT, VERTEX_REGION, HERMES_MODEL, PORT,
#   HERMES_DASHBOARD_BASIC_AUTH_{USERNAME,PASSWORD_HASH,SECRET}  (secrets)
#   GH_TOKEN (optional secret: lets the agent push branches and open PRs)
# -----------------------------------------------------------------------------
set -euo pipefail

: "${AGENT_NAME:?}" "${AGENT_STATE_BUCKET:?}" "${GOOGLE_CLOUD_PROJECT:?}"
BACKUP_INTERVAL="${BACKUP_INTERVAL:-300}"
PREFIX="agents/${AGENT_NAME}"
log() { printf '{"severity":"%s","message":"%s"}\n' "$1" "$2"; }

# --- Cloud Storage via the metadata-server token (no SDK in the image) -------
token() {
  curl -fsS -H 'Metadata-Flavor: Google' \
    http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token | jq -r .access_token
}
gcs_get() { # gcs_get <object> <file> → 0 if it existed
  local code
  code="$(curl -sS -o "$2" -w '%{http_code}' -H @<(printf 'Authorization: Bearer %s\n' "$(token)") \
    "https://storage.googleapis.com/storage/v1/b/${AGENT_STATE_BUCKET}/o/$(jq -rn --arg o "$1" '$o|@uri')?alt=media")"
  [ "$code" = 200 ]
}
gcs_put() { # gcs_put <file> <object>
  curl -fsS -o /dev/null -X POST -H @<(printf 'Authorization: Bearer %s\n' "$(token)") \
    -H 'Content-Type: application/octet-stream' --data-binary @"$1" \
    "https://storage.googleapis.com/upload/storage/v1/b/${AGENT_STATE_BUCKET}/o?uploadType=media&name=$(jq -rn --arg o "$2" '$o|@uri')"
}

# --- restore -----------------------------------------------------------------
mkdir -p "$HERMES_HOME"
if gcs_get "$PREFIX/hermes.zip" /tmp/hermes.zip; then
  hermes import --force /tmp/hermes.zip >/dev/null && log INFO "restored hermes state"
fi
if gcs_get "$PREFIX/workspace.tgz" /tmp/workspace.tgz; then
  tar -xzf /tmp/workspace.tgz -C /workspace && log INFO "restored workspace"
fi
rm -f /tmp/hermes.zip /tmp/workspace.tgz

# --- configuration: only the keys the platform manages -----------------------
hset() { hermes config set "$1" "$2" >/dev/null; }
hset model.provider vertex
hset model.default "${HERMES_MODEL:-zai-org/glm-5.2-maas}"
hset vertex.project_id "$GOOGLE_CLOUD_PROJECT"
hset vertex.region "${VERTEX_REGION:-global}"
hset agent.max_turns 60
hset delegation.max_iterations 30
hset tool_loop_guardrails.hard_stop_enabled true
hset code_execution.timeout 300
hset terminal.cwd /workspace
hset terminal.timeout 180
hset compression.enabled true
hset compression.threshold_tokens 65536
hset updates.check false
hset telemetry.shared_metrics.enabled false
hset telemetry.shared_metrics.send false
if [ -n "${GH_TOKEN:-}" ]; then gh auth setup-git >/dev/null 2>&1 || true; fi
git config --global user.name "hermes-${AGENT_NAME}"
git config --global user.email "hermes-${AGENT_NAME}@users.noreply.github.com"

# --- snapshots ---------------------------------------------------------------
snapshot() {
  local ok=1
  hermes backup -o /tmp/hermes.zip >/dev/null 2>&1 && gcs_put /tmp/hermes.zip "$PREFIX/hermes.zip" || ok=0
  tar -czf /tmp/workspace.tgz -C /workspace \
    --exclude=node_modules --exclude=.venv --exclude=target --exclude=dist --exclude=__pycache__ . 2>/dev/null &&
    gcs_put /tmp/workspace.tgz "$PREFIX/workspace.tgz" || ok=0
  rm -f /tmp/hermes.zip /tmp/workspace.tgz
  if [ "$ok" = 1 ]; then log INFO "state saved"; else log WARNING "state save failed"; fi
}
(while sleep "$BACKUP_INTERVAL"; do snapshot; done) &
saver=$!

# --- serve -------------------------------------------------------------------
hermes dashboard --host 0.0.0.0 --port "${PORT:-8080}" --skip-build --no-open &
server=$!
shutdown() {
  log INFO "SIGTERM: saving state"
  kill "$saver" 2>/dev/null || true
  snapshot
  kill "$server" 2>/dev/null || true
  wait "$server" 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT
wait "$server"
