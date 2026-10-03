#!/bin/bash
# =============================================================================
# devbox-models startup script — static body (see startup-env.sh.tftpl).
# =============================================================================
# Runs as root on EVERY boot (google-startup-scripts.service) and is
# idempotent. On the very first boot it only prepares the VM and powers off
# (unless START_ON_CREATE=true). On later boots:
#
#   1. arm the watchdog (idle shutdown, max run time, startup timeout)
#   2. wait for the NVIDIA driver; make sure Docker can see the GPUs
#   3. RAID0 the local NVMe SSDs at /mnt/models (they are blank after a stop)
#   4. copy the staged weights from GCS (Private Google Access, no NAT)
#   5. read the API key from Secret Manager (metadata token + REST)
#   6. (re)create the vLLM container
#
# Logs go to journald (tag devbox-models) and Cloud Logging (log name
# devbox-models); the vLLM container logs to Cloud Logging via gcplogs.
# =============================================================================
# shellcheck disable=SC2154  # settings come from the rendered header
set -Eeuo pipefail # -E: the ERR trap in main() also fires inside functions
umask 077

readonly STATE_DIR=/var/lib/devbox-models # boot disk: survives stop/start
readonly RUN_DIR=/run/devbox-models       # tmpfs: reset every boot
readonly CONF_DIR=/etc/devbox-models
readonly LIB=/usr/local/lib/devbox-models/lib.sh
readonly WATCHDOG=/usr/local/sbin/devbox-models-watchdog
readonly MODELS_MNT=/mnt/models
readonly MD_NAME=devbox-models
readonly CONTAINER=vllm

mkdir -p "$STATE_DIR" "$RUN_DIR" "$CONF_DIR" "$(dirname "$LIB")"

# -----------------------------------------------------------------------------
# Shared helpers (also sourced by the watchdog)
# -----------------------------------------------------------------------------
cat >"$LIB" <<'LIBEOF'
# devbox-models helper library — written by the startup script.
DM_MD="http://metadata.google.internal/computeMetadata/v1"

dm_metadata() { # dm_metadata <path>
  curl -fsS --retry 5 --retry-connrefused -H 'Metadata-Flavor: Google' "${DM_MD}/$1"
}

dm_token() {
  dm_metadata instance/service-accounts/default/token |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'
}

# dm_log <INFO|WARNING|ERROR> <message...> — journald always, Cloud Logging
# best-effort (a logging outage must never break serving or shutdown).
dm_log() {
  local severity="$1"
  shift
  local msg="$*" prio=info
  case "$severity" in WARNING) prio=warning ;; ERROR) prio=err ;; esac
  logger -t devbox-models -p "user.${prio}" -- "$msg" || true
  echo "[devbox-models] ${severity}: ${msg}" >&2
  (
    set +e
    project="$(dm_metadata project/project-id)" || exit 0
    instance_id="$(dm_metadata instance/id)" || exit 0
    zone="$(dm_metadata instance/zone)" || exit 0
    token="$(dm_token)" || exit 0
    body="$(python3 - "$project" "$instance_id" "${zone##*/}" "$severity" "$msg" <<'PY'
import json, sys
project, instance_id, zone, severity, msg = sys.argv[1:6]
print(json.dumps({
    "logName": f"projects/{project}/logs/devbox-models",
    "resource": {"type": "gce_instance",
                 "labels": {"project_id": project, "instance_id": instance_id, "zone": zone}},
    "entries": [{"severity": severity, "textPayload": msg}],
}))
PY
)" || exit 0
    curl -fsS -m 10 -X POST -H "Authorization: Bearer ${token}" \
      -H 'Content-Type: application/json' --data-binary "$body" \
      https://logging.googleapis.com/v2/entries:write >/dev/null 2>&1
  ) || true
}

# dm_poweroff <reason> — stop the VM from inside the guest. A guest shutdown
# discards local SSD contents, which is what we want; the instance ends up
# TERMINATED (stopped) and GPU billing ends.
dm_poweroff() {
  dm_log WARNING "powering off: $*"
  touch /run/devbox-models/stopping 2>/dev/null || true
  sync
  shutdown -h now "devbox-models: $*"
}
LIBEOF
# shellcheck source=/dev/null
. "$LIB"

# -----------------------------------------------------------------------------
# Watchdog: systemd timer every 5 minutes
# -----------------------------------------------------------------------------
install_watchdog() {
  cat >"$CONF_DIR/watchdog.env" <<EOF
MODEL_KEY=${MODEL_KEY}
VLLM_PORT=${VLLM_PORT}
IDLE_SHUTDOWN_MINUTES=${IDLE_SHUTDOWN_MINUTES}
MAX_RUN_HOURS=${MAX_RUN_HOURS}
STARTUP_TIMEOUT_MINUTES=${STARTUP_TIMEOUT_MINUTES}
EOF

  cat >"$WATCHDOG" <<'WDEOF'
#!/bin/bash
# devbox-models watchdog — stops the VM when it is idle, has run too long, or
# never became ready. Invoked by devbox-models-watchdog.timer.
set -euo pipefail
# shellcheck source=/dev/null
. /usr/local/lib/devbox-models/lib.sh
# shellcheck source=/dev/null
. /etc/devbox-models/watchdog.env

run=/run/devbox-models
mkdir -p "$run"
[ -e "$run/stopping" ] && exit 0

now="$(date +%s)"
up="$(cut -d. -f1 /proc/uptime)"

# 1. Hard cap, whatever the activity.
if [ "$up" -ge $((MAX_RUN_HOURS * 3600)) ]; then
  dm_poweroff "max_run_hours=${MAX_RUN_HOURS} reached (uptime ${up}s)"
  exit 0
fi

metrics="$(curl -fsS -m 10 "http://127.0.0.1:${VLLM_PORT}/metrics" 2>/dev/null || true)"

if [ -z "$metrics" ]; then
  if [ ! -e "$run/ready_since" ]; then
    # 2. Never came up: weights copy, load or compile failed or is too slow.
    if [ "$up" -ge $((STARTUP_TIMEOUT_MINUTES * 60)) ]; then
      dm_poweroff "vLLM not ready ${STARTUP_TIMEOUT_MINUTES} min after boot"
    fi
    exit 0
  fi
  # Was serving, now unreachable: nobody can be using it — fall through to
  # the idle check with no activity recorded.
  total=-1
  active=0
else
  if [ ! -e "$run/ready_since" ]; then
    echo "$now" >"$run/ready_since"
    echo "$now" >"$run/last_activity"
    dm_log INFO "vLLM '${MODEL_KEY}' is serving (ready after ${up}s)"
  fi
  # Sum across label sets (finished_reason, engine, ...).
  total="$(awk '/^vllm:request_success_total[{ ]/ {s += $NF} END {printf "%.0f", s + 0}' <<<"$metrics")"
  active="$(awk '/^vllm:num_requests_(running|waiting)[{ ]/ {s += $NF} END {printf "%.0f", s + 0}' <<<"$metrics")"
fi

prev="$(cat "$run/last_total" 2>/dev/null || echo -2)"
if [ "$active" -gt 0 ] || { [ "$total" != "-1" ] && [ "$total" != "$prev" ]; }; then
  echo "$now" >"$run/last_activity"
fi
[ "$total" = "-1" ] || echo "$total" >"$run/last_total"

# 3. Idle shutdown (0 disables).
[ "$IDLE_SHUTDOWN_MINUTES" -gt 0 ] || exit 0
limit=$((IDLE_SHUTDOWN_MINUTES * 60))
ready_since="$(cat "$run/ready_since")"
last="$(cat "$run/last_activity" 2>/dev/null || echo "$ready_since")"
if [ $((now - last)) -ge "$limit" ] && [ $((now - ready_since)) -ge "$limit" ]; then
  dm_poweroff "idle for $(((now - last) / 60)) min (requests_total=${total}, active=${active})"
fi
WDEOF
  chmod 0755 "$WATCHDOG"

  cat >/etc/systemd/system/devbox-models-watchdog.service <<EOF
[Unit]
Description=devbox-models idle / max-run watchdog

[Service]
Type=oneshot
ExecStart=${WATCHDOG}
EOF

  cat >/etc/systemd/system/devbox-models-watchdog.timer <<'EOF'
[Unit]
Description=Run the devbox-models watchdog every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now devbox-models-watchdog.timer
}

# -----------------------------------------------------------------------------
# GPU driver and Docker
# -----------------------------------------------------------------------------
wait_for_gpu() {
  local i
  for i in $(seq 1 120); do
    if nvidia-smi -L >/dev/null 2>&1; then
      dm_log INFO "GPUs visible: $(nvidia-smi -L | wc -l) (driver $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1))"
      return 0
    fi
    [ "$i" -eq 1 ] && dm_log INFO "waiting for the NVIDIA driver (DLVM installs it on first boot)"
    sleep 10
  done
  dm_log ERROR "NVIDIA driver not available after 20 minutes"
  return 1
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    dm_log WARNING "docker missing from the image; installing docker.io"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io
  fi
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    dm_log WARNING "nvidia-container-toolkit missing; installing from NVIDIA's signed apt repo"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |
      gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit.gpg] https://#' \
        >/etc/apt/sources.list.d/nvidia-container-toolkit.list
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvidia-container-toolkit
  fi
  if ! docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
    nvidia-ctk runtime configure --runtime=docker
  fi
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl restart docker
}

pull_image() {
  if docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1; then
    return 0
  fi
  dm_log INFO "pulling ${VLLM_IMAGE}"
  local i
  for i in 1 2 3; do
    docker pull "$VLLM_IMAGE" && return 0
    sleep $((i * 15))
  done
  dm_log ERROR "could not pull ${VLLM_IMAGE}"
  return 1
}

# -----------------------------------------------------------------------------
# Local NVMe SSD → RAID0 at /mnt/models
# -----------------------------------------------------------------------------
setup_scratch() {
  mkdir -p "$MODELS_MNT"
  if mountpoint -q "$MODELS_MNT"; then
    return 0
  fi

  local dev="/dev/md/${MD_NAME}"
  local ssds=()
  mapfile -t ssds < <(find /dev/disk/by-id -name 'google-local-nvme-ssd-*' ! -name '*-part*' | sort)

  if [ "${#ssds[@]}" -eq 0 ]; then
    dm_log WARNING "no local NVMe SSD found; weights will be copied to the boot disk"
    mkdir -p "$STATE_DIR/models"
    mount --bind "$STATE_DIR/models" "$MODELS_MNT"
    return 0
  fi

  command -v mdadm >/dev/null 2>&1 || {
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mdadm
  }

  # A guest reboot keeps local SSD data: reassemble and reuse. After a stop
  # the disks are blank and the array is built from scratch.
  mdadm --assemble --scan >/dev/null 2>&1 || true
  if [ ! -e "$dev" ]; then
    if [ "${#ssds[@]}" -eq 1 ]; then
      dev="${ssds[0]}"
    else
      dm_log INFO "creating RAID0 over ${#ssds[@]} local NVMe SSDs"
      mdadm --create "$dev" --name="$MD_NAME" --level=0 --raid-devices="${#ssds[@]}" \
        --force --run "${ssds[@]}"
    fi
  fi
  if ! blkid "$dev" >/dev/null 2>&1; then
    mkfs.ext4 -q -F -m 0 -E lazy_itable_init=1,lazy_journal_init=1,discard "$dev"
  fi
  mount -o noatime,discard "$dev" "$MODELS_MNT"
  dm_log INFO "local SSD scratch mounted: $(df -h --output=size "$MODELS_MNT" | tail -1 | tr -d ' ')"
}

# -----------------------------------------------------------------------------
# Weights: GCS → local SSD
# -----------------------------------------------------------------------------
gcloud_bin() {
  local c
  for c in gcloud /usr/bin/gcloud /usr/lib/google-cloud-sdk/bin/gcloud /snap/bin/gcloud; do
    if command -v "$c" >/dev/null 2>&1; then
      command -v "$c"
      return 0
    fi
  done
  return 1
}

fetch_weights() {
  local dest="$MODELS_MNT/$MODEL_KEY"
  local marker="$dest/.devbox-complete"
  if [ -f "$marker" ] && [ "$(cat "$marker")" = "$WEIGHTS_URI" ]; then
    dm_log INFO "weights already on local SSD (${WEIGHTS_URI})"
    return 0
  fi

  local gc
  gc="$(gcloud_bin)" || {
    dm_log ERROR "gcloud not found on the image; cannot copy weights"
    return 1
  }
  if ! "$gc" storage ls "${WEIGHTS_URI}/.devbox-staged" >/dev/null 2>&1; then
    dm_log ERROR "weights not staged at ${WEIGHTS_URI} (no .devbox-staged marker). Run the gcp-models workflow with action=stage-weights, model=${MODEL_KEY}."
    return 1
  fi

  mkdir -p "$dest"
  local start
  start="$(date +%s)"
  dm_log INFO "copying ${WEIGHTS_URI} to local SSD"
  "$gc" storage rsync --recursive --no-user-output-enabled "$WEIGHTS_URI" "$dest"
  echo "$WEIGHTS_URI" >"$marker"
  dm_log INFO "weights copied in $(($(date +%s) - start))s ($(du -sh "$dest" | cut -f1))"
}

# -----------------------------------------------------------------------------
# API key: Secret Manager REST with the metadata-server token (no gcloud)
# -----------------------------------------------------------------------------
read_api_key() {
  local token
  token="$(dm_token)"
  curl -fsS --retry 5 -H "Authorization: Bearer ${token}" \
    "https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${SECRET_ID}/versions/latest:access" |
    python3 -c 'import base64,json,sys; print(base64.b64decode(json.load(sys.stdin)["payload"]["data"]).decode())'
}

# -----------------------------------------------------------------------------
# vLLM
# -----------------------------------------------------------------------------
start_vllm() {
  local key env_file="$RUN_DIR/vllm.env"
  key="$(read_api_key)"
  [ -n "$key" ] || {
    dm_log ERROR "empty API key from ${SECRET_ID}"
    return 1
  }

  # VLLM_API_KEY keeps the key out of the process list (vLLM reads it when
  # --api-key is not given). /metrics and /health stay unauthenticated, which
  # the watchdog relies on; only /v1, /v2, /inference and /cohere are guarded.
  {
    printf 'VLLM_API_KEY=%s\n' "$key"
    printf 'HF_HUB_OFFLINE=1\n'
    printf 'TRANSFORMERS_OFFLINE=1\n'
    printf '%s' "$VLLM_ENV_B64" | base64 -d
  } >"$env_file"
  chmod 0600 "$env_file"

  local args=()
  mapfile -t args < <(printf '%s' "$VLLM_ARGS_B64" | base64 -d)

  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run -d \
    --name "$CONTAINER" \
    --gpus all \
    --ipc=host \
    --ulimit memlock=-1 \
    --ulimit stack=67108864 \
    --restart unless-stopped \
    -p "${VLLM_PORT}:8000" \
    -v "$MODELS_MNT/$MODEL_KEY:/models/$MODEL_KEY:ro" \
    --env-file "$env_file" \
    --log-driver gcplogs \
    --log-opt "labels=devbox-model" \
    --label "devbox-model=${MODEL_KEY}" \
    "$VLLM_IMAGE" \
    "/models/$MODEL_KEY" \
    --served-model-name "$MODEL_KEY" \
    --host 0.0.0.0 \
    --port 8000 \
    --max-model-len "$MAX_MODEL_LEN" \
    "${args[@]}" >/dev/null
  rm -f "$env_file"
  dm_log INFO "vLLM container started for '${MODEL_KEY}' (${VLLM_IMAGE##*/}); loading weights"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  # Any unhandled failure stops the VM at once instead of leaving 8 GPUs
  # billing until the watchdog's startup timeout.
  trap 'dm_poweroff "startup script failed (line ${LINENO}); see log devbox-models"' ERR

  # A previous boot's container may have been restarted by Docker before the
  # local SSD array exists; remove it now, it is recreated below.
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

  install_watchdog

  if [ ! -e "$STATE_DIR/prepared" ]; then
    dm_log INFO "first boot of devbox-model-${MODEL_KEY}: preparing"
    wait_for_gpu
    ensure_docker
    pull_image
    touch "$STATE_DIR/prepared"
    if [ "$START_ON_CREATE" != "true" ]; then
      dm_poweroff "first-boot preparation finished; start the VM when you need '${MODEL_KEY}'"
      exit 0
    fi
  fi

  wait_for_gpu
  ensure_docker
  setup_scratch
  pull_image
  fetch_weights
  start_vllm
}

main "$@"
