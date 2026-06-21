#!/bin/bash
set -euo pipefail

# NOTE: Replace IMAGE with the real Artifact Registry path before production use.
IMAGE="gcr.io/cloudrun/hello"   # placeholder — swap with real image on first real deploy
JOB_NAME="outthink-sync-agent"
REGION="europe-west1"

PROJECT="${DEVSHELL_PROJECT_ID:-${GOOGLE_CLOUD_PROJECT:-$(gcloud config get-value project 2>/dev/null)}}"

if [ -z "$PROJECT" ]; then
  echo ""
  echo "No GCP project detected."
  echo "Run this first, then re-run setup:"
  echo ""
  echo "  gcloud config set project YOUR_PROJECT_ID"
  echo ""
  exit 1
fi

gcloud config set project "$PROJECT" --quiet
echo "Project: $PROJECT"
echo ""

# ── Guard: already deployed ─────────────────────────────────────────────────
if gcloud run jobs describe "$JOB_NAME" --region="$REGION" --project="$PROJECT" &>/dev/null; then
  echo "⚠  The agent is already deployed in this project."
  echo "   Use the Operations pages in this tutorial for ongoing tasks"
  echo "   (manual sync, debug mode, logs, token rotation, etc.)."
  echo ""
  exit 0
fi

# ── Collect inputs ──────────────────────────────────────────────────────────
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
ORG_ID="${OUTTHINK_ORG_ID:-}"
SCIM_TOKEN="${OUTTHINK_SCIM_TOKEN:-}"
OUTTHINK_REGION="${OUTTHINK_REGION:-eu}"

[ -z "$ADMIN_EMAIL" ] && read -rp  "Google Workspace admin email: " ADMIN_EMAIL
[ -z "$ORG_ID" ]      && read -rp  "OutThink Organisation ID: " ORG_ID
[ -z "$SCIM_TOKEN" ]  && read -rsp "OutThink SCIM token: " SCIM_TOKEN && echo

case "$OUTTHINK_REGION" in
  us) SCIM_BASE_URL="https://us.api.outthink.io/scim/Organizations/${ORG_ID}/v2" ;;
  *)  SCIM_BASE_URL="https://api.outthink.io/scim/Organizations/${ORG_ID}/v2" ;;
esac

# ── Enable required APIs ────────────────────────────────────────────────────
echo ""
echo "Enabling required APIs..."
gcloud services enable \
  admin.googleapis.com \
  storage.googleapis.com \
  run.googleapis.com \
  cloudscheduler.googleapis.com \
  iamcredentials.googleapis.com \
  secretmanager.googleapis.com \
  --project="$PROJECT" --quiet
echo "✓ APIs enabled"

# ── Create service account ──────────────────────────────────────────────────
SA_NAME="outthink-sync-agent"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT" &>/dev/null; then
  echo "✓ Service account already exists — skipping"
else
  echo "Creating service account..."
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="OutThink Workspace Sync Agent" \
    --project="$PROJECT"
  echo "✓ Service account created: $SA_EMAIL"
fi

# ── Create checkpoint bucket ────────────────────────────────────────────────
BUCKET="${PROJECT}-outthink-sync-checkpoint"

if gsutil ls "gs://${BUCKET}" &>/dev/null; then
  echo "✓ Checkpoint bucket already exists — skipping"
else
  echo "Creating checkpoint bucket..."
  gsutil mb -p "$PROJECT" "gs://${BUCKET}"
  echo "✓ Bucket created: gs://${BUCKET}"
fi

gsutil iam ch "serviceAccount:${SA_EMAIL}:roles/storage.objectUser" "gs://${BUCKET}"
echo "✓ Bucket permissions set"

# ── Store SCIM token in Secret Manager ─────────────────────────────────────
echo "Storing SCIM token in Secret Manager..."
if gcloud secrets describe outthink-scim-token --project="$PROJECT" &>/dev/null; then
  echo -n "$SCIM_TOKEN" | gcloud secrets versions add outthink-scim-token \
    --data-file=- --project="$PROJECT"
else
  echo -n "$SCIM_TOKEN" | gcloud secrets create outthink-scim-token \
    --data-file=- --project="$PROJECT"
fi
gcloud secrets add-iam-policy-binding outthink-scim-token \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" \
  --project="$PROJECT" --quiet
echo "✓ SCIM token stored in Secret Manager"

# ── Deploy Cloud Run Job ────────────────────────────────────────────────────
echo "Deploying Cloud Run Job..."
gcloud run jobs deploy "$JOB_NAME" \
  --image="$IMAGE" \
  --region="$REGION" \
  --service-account="$SA_EMAIL" \
  --set-env-vars="SCIM_BASE_URL=${SCIM_BASE_URL},GOOGLE_ADMIN_EMAIL=${ADMIN_EMAIL},GCP_SERVICE_ACCOUNT=${SA_EMAIL},CHECKPOINT_BUCKET=${BUCKET},STORAGE_PROVIDER=gcs,LOG_LEVEL=INFO,DRY_RUN=false" \
  --set-secrets="SCIM_TOKEN=outthink-scim-token:latest" \
  --project="$PROJECT"
echo "✓ Cloud Run Job deployed"

# ── Create Cloud Scheduler trigger ─────────────────────────────────────────
echo "Setting up Cloud Scheduler (every 12 hours)..."
gcloud scheduler jobs create http "${JOB_NAME}-sync" \
  --location="$REGION" \
  --schedule="0 */12 * * *" \
  --uri="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT}/jobs/${JOB_NAME}:run" \
  --oauth-service-account-email="$SA_EMAIL" \
  --project="$PROJECT" 2>/dev/null || echo "✓ Scheduler already exists — skipping"
echo "✓ Cloud Scheduler configured"

# ── Print client ID ─────────────────────────────────────────────────────────
CLIENT_ID=$(gcloud iam service-accounts describe "$SA_EMAIL" \
  --format="value(oauth2ClientId)" --project="$PROJECT")

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ✓ Setup complete."
echo ""
echo "  FINAL STEP — Domain-Wide Delegation"
echo "  Send this to your Google Workspace admin:"
echo ""
echo "  Client ID : $CLIENT_ID"
echo "  Scopes    : https://www.googleapis.com/auth/admin.directory.user.readonly,"
echo "              https://www.googleapis.com/auth/admin.reports.audit.readonly"
echo ""
echo "  Instructions: admin.google.com → Security → API controls"
echo "                → Domain-wide delegation → Add new"
echo "════════════════════════════════════════════════════════════"
