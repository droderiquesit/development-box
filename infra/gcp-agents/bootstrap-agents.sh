#!/usr/bin/env bash
# =============================================================================
# One-time: let the existing CI deploy identity (infra/gcp-models/bootstrap.sh)
# also deploy infra/gcp-agents. Run by a HUMAN with Owner, once; idempotent.
#
#   infra/gcp-agents/bootstrap-agents.sh --project my-proj [--region us-central1]
#
# Least privilege, each grant justified:
#   run.admin                       create/update the agent services + their IAM
#   artifactregistry.admin          the devbox-agents repository (cleanup policies)
#   serviceusage.serviceUsageViewer refresh the google_project_service resources
#   storage.admin, CONDITIONED to the agent-state bucket only
#   iam.serviceAccountAdmin + iam.serviceAccountUser on the devbox-agent SA ONLY
#   resourcemanager.projectIamAdmin, CONDITIONED to granting exactly the agent
#     SA's three project roles (aiplatform.user, logWriter, metricWriter)
# Already held from the models bootstrap: secretmanager.admin, iap.admin.
# =============================================================================
set -euo pipefail

PROJECT=""
REGION="us-central1"
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    *) echo "usage: $0 --project <id> [--region <region>]" >&2; exit 2 ;;
  esac
done
[ -n "$PROJECT" ] || { echo "--project is required" >&2; exit 2; }

g() { gcloud --project="$PROJECT" --quiet "$@"; }
DEPLOY="serviceAccount:devbox-models-deploy@${PROJECT}.iam.gserviceaccount.com"
AGENT_SA="devbox-agent@${PROJECT}.iam.gserviceaccount.com"
BUCKET="${PROJECT}-devbox-agent-state"

g services enable run.googleapis.com artifactregistry.googleapis.com iap.googleapis.com aiplatform.googleapis.com

for r in roles/run.admin roles/artifactregistry.admin roles/serviceusage.serviceUsageViewer; do
  g projects add-iam-policy-binding "$PROJECT" --member="$DEPLOY" --role="$r" --condition=None >/dev/null
  echo "  $r -> deploy SA"
done

cond="$(mktemp)"
trap 'rm -f "$cond"' EXIT
cat >"$cond" <<EOF
title: devbox-agents-state-bucket
description: Only the agent-state bucket.
expression: resource.name.startsWith('projects/_/buckets/${BUCKET}')
EOF
g projects add-iam-policy-binding "$PROJECT" --member="$DEPLOY" --role=roles/storage.admin --condition-from-file="$cond" >/dev/null
echo "  roles/storage.admin (bucket ${BUCKET} only) -> deploy SA"

cat >"$cond" <<EOF
title: devbox-agents-limited-grants
description: Only the roles infra/gcp-agents grants at project level.
expression: >-
  api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly([
  'roles/aiplatform.user', 'roles/logging.logWriter', 'roles/monitoring.metricWriter'])
EOF
g projects add-iam-policy-binding "$PROJECT" --member="$DEPLOY" --role=roles/resourcemanager.projectIamAdmin --condition-from-file="$cond" >/dev/null
echo "  roles/resourcemanager.projectIamAdmin (agent roles only) -> deploy SA"

if g iam service-accounts describe "$AGENT_SA" >/dev/null 2>&1; then
  for r in roles/iam.serviceAccountAdmin roles/iam.serviceAccountUser; do
    g iam service-accounts add-iam-policy-binding "$AGENT_SA" --member="$DEPLOY" --role="$r" >/dev/null
    echo "  $r on $AGENT_SA -> deploy SA"
  done
else
  echo "  note: $AGENT_SA does not exist yet — apply infra/gcp-agents once by hand, then re-run this"
fi
echo "done. Region: ${REGION}"
