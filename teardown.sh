#!/bin/bash
set -euo pipefail

JOB_NAME="outthink-sync-agent"
REGION="europe-west1"

# ── Colors & UI helpers ───────────────────────────────────────────────────────
RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; WHITE='\033[97m'

ok()      { echo -e "  ${GREEN}✓${RESET}  $1"; }
skipped() { echo -e "  ${DIM}·${RESET}  ${DIM}$1 (not found — skipping)${RESET}"; }
fail()    { echo -e "  ${RED}✗${RESET}  ${RED}$1${RESET}"; }
section() {
  echo ""
  echo -e "  ${BOLD}${WHITE}$1${RESET}"
  echo -e "  ${DIM}$(printf '%.0s─' {1..48})${RESET}"
}

# ── Parse CLI flags ───────────────────────────────────────────────────────────
DELETE_BUCKET=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --gcp-project)    GCP_PROJECT="$2"; shift 2 ;;
    --region)         REGION="$2";      shift 2 ;;
    --delete-bucket)  DELETE_BUCKET=true; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

: "${GCP_PROJECT:?--gcp-project is required}"

PROJECT="$GCP_PROJECT"
SA_NAME="outthink-sync-agent"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
BUCKET="${PROJECT}-outthink-sync-checkpoint"
SCHEDULER_JOB="${JOB_NAME}-scheduler"

gcloud config set project "$PROJECT" --quiet 2>/dev/null

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}${WHITE}╭─────────────────────────────────────────────────╮${RESET}"
echo -e "  ${BOLD}${WHITE}│                                                 │${RESET}"
echo -e "  ${BOLD}${WHITE}│   OutThink  ·  GWS Sync Agent  ·  Teardown     │${RESET}"
echo -e "  ${BOLD}${WHITE}│                                                 │${RESET}"
echo -e "  ${BOLD}${WHITE}╰─────────────────────────────────────────────────╯${RESET}"
echo ""
echo -e "  ${DIM}Project   ${RESET}${CYAN}${PROJECT}${RESET}"
echo -e "  ${DIM}Region    ${RESET}${CYAN}${REGION}${RESET}"
echo ""
echo -e "  ${YELLOW}This will permanently delete the sync agent and all its GCP resources.${RESET}"
echo ""
read -rp "  Type the project ID to confirm: " CONFIRM
if [[ "$CONFIRM" != "$PROJECT" ]]; then
  fail "Confirmation did not match. Aborting."
  exit 1
fi

# ── Cloud Scheduler ───────────────────────────────────────────────────────────
section "Cloud Scheduler"

if gcloud scheduler jobs describe "$SCHEDULER_JOB" \
    --location="$REGION" --project="$PROJECT" &>/dev/null; then
  gcloud scheduler jobs delete "$SCHEDULER_JOB" \
    --location="$REGION" --project="$PROJECT" --quiet
  ok "Deleted scheduler job"
else
  skipped "$SCHEDULER_JOB"
fi

# ── Cloud Run Job ─────────────────────────────────────────────────────────────
section "Cloud Run Job"

if gcloud run jobs describe "$JOB_NAME" \
    --region="$REGION" --project="$PROJECT" &>/dev/null; then
  gcloud run jobs delete "$JOB_NAME" \
    --region="$REGION" --project="$PROJECT" --quiet
  ok "Deleted Cloud Run Job"
else
  skipped "$JOB_NAME"
fi

# ── Secrets ───────────────────────────────────────────────────────────────────
section "Secrets"

for secret in outthink-scim-token outthink-agent-key; do
  if gcloud secrets describe "$secret" --project="$PROJECT" &>/dev/null; then
    gcloud secrets delete "$secret" --project="$PROJECT" --quiet
    ok "Deleted secret: $secret"
  else
    skipped "$secret"
  fi
done

# ── Checkpoint bucket ─────────────────────────────────────────────────────────
section "Checkpoint Bucket"

if gsutil ls "gs://${BUCKET}" &>/dev/null; then
  if [[ "$DELETE_BUCKET" == "true" ]]; then
    gsutil -m rm -r "gs://${BUCKET}" 2>/dev/null || true
    gcloud storage buckets delete "gs://${BUCKET}" --project="$PROJECT" --quiet
    ok "Deleted gs://${BUCKET}"
  else
    echo -e "  ${YELLOW}·${RESET}  ${YELLOW}gs://${BUCKET} contains checkpoint data — skipped${RESET}"
    echo -e "  ${DIM}   Re-run with --delete-bucket to remove it${RESET}"
  fi
else
  skipped "gs://${BUCKET}"
fi

# ── Service account ───────────────────────────────────────────────────────────
section "Service Account"

if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT" &>/dev/null; then
  # Remove project-level IAM binding first
  gcloud projects remove-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/logging.logWriter" --quiet 2>/dev/null || true

  gcloud iam service-accounts delete "$SA_EMAIL" \
    --project="$PROJECT" --quiet
  ok "Deleted service account"
else
  skipped "$SA_EMAIL"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${GREEN}${BOLD}╭─────────────────────────────────────────────────╮${RESET}"
echo -e "  ${GREEN}${BOLD}│   ✓  Teardown complete                          │${RESET}"
echo -e "  ${GREEN}${BOLD}╰─────────────────────────────────────────────────╯${RESET}"
echo ""
