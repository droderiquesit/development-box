#!/usr/bin/env bash
# Set the Hermes dashboard password for every agent. Run it yourself: the
# password is read without echo, hashed locally (scrypt, Hermes' own format),
# and only the hash is stored in Secret Manager. Agents pick it up on their
# next start (new revision or scale-from-zero).
#
#   infra/gcp-agents/set-dashboard-password.sh <project>
set -euo pipefail
project="${1:?usage: $0 <project>}"
read -rsp 'New dashboard password: ' pw && echo
read -rsp 'Repeat: ' pw2 && echo
[ "$pw" = "$pw2" ] || { echo "passwords differ" >&2; exit 1; }
[ "${#pw}" -ge 12 ] || { echo "use at least 12 characters" >&2; exit 1; }
PW="$pw" python3 - <<'PY' | gcloud secrets versions add hermes-dashboard-password-hash --data-file=- --project "$project"
import base64, hashlib, os, secrets, sys
salt = secrets.token_bytes(16)
dk = hashlib.scrypt(os.environ["PW"].encode(), salt=salt, n=2**14, r=8, p=1, dklen=32, maxmem=0)
sys.stdout.write(f"scrypt$16384$8$1${base64.b64encode(salt).decode()}${base64.b64encode(dk).decode()}")
PY
echo "stored. Restart agents to apply: gcloud run services update hermes-<name> --region us-central1 --project $project --update-labels=pw=$(date +%s)"
