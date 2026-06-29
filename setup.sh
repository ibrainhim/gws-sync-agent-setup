#!/bin/bash
set -euo pipefail

JOB_NAME="outthink-sync-agent"
REGION="europe-west1"
AR_REPO="outthink-sync-agent"

# ── Required inputs ──────────────────────────────────────────────────────────
: "${GCP_PROJECT:?GCP_PROJECT is required}"
: "${ADMIN_EMAIL:?ADMIN_EMAIL is required (Google Workspace super-admin email)}"
: "${SCIM_BASE_URL:?SCIM_BASE_URL is required (OutThink SCIM endpoint)}"
: "${SCIM_TOKEN:?SCIM_TOKEN is required (OutThink SCIM bearer token)}"

PROJECT="$GCP_PROJECT"

SA_NAME="outthink-sync-agent"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
BUCKET="${PROJECT}-outthink-sync-checkpoint"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${AR_REPO}/agent:latest"

gcloud config set project "$PROJECT" --quiet

echo "──────────────────────────────────────────────────────"
echo "  OutThink GWS Sync Agent — setup"
echo "  Project : $PROJECT"
echo "  Region  : $REGION"
echo "──────────────────────────────────────────────────────"

# ── Preflight: billing must be enabled ───────────────────────────────────────
BILLING_ENABLED=$(gcloud billing projects describe "$PROJECT" \
  --format="value(billingEnabled)" 2>/dev/null || echo "False")
if [[ "$BILLING_ENABLED" != "True" ]]; then
  echo ""
  echo "ERROR: Billing is not enabled on project '$PROJECT'."
  echo "  Enable it at:"
  echo "  https://console.cloud.google.com/billing/linkedaccount?project=${PROJECT}"
  echo ""
  exit 1
fi
echo "✓ Billing enabled"

# ── Enable required APIs ──────────────────────────────────────────────────────
echo "Enabling required APIs..."
gcloud services enable \
  admin.googleapis.com \
  storage.googleapis.com \
  run.googleapis.com \
  cloudscheduler.googleapis.com \
  iamcredentials.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  --project="$PROJECT" --quiet
echo "✓ APIs enabled"

# ── Service account ───────────────────────────────────────────────────────────
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT" &>/dev/null; then
  echo "✓ Service account already exists — skipping"
else
  echo "Creating service account..."
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="OutThink Workspace Sync Agent" \
    --project="$PROJECT"
  echo "✓ Service account created: $SA_EMAIL"
fi

# Allow the SA to sign tokens for itself (required for DWD credential exchange)
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project="$PROJECT" --quiet

gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/logging.logWriter" --quiet

echo "✓ Service account permissions set"

# ── Checkpoint bucket ─────────────────────────────────────────────────────────
if gsutil ls "gs://${BUCKET}" &>/dev/null; then
  echo "✓ Checkpoint bucket already exists — skipping"
else
  echo "Creating checkpoint bucket..."
  gcloud storage buckets create "gs://${BUCKET}" \
    --location="$REGION" \
    --uniform-bucket-level-access \
    --project="$PROJECT" --quiet
  echo "✓ Bucket created: gs://${BUCKET}"
fi

gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin" --quiet
echo "✓ Bucket permissions set"

# ── SCIM token in Secret Manager ─────────────────────────────────────────────
if gcloud secrets describe outthink-scim-token --project="$PROJECT" &>/dev/null; then
  echo -n "$SCIM_TOKEN" | gcloud secrets versions add outthink-scim-token \
    --data-file=- --project="$PROJECT" --quiet
  echo "✓ SCIM token updated in Secret Manager"
else
  echo -n "$SCIM_TOKEN" | gcloud secrets create outthink-scim-token \
    --data-file=- \
    --replication-policy=automatic \
    --project="$PROJECT" --quiet
  echo "✓ SCIM token stored in Secret Manager"
fi

gcloud secrets add-iam-policy-binding outthink-scim-token \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" \
  --project="$PROJECT" --quiet

# ── Artifact Registry ─────────────────────────────────────────────────────────
if gcloud artifacts repositories describe "$AR_REPO" \
    --location="$REGION" --project="$PROJECT" &>/dev/null; then
  echo "✓ Artifact Registry repository already exists — skipping"
else
  echo "Creating Artifact Registry repository..."
  gcloud artifacts repositories create "$AR_REPO" \
    --repository-format=docker \
    --location="$REGION" \
    --description="OutThink GWS Sync Agent container images" \
    --project="$PROJECT" --quiet
  echo "✓ Artifact Registry repository created"
fi

gcloud artifacts repositories add-iam-policy-binding "$AR_REPO" \
  --location="$REGION" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/artifactregistry.reader" \
  --project="$PROJECT" --quiet
echo "✓ Artifact Registry permissions set"

# ── Cloud Run Job ─────────────────────────────────────────────────────────────
echo "Deploying Cloud Run Job..."
gcloud run jobs deploy "$JOB_NAME" \
  --image="$IMAGE" \
  --region="$REGION" \
  --service-account="$SA_EMAIL" \
  --task-timeout=14400s \
  --set-env-vars="SCIM_BASE_URL=${SCIM_BASE_URL},GOOGLE_ADMIN_EMAIL=${ADMIN_EMAIL},GCP_SERVICE_ACCOUNT=${SA_EMAIL},CHECKPOINT_BUCKET=${BUCKET},STORAGE_PROVIDER=gcs,LOG_LEVEL=INFO,DRY_RUN=false,SYNC_INTERVAL_HOURS=12,RECONCILIATION_INTERVAL_HOURS=24,LOCK_STALE_THRESHOLD_SECONDS=7200" \
  --set-secrets="SCIM_TOKEN=outthink-scim-token:latest" \
  --project="$PROJECT" --quiet
echo "✓ Cloud Run Job deployed"

# ── Cloud Scheduler ───────────────────────────────────────────────────────────
SCHEDULER_JOB="${JOB_NAME}-scheduler"
if gcloud scheduler jobs describe "$SCHEDULER_JOB" \
    --location="$REGION" --project="$PROJECT" &>/dev/null; then
  echo "✓ Cloud Scheduler already configured — skipping"
else
  echo "Setting up Cloud Scheduler (every 2 hours)..."
  gcloud scheduler jobs create http "$SCHEDULER_JOB" \
    --location="$REGION" \
    --schedule="0 */2 * * *" \
    --uri="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT}/jobs/${JOB_NAME}:run" \
    --oauth-service-account-email="$SA_EMAIL" \
    --project="$PROJECT" --quiet
  echo "✓ Cloud Scheduler configured"
fi

# ── Print client ID for DWD ───────────────────────────────────────────────────
CLIENT_ID=$(gcloud iam service-accounts describe "$SA_EMAIL" \
  --format="value(oauth2ClientId)" --project="$PROJECT")

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ✓ Setup complete."
echo ""
echo "  STEP 1 — Build and push the container image"
echo ""
echo "  gcloud auth configure-docker ${REGION}-docker.pkg.dev"
echo "  docker build -t ${IMAGE} ."
echo "  docker push ${IMAGE}"
echo ""
echo "  Then update the job with the pushed image:"
echo "  gcloud run jobs update ${JOB_NAME} \\"
echo "    --image=${IMAGE} \\"
echo "    --region=${REGION} --project=${PROJECT}"
echo ""
echo "  STEP 2 — Domain-Wide Delegation"
echo "  Send this to your Google Workspace admin:"
echo ""
echo "  Client ID : $CLIENT_ID"
echo "  Scopes    : https://www.googleapis.com/auth/admin.directory.user.readonly,"
echo "              https://www.googleapis.com/auth/admin.directory.group.readonly,"
echo "              https://www.googleapis.com/auth/admin.directory.group.member.readonly,"
echo "              https://www.googleapis.com/auth/admin.reports.audit.readonly"
echo ""
echo "  Instructions: admin.google.com → Security → API controls"
echo "                → Domain-wide delegation → Add new"
echo ""
echo "  STEP 3 — Verify auth chain"
echo "  gcloud run jobs execute ${JOB_NAME} \\"
echo "    --region=${REGION} --project=${PROJECT} \\"
echo "    --args=check-auth"
echo "════════════════════════════════════════════════════════════"
