#!/usr/bin/env bash
# Point IAP for every agent service at YOUR OAuth client. Needed for projects
# without a Google Cloud organization (personal accounts): IAP then cannot use
# Google's managed client and answers 502 "Empty Google Account OAuth client".
# Run it yourself — the client secret is read without echo and only goes to
# the IAP settings API (it never touches Terraform state or this repo).
#
#   infra/gcp-agents/set-iap-oauth.sh <project> [region]
set -euo pipefail
project="${1:?usage: $0 <project> [region]}"
region="${2:-us-central1}"
read -rp 'OAuth client ID: ' client_id
read -rsp 'OAuth client secret: ' client_secret && echo
cfg="$(mktemp)"
trap 'rm -f "$cfg"' EXIT
chmod 600 "$cfg"
printf 'accessSettings:\n  oauthSettings:\n    clientId: %s\n    clientSecret: %s\n' "$client_id" "$client_secret" >"$cfg"
for svc in $(gcloud run services list --project "$project" --region "$region" \
  --filter='metadata.name~^hermes-' --format='value(metadata.name)'); do
  gcloud iap settings set "$cfg" --project "$project" --resource-type=cloud-run \
    --region "$region" --service "$svc" >/dev/null && echo "IAP OAuth client set for $svc"
done
echo "Redirect URI to register on the client:"
echo "  https://iap.googleapis.com/v1/oauth/clientIds/${client_id}:handleRedirect"
