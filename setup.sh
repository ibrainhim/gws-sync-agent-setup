#!/bin/bash
set -euo pipefail

JOB_NAME="outthink-sync-agent"
REGION="europe-west1"
IMAGE="europe-docker.pkg.dev/outthink-platform/gws-sync-agent/agent:latest"

# ── Colors & UI helpers ───────────────────────────────────────────────────────
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
WHITE='\033[97m'

ok()   { echo -e "  ${GREEN}✓${RESET}  $1"; }
fail() { echo -e "  ${RED}✗${RESET}  ${RED}$1${RESET}"; }
info() { echo -e "  ${DIM}·${RESET}  ${DIM}$1${RESET}"; }
section() {
  echo ""
  echo -e "  ${BOLD}${WHITE}$1${RESET}"
  echo -e "  ${DIM}$(printf '%.0s─' {1..48})${RESET}"
}

# ── Parse CLI flags ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --gcp-project)    GCP_PROJECT="$2";                    shift 2 ;;
    --admin-email)    ADMIN_EMAIL="$2";                    shift 2 ;;
    --org-id)         OUTTHINK_ORG_ID="$2";                shift 2 ;;
    --scim-token)     SCIM_TOKEN="$2";                     shift 2 ;;
    --sync-interval)  SYNC_INTERVAL_HOURS="$2";            shift 2 ;;
    --recon-interval) RECONCILIATION_INTERVAL_HOURS="$2";  shift 2 ;;
    --log-level)      LOG_LEVEL="$2";                      shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Required inputs ───────────────────────────────────────────────────────────
: "${GCP_PROJECT:?--gcp-project is required}"
: "${ADMIN_EMAIL:?--admin-email is required}"
: "${OUTTHINK_ORG_ID:?--org-id is required}"
: "${SCIM_TOKEN:?--scim-token is required}"

# ── Optional inputs with defaults ─────────────────────────────────────────────
SYNC_INTERVAL_HOURS="${SYNC_INTERVAL_HOURS:-12}"
RECONCILIATION_INTERVAL_HOURS="${RECONCILIATION_INTERVAL_HOURS:-24}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

SCIM_BASE_URL="https://api.outthink.io/scim/Organizations/${OUTTHINK_ORG_ID}/v2"
PROJECT="$GCP_PROJECT"
SA_NAME="outthink-sync-agent"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
BUCKET="${PROJECT}-outthink-sync-checkpoint"

gcloud config set project "$PROJECT" --quiet 2>/dev/null

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}${WHITE}╭─────────────────────────────────────────────────╮${RESET}"
echo -e "  ${BOLD}${WHITE}│                                                 │${RESET}"
echo -e "  ${BOLD}${WHITE}│   OutThink  ·  GWS Sync Agent  ·  Setup        │${RESET}"
echo -e "  ${BOLD}${WHITE}│                                                 │${RESET}"
echo -e "  ${BOLD}${WHITE}╰─────────────────────────────────────────────────╯${RESET}"
echo ""
echo -e "  ${DIM}Project   ${RESET}${CYAN}${PROJECT}${RESET}"
echo -e "  ${DIM}Region    ${RESET}${CYAN}${REGION}${RESET}"
echo -e "  ${DIM}Org       ${RESET}${CYAN}${OUTTHINK_ORG_ID}${RESET}"

# ── Billing ───────────────────────────────────────────────────────────────────
section "Preflight"

BILLING_ENABLED=$(gcloud billing projects describe "$PROJECT" \
  --format="value(billingEnabled)" 2>/dev/null || echo "False")
if [[ "$BILLING_ENABLED" != "True" ]]; then
  fail "Billing is not enabled on project '${PROJECT}'"
  echo ""
  echo -e "  ${YELLOW}Enable it at:${RESET}"
  echo -e "  ${DIM}https://console.cloud.google.com/billing/linkedaccount?project=${PROJECT}${RESET}"
  echo ""
  exit 1
fi
ok "Billing enabled"

# ── APIs ──────────────────────────────────────────────────────────────────────
section "Enabling APIs"

gcloud services enable \
  admin.googleapis.com \
  storage.googleapis.com \
  run.googleapis.com \
  cloudscheduler.googleapis.com \
  iamcredentials.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  --project="$PROJECT" --quiet
ok "All APIs enabled"

# ── Service account ───────────────────────────────────────────────────────────
section "Service Account"

if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT" &>/dev/null; then
  info "Already exists — skipping creation"
else
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="OutThink Workspace Sync Agent" \
    --project="$PROJECT" --quiet
  ok "Created ${SA_EMAIL}"
fi

gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project="$PROJECT" --quiet

gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/logging.logWriter" --quiet

ok "IAM roles assigned"

# ── Checkpoint bucket ─────────────────────────────────────────────────────────
section "Checkpoint Bucket"

if gsutil ls "gs://${BUCKET}" &>/dev/null; then
  info "Already exists — skipping creation"
else
  gcloud storage buckets create "gs://${BUCKET}" \
    --location="$REGION" \
    --uniform-bucket-level-access \
    --project="$PROJECT" --quiet
  ok "Created gs://${BUCKET}"
fi

gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin" --quiet
ok "Permissions set"

# ── Secret Manager ────────────────────────────────────────────────────────────
section "SCIM Token"

if gcloud secrets describe outthink-scim-token --project="$PROJECT" &>/dev/null; then
  echo -n "$SCIM_TOKEN" | gcloud secrets versions add outthink-scim-token \
    --data-file=- --project="$PROJECT" --quiet
  ok "Token updated in Secret Manager"
else
  echo -n "$SCIM_TOKEN" | gcloud secrets create outthink-scim-token \
    --data-file=- \
    --replication-policy=automatic \
    --project="$PROJECT" --quiet
  ok "Token stored in Secret Manager"
fi

gcloud secrets add-iam-policy-binding outthink-scim-token \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" \
  --project="$PROJECT" --quiet

# ── Cloud Run Job ─────────────────────────────────────────────────────────────
section "Cloud Run Job"

gcloud run jobs deploy "$JOB_NAME" \
  --image="$IMAGE" \
  --region="$REGION" \
  --service-account="$SA_EMAIL" \
  --task-timeout=14400s \
  --set-env-vars="SCIM_BASE_URL=${SCIM_BASE_URL},GOOGLE_ADMIN_EMAIL=${ADMIN_EMAIL},GCP_SERVICE_ACCOUNT=${SA_EMAIL},CHECKPOINT_BUCKET=${BUCKET},STORAGE_PROVIDER=gcs,LOG_LEVEL=${LOG_LEVEL},DRY_RUN=false,SYNC_INTERVAL_HOURS=${SYNC_INTERVAL_HOURS},RECONCILIATION_INTERVAL_HOURS=${RECONCILIATION_INTERVAL_HOURS},LOCK_STALE_THRESHOLD_SECONDS=7200" \
  --set-secrets="SCIM_TOKEN=outthink-scim-token:latest" \
  --project="$PROJECT" --quiet
ok "Job deployed"

# ── Cloud Scheduler ───────────────────────────────────────────────────────────
section "Cloud Scheduler"

SCHEDULER_JOB="${JOB_NAME}-scheduler"
if gcloud scheduler jobs describe "$SCHEDULER_JOB" \
    --location="$REGION" --project="$PROJECT" &>/dev/null; then
  info "Already configured — skipping"
else
  gcloud scheduler jobs create http "$SCHEDULER_JOB" \
    --location="$REGION" \
    --schedule="0 */${SYNC_INTERVAL_HOURS} * * *" \
    --uri="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT}/jobs/${JOB_NAME}:run" \
    --oauth-service-account-email="$SA_EMAIL" \
    --project="$PROJECT" --quiet
  ok "Trigger set (every ${SYNC_INTERVAL_HOURS}h)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
CLIENT_ID=$(gcloud iam service-accounts describe "$SA_EMAIL" \
  --format="value(oauth2ClientId)" --project="$PROJECT")

echo ""
echo -e "  ${GREEN}${BOLD}╭─────────────────────────────────────────────────╮${RESET}"
echo -e "  ${GREEN}${BOLD}│   ✓  Setup complete                             │${RESET}"
echo -e "  ${GREEN}${BOLD}╰─────────────────────────────────────────────────╯${RESET}"

section "Step 1 — Domain-Wide Delegation"
echo -e "  Send these to your Google Workspace admin:"
echo ""
echo -e "  ${BOLD}Client ID${RESET}  ${CYAN}${CLIENT_ID}${RESET}"
echo ""
echo -e "  ${BOLD}Scopes${RESET}"
echo -e "  ${DIM}https://www.googleapis.com/auth/admin.directory.user.readonly${RESET}"
echo -e "  ${DIM}https://www.googleapis.com/auth/admin.directory.group.readonly${RESET}"
echo -e "  ${DIM}https://www.googleapis.com/auth/admin.directory.group.member.readonly${RESET}"
echo -e "  ${DIM}https://www.googleapis.com/auth/admin.reports.audit.readonly${RESET}"
echo ""
echo -e "  ${DIM}admin.google.com → Security → API controls → Domain-wide delegation → Add new${RESET}"

section "Step 2 — Verify"
echo -e "  ${DIM}gcloud run jobs execute ${JOB_NAME} \\${RESET}"
echo -e "  ${DIM}  --region=${REGION} --project=${PROJECT} \\${RESET}"
echo -e "  ${DIM}  --args=check-auth${RESET}"
echo ""
