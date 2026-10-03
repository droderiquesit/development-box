#!/usr/bin/env bash
# =============================================================================
# stage-weights.sh — copy ONE pinned Hugging Face revision into GCS, once.
# =============================================================================
#   stage-weights.sh --repo deepseek-ai/DeepSeek-V4-Pro-0813 \
#                    --revision 72e1d3230f6c080a530b0a1d46f8eb4602340597 \
#                    --bucket <project>-devbox-model-weights \
#                    [--shard 0 --shards 8]   # split the files across runners
#   stage-weights.sh ... --finalize           # verify everything, write marker
#
# Files are STREAMED Hugging Face -> GCS (curl | sha256 | gcloud storage cp -),
# so the machine running this needs no disk space — a GitHub-hosted runner is
# enough, and that is how the gcp-models workflow runs it (action
# stage-weights: 8 parallel shards, then --finalize). It must never run on the
# H200 VMs: they would bill ~$43/h while downloading.
#
# Layout: gs://<bucket>/<repo>/<revision>/<file>. Large files are verified
# against the Hugging Face LFS sha256; small files by size. Objects that are
# already present with the right size are skipped, so re-running resumes.
# --finalize checks every file and writes <prefix>/.devbox-staged, which the
# VM requires before it will copy anything.
#
# Auth: gcloud must be authenticated as an identity with objectUser on the
# bucket (CI: the devbox-models-stage service account via WIF). HF_TOKEN in
# the environment is optional (public repos; it only raises rate limits).
# =============================================================================
set -euo pipefail

REPO=""
REVISION=""
BUCKET=""
SHARD=0
SHARDS=1
FINALIZE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --revision) REVISION="$2"; shift 2 ;;
    --bucket) BUCKET="$2"; shift 2 ;;
    --shard) SHARD="$2"; shift 2 ;;
    --shards) SHARDS="$2"; shift 2 ;;
    --finalize) FINALIZE=true; shift ;;
    -h | --help) sed -n '2,/^# =====/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "error: --repo owner/name required" >&2; exit 2; }
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || { echo "error: --revision must be a 40-char commit SHA" >&2; exit 2; }
[[ "$BUCKET" =~ ^[a-z0-9][a-z0-9._-]{1,220}$ ]] || { echo "error: --bucket required" >&2; exit 2; }
[[ "$SHARD" =~ ^[0-9]+$ && "$SHARDS" =~ ^[0-9]+$ && "$SHARD" -lt "$SHARDS" ]] || { echo "error: bad --shard/--shards" >&2; exit 2; }
for t in curl python3 gcloud; do command -v "$t" >/dev/null || { echo "error: $t is required" >&2; exit 1; }; done

PREFIX="gs://${BUCKET}/${REPO}/${REVISION}"
HF="https://huggingface.co"
AUTH=()
[ -z "${HF_TOKEN:-}" ] || AUTH=(-H "Authorization: Bearer ${HF_TOKEN}")

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- File list at the pinned revision: path<TAB>size<TAB>sha256|- ------------
curl -fsS --retry 5 "${AUTH[@]}" "${HF}/api/models/${REPO}/revision/${REVISION}?blobs=true" >"$work/info.json"
python3 - "$work/info.json" >"$work/files.tsv" <<'PY'
import json, sys
info = json.load(open(sys.argv[1]))
rows = []
for s in info.get("siblings", []):
    lfs = s.get("lfs") or {}
    size = lfs.get("size", s.get("size"))
    if size is None:
        sys.exit(f"no size for {s['rfilename']} (blobs=true missing?)")
    rows.append((s["rfilename"], int(size), lfs.get("sha256", "-")))
# Largest first, so round-robin sharding balances bytes per shard.
for name, size, sha in sorted(rows, key=lambda r: (-r[1], r[0])):
    if "\t" in name or "\n" in name:
        sys.exit(f"refusing odd file name {name!r}")
    print(f"{name}\t{size}\t{sha}")
PY
total_files="$(wc -l <"$work/files.tsv")"
total_bytes="$(awk -F'\t' '{s += $2} END {printf "%.0f", s}' "$work/files.tsv")"
echo "${REPO}@${REVISION}: ${total_files} files, $((total_bytes / 1000000000)) GB -> ${PREFIX}"

# --- What is already in GCS: url<TAB>size -----------------------------------
gcloud storage ls --long "${PREFIX}/**" 2>/dev/null |
  awk '$1 ~ /^[0-9]+$/ && $3 ~ /^gs:\/\// {print $3 "\t" $1}' >"$work/present.tsv" || true

present_size() { # present_size <path> -> size or empty
  awk -F'\t' -v u="${PREFIX}/$1" '$1 == u {print $2; exit}' "$work/present.tsv"
}

if [ "$FINALIZE" = true ]; then
  missing=0
  while IFS=$'\t' read -r path size _sha; do
    if [ "$(present_size "$path")" != "$size" ]; then
      echo "MISSING or wrong size: $path" >&2
      missing=$((missing + 1))
    fi
  done <"$work/files.tsv"
  if [ "$missing" -gt 0 ]; then
    echo "error: $missing file(s) not staged; re-run the staging shards" >&2
    exit 1
  fi
  python3 - "$REPO" "$REVISION" "$total_files" "$total_bytes" >"$work/marker.json" <<'PY'
import datetime, json, sys
repo, rev, files, size = sys.argv[1:5]
print(json.dumps({"repo": repo, "revision": rev, "files": int(files), "bytes": int(size),
                  "staged_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}))
PY
  gcloud storage cp "$work/marker.json" "${PREFIX}/.devbox-staged"
  echo "staged: ${PREFIX} (${total_files} files verified)"
  exit 0
fi

# --- Stream this shard's files ----------------------------------------------
cat >"$work/hash.py" <<'PY'
import hashlib, sys
h, n = hashlib.sha256(), 0
out = sys.stdout.buffer
for chunk in iter(lambda: sys.stdin.buffer.read(8 << 20), b""):
    h.update(chunk); n += len(chunk); out.write(chunk)
out.flush()
open(sys.argv[1], "w").write(f"{h.hexdigest()} {n}\n")
PY

i=-1
done_files=0
while IFS=$'\t' read -r path size sha; do
  i=$((i + 1))
  [ $((i % SHARDS)) -eq "$SHARD" ] || continue
  dst="${PREFIX}/${path}"
  if [ "$(present_size "$path")" = "$size" ]; then
    echo "skip  $path (present)"
    continue
  fi
  echo "copy  $path ($((size / 1000000)) MB)"
  url="${HF}/${REPO}/resolve/${REVISION}/${path}"
  ok=false
  for attempt in 1 2 3; do
    if curl -fsSL --retry 5 --retry-all-errors "${AUTH[@]}" "$url" |
      python3 "$work/hash.py" "$work/digest" |
      gcloud storage cp --no-user-output-enabled - "$dst"; then
      read -r got_sha got_size <"$work/digest"
      if [ "$got_size" = "$size" ] && { [ "$sha" = "-" ] || [ "$got_sha" = "$sha" ]; }; then
        ok=true
        break
      fi
      echo "  checksum/size mismatch (attempt $attempt): got $got_size bytes sha256 $got_sha" >&2
      gcloud storage rm --quiet "$dst" >/dev/null 2>&1 || true
    fi
    sleep $((attempt * 20))
  done
  [ "$ok" = true ] || { echo "error: failed to stage $path" >&2; exit 1; }
  done_files=$((done_files + 1))
done <"$work/files.tsv"

echo "shard ${SHARD}/${SHARDS}: ${done_files} file(s) copied"
