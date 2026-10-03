#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — ONE-TIME setup of a GCP project for infra/gcp-models.
# =============================================================================
# Run by a HUMAN with Owner (or equivalent) credentials, once per project.
# Agents and CI never run this. It is idempotent: re-running it converges.
#
#   infra/gcp-models/bootstrap.sh --project my-proj --iap-member user:me@example.com \
#       [--billing-account 0X0X0X-0X0X0X-0X0X0X] [--region us-central1] \
#       [--repo droderiquesit/development-box]
#
# It creates:
#   * required APIs
#   * gs://<project>-devbox-models-tfstate  (Terraform state: versioned,
#     uniform access, public access prevention)
#   * gs://<project>-devbox-model-weights   (staged weights: regional,
#     uniform access, public access prevention, no soft delete)
#   * service accounts:
#       devbox-models-runtime  the VMs           (roles managed by Terraform,
#                                                 + objectViewer on weights)
#       devbox-models-plan     CI terraform plan (read-only)
#       devbox-models-deploy   CI terraform apply (environment gcp-models)
#       devbox-models-stage    CI weight staging  (environment gcp-models)
#   * Workload Identity Federation pool "github" + provider "development-box"
#     accepting ONLY tokens from --repo on refs/heads/main or pull requests.
#
# and prints the `gh variable set` commands and the GPU quota request.
# =============================================================================
set -euo pipefail

PROJECT=""
REGION="us-central1"
REPO="droderiquesit/development-box"
BILLING_ACCOUNT=""
POOL_ID="github"
PROVIDER_ID="development-box"
ENVIRONMENT="gcp-models"
IAP_MEMBERS=()

usage() {
  sed -n '2,/^# =====/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --billing-account) BILLING_ACCOUNT="$2"; shift 2 ;;
    --iap-member) IAP_MEMBERS+=("$2"); shift 2 ;;
    -h | --help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 2 ;;
  esac
done

[ -n "$PROJECT" ] || { echo "error: --project is required" >&2; usage 2; }
command -v gcloud >/dev/null || { echo "error: gcloud is required" >&2; exit 1; }
for m in "${IAP_MEMBERS[@]}"; do
  [[ "$m" =~ ^(user|group|serviceAccount):[^@[:space:]]+@[^@[:space:]]+$ ]] ||
    { echo "error: --iap-member must look like user:<email> (got '$m')" >&2; exit 2; }
done

OWNER="${REPO%%/*}"
STATE_BUCKET="${PROJECT}-devbox-models-tfstate"
WEIGHTS_BUCKET="${PROJECT}-devbox-model-weights"
SA_DOMAIN="${PROJECT}.iam.gserviceaccount.com"
RUNTIME_SA="devbox-models-runtime@${SA_DOMAIN}"
PLAN_SA="devbox-models-plan@${SA_DOMAIN}"
DEPLOY_SA="devbox-models-deploy@${SA_DOMAIN}"
STAGE_SA="devbox-models-stage@${SA_DOMAIN}"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
g() { gcloud --project="$PROJECT" --quiet "$@"; }

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
WIF_POOL="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}"

# -----------------------------------------------------------------------------
say "Enabling APIs"
# -----------------------------------------------------------------------------
apis=(
  compute.googleapis.com iap.googleapis.com secretmanager.googleapis.com
  iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com
  cloudresourcemanager.googleapis.com logging.googleapis.com
  monitoring.googleapis.com storage.googleapis.com serviceusage.googleapis.com
)
[ -z "$BILLING_ACCOUNT" ] || apis+=(billingbudgets.googleapis.com cloudbilling.googleapis.com)
g services enable "${apis[@]}"

# -----------------------------------------------------------------------------
say "Buckets"
# -----------------------------------------------------------------------------
ensure_bucket() { # ensure_bucket <name>
  if ! g storage buckets describe "gs://$1" >/dev/null 2>&1; then
    g storage buckets create "gs://$1" --location="$REGION" \
      --default-storage-class=STANDARD --uniform-bucket-level-access \
      --public-access-prevention
  fi
  g storage buckets update "gs://$1" --uniform-bucket-level-access \
    --public-access-prevention --update-labels=app=devbox-models,managed-by=bootstrap
}
ensure_bucket "$STATE_BUCKET"
g storage buckets update "gs://$STATE_BUCKET" --versioning
ensure_bucket "$WEIGHTS_BUCKET"
# Weights are re-downloadable; soft delete would bill ~1 TB for a week every
# time a model is swapped.
g storage buckets update "gs://$WEIGHTS_BUCKET" --clear-soft-delete

# -----------------------------------------------------------------------------
say "Service accounts"
# -----------------------------------------------------------------------------
ensure_sa() { # ensure_sa <id> <display name>
  g iam service-accounts describe "$1@${SA_DOMAIN}" >/dev/null 2>&1 ||
    g iam service-accounts create "$1" --display-name="$2"
}
ensure_sa devbox-models-runtime "DevBox model VMs (runtime)"
ensure_sa devbox-models-plan "DevBox models CI: terraform plan"
ensure_sa devbox-models-deploy "DevBox models CI: terraform apply"
ensure_sa devbox-models-stage "DevBox models CI: stage weights"

project_role() { # project_role <member> <role> [condition-file]
  if [ -n "${3:-}" ]; then
    g projects add-iam-policy-binding "$PROJECT" --member="$1" --role="$2" \
      --condition-from-file="$3" >/dev/null
  else
    g projects add-iam-policy-binding "$PROJECT" --member="$1" --role="$2" \
      --condition=None >/dev/null
  fi
  echo "  $2 -> $1"
}
bucket_role() { # bucket_role <bucket> <member> <role>
  g storage buckets add-iam-policy-binding "gs://$1" --member="$2" --role="$3" >/dev/null
  echo "  $3 on gs://$1 -> $2"
}
sa_role() { # sa_role <sa email> <member> <role>
  # IAM is eventually consistent: a binding that names a service account or a
  # workload identity pool created seconds earlier can fail with
  # PERMISSION_DENIED "(or it may not exist)" until it propagates. Retry.
  local i err
  err="$(mktemp)"
  for i in 1 2 3 4 5 6; do
    if g iam service-accounts add-iam-policy-binding "$1" --member="$2" --role="$3" >/dev/null 2>"$err"; then
      echo "  $3 on $1 -> $2"
      rm -f "$err"
      return 0
    fi
    grep -q 'PERMISSION_DENIED\|NOT_FOUND\|does not exist' "$err" || break
    echo "  waiting for IAM to propagate (attempt ${i}/6)..." >&2
    sleep $((i * 10))
  done
  cat "$err" >&2
  rm -f "$err"
  return 1
}

# -----------------------------------------------------------------------------
say "Roles: deployer (terraform apply) — no Owner/Editor"
# -----------------------------------------------------------------------------
# compute.instanceAdmin.v1  create/update the VMs, their disks and their
#                           instance-level IAM (devboxModelsOperator, osLogin)
# compute.networkAdmin      VPC, subnet, Cloud Router, Cloud NAT
# compute.securityAdmin     the single IAP firewall rule (networkAdmin cannot)
# iam.roleAdmin             the two custom roles devboxModels{Operator,Lister}
# secretmanager.admin       the API-key secret, its versions and its IAM
# iap.admin                 per-instance IAP tunnel bindings
# serviceusage.serviceUsageConsumer
#                           the provider bills API quota to the project
#                           (user_project_override, needed by Budgets)
# resourcemanager.projectIamAdmin, CONDITIONED so it can only add/remove
#                           grants of logWriter, metricWriter and the lister
#                           custom role — not Owner, not anything else
# iam.serviceAccountUser    on the runtime SA ONLY (attach it to the VMs)
# iam.serviceAccountAdmin   on the runtime SA ONLY (break-glass SSH actAs grant)
# storage.objectUser        on the state bucket ONLY (state + lock objects)
DEPLOY="serviceAccount:${DEPLOY_SA}"
for r in roles/compute.instanceAdmin.v1 roles/compute.networkAdmin \
  roles/compute.securityAdmin roles/iam.roleAdmin roles/secretmanager.admin \
  roles/iap.admin roles/serviceusage.serviceUsageConsumer; do
  project_role "$DEPLOY" "$r"
done

cond="$(mktemp)"
trap 'rm -f "$cond"' EXIT
cat >"$cond" <<EOF
title: devbox-models-limited-grants
description: Only the roles infra/gcp-models grants at project level.
expression: >-
  api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly([
  'roles/logging.logWriter', 'roles/monitoring.metricWriter',
  'projects/${PROJECT}/roles/devboxModelsLister'])
EOF
project_role "$DEPLOY" roles/resourcemanager.projectIamAdmin "$cond"
sa_role "$RUNTIME_SA" "$DEPLOY" roles/iam.serviceAccountUser
sa_role "$RUNTIME_SA" "$DEPLOY" roles/iam.serviceAccountAdmin
bucket_role "$STATE_BUCKET" "$DEPLOY" roles/storage.objectUser

# -----------------------------------------------------------------------------
say "Roles: planner (terraform plan, runs on pull requests) — read-only"
# -----------------------------------------------------------------------------
# viewer + iam.securityReviewer  refresh every resource and its IAM policy
# serviceUsageConsumer           quota project (see above)
# storage.objectUser on state    read state, write the lock object
# Cannot read the API key: the provider does not read write-only secret data.
PLAN="serviceAccount:${PLAN_SA}"
for r in roles/viewer roles/iam.securityReviewer roles/serviceusage.serviceUsageConsumer; do
  project_role "$PLAN" "$r"
done
bucket_role "$STATE_BUCKET" "$PLAN" roles/storage.objectUser

# -----------------------------------------------------------------------------
say "Roles: weights"
# -----------------------------------------------------------------------------
bucket_role "$WEIGHTS_BUCKET" "serviceAccount:${STAGE_SA}" roles/storage.objectUser
bucket_role "$WEIGHTS_BUCKET" "serviceAccount:${RUNTIME_SA}" roles/storage.objectViewer

# -----------------------------------------------------------------------------
if [ -n "$BILLING_ACCOUNT" ]; then
  say "Roles: billing budget"
  # costsManager: create/update budgets on the billing account (deployer);
  # billing.viewer: refresh them during plan (planner). Needs Billing Admin.
  gcloud billing accounts add-iam-policy-binding "$BILLING_ACCOUNT" \
    --member="$DEPLOY" --role=roles/billing.costsManager >/dev/null
  gcloud billing accounts add-iam-policy-binding "$BILLING_ACCOUNT" \
    --member="$PLAN" --role=roles/billing.viewer >/dev/null
  project_role "$DEPLOY" roles/monitoring.notificationChannelEditor
  echo "  billing roles granted on $BILLING_ACCOUNT"
fi

# -----------------------------------------------------------------------------
say "Workload Identity Federation (GitHub OIDC, no JSON keys)"
# -----------------------------------------------------------------------------
g iam workload-identity-pools describe "$POOL_ID" --location=global >/dev/null 2>&1 ||
  g iam workload-identity-pools create "$POOL_ID" --location=global \
    --display-name="GitHub Actions"

# Only this repository, and only main or a pull request (fork PRs get no
# id-token at all). A token from any other branch is refused outright.
CONDITION="assertion.repository == '${REPO}' && assertion.repository_owner == '${OWNER}' && (assertion.ref == 'refs/heads/main' || assertion.event_name == 'pull_request')"
MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref,attribute.event_name=assertion.event_name"
if g iam workload-identity-pools providers describe "$PROVIDER_ID" \
  --location=global --workload-identity-pool="$POOL_ID" >/dev/null 2>&1; then
  g iam workload-identity-pools providers update-oidc "$PROVIDER_ID" \
    --location=global --workload-identity-pool="$POOL_ID" \
    --attribute-mapping="$MAPPING" --attribute-condition="$CONDITION"
else
  g iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
    --location=global --workload-identity-pool="$POOL_ID" \
    --display-name="${REPO}" --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="$MAPPING" --attribute-condition="$CONDITION"
fi

# planner: any job of the repo that passed the provider condition.
sa_role "$PLAN_SA" "principalSet://iam.googleapis.com/${WIF_POOL}/attribute.repository/${REPO}" \
  roles/iam.workloadIdentityUser
# deployer + stager: only jobs running in the protected GitHub environment
# (sub = repo:<owner>/<repo>:environment:gcp-models). The environment's
# required reviewers are the human approval gate for terraform apply.
ENV_SUBJECT="principal://iam.googleapis.com/${WIF_POOL}/subject/repo:${REPO}:environment:${ENVIRONMENT}"
sa_role "$DEPLOY_SA" "$ENV_SUBJECT" roles/iam.workloadIdentityUser
sa_role "$STAGE_SA" "$ENV_SUBJECT" roles/iam.workloadIdentityUser

# -----------------------------------------------------------------------------
say "Next steps"
# -----------------------------------------------------------------------------
members_json="[]"
if [ "${#IAP_MEMBERS[@]}" -gt 0 ]; then
  members_json="[$(printf '"%s",' "${IAP_MEMBERS[@]}" | sed 's/,$//')]"
fi
cat <<EOF

1. GitHub repository variables (not secrets — none of these are sensitive):

   gh variable set GCP_PROJECT_ID      --repo ${REPO} --body '${PROJECT}'
   gh variable set GCP_WIF_PROVIDER    --repo ${REPO} --body '${WIF_POOL}/providers/${PROVIDER_ID}'
   gh variable set GCP_PLAN_SA         --repo ${REPO} --body '${PLAN_SA}'
   gh variable set GCP_DEPLOY_SA       --repo ${REPO} --body '${DEPLOY_SA}'
   gh variable set GCP_STAGE_SA        --repo ${REPO} --body '${STAGE_SA}'
   gh variable set GCP_TF_STATE_BUCKET --repo ${REPO} --body '${STATE_BUCKET}'
   gh variable set GCP_IAP_MEMBERS     --repo ${REPO} --body '${members_json}'
EOF
if [ -n "$BILLING_ACCOUNT" ]; then
  cat <<EOF
   gh variable set GCP_BILLING_ACCOUNT    --repo ${REPO} --body '${BILLING_ACCOUNT}'
   gh variable set GCP_MONTHLY_BUDGET_USD --repo ${REPO} --body '500'
   gh variable set GCP_BUDGET_EMAILS      --repo ${REPO} --body '[]'
EOF
fi
cat <<EOF

2. GitHub environment '${ENVIRONMENT}' — the human gate for apply and staging.
   Create it, restrict it to the main branch, and add yourself as a required
   reviewer (Settings -> Environments), or:

   gh api -X PUT repos/${REPO}/environments/${ENVIRONMENT} --input - <<'JSON'
   {"reviewers":[{"type":"User","id":<your numeric GitHub user id>}],
    "deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false}}
   JSON

3. GPU quota — new projects have 0. a3-ultragpu-8g = 8 H200 per model VM.
   Request in ${REGION} (Console -> IAM & Admin -> Quotas, filter by metric):
     PREEMPTIBLE_NVIDIA_H200_GPUS   >= 8   (Spot; also used by Flex-start)
     NVIDIA_H200_GPUS               >= 8   (only for reservations)
   and globally GPUS_ALL_REGIONS >= 8. Raise to 16/24 only to run 2-3 models
   at once. Check current values with:
     gcloud compute regions describe ${REGION} --project=${PROJECT} \\
       --format="table(quotas.metric,quotas.limit,quotas.usage)" | grep -i h200

4. Open a pull request touching infra/gcp-models/ -> review the plan ->
   merge -> approve the '${ENVIRONMENT}' deployment. Then stage weights:
     gh workflow run gcp-models.yml --repo ${REPO} -f action=stage-weights -f model=coder
EOF
