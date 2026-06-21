#!/bin/bash
set -euo pipefail

JOB_NAME="outthink-sync-agent"
REGION="europe-west1"
PROJECT=$(gcloud config get-value project)
COMMAND="${1:-help}"

case "$COMMAND" in

  test)
    echo "Running test sync (dry run — no changes will be written to OutThink)..."
    gcloud run jobs update "$JOB_NAME" \
      --update-env-vars DRY_RUN=true \
      --region="$REGION" --project="$PROJECT" --quiet
    gcloud run jobs execute "$JOB_NAME" \
      --region="$REGION" --project="$PROJECT" --wait
    gcloud run jobs update "$JOB_NAME" \
      --update-env-vars DRY_RUN=false \
      --region="$REGION" --project="$PROJECT" --quiet
    echo "Test complete. No changes were written to OutThink."
    ;;

  sync)
    echo "Triggering manual sync..."
    gcloud run jobs execute "$JOB_NAME" \
      --region="$REGION" --project="$PROJECT" --wait
    echo "Sync complete."
    ;;

  debug-on)
    gcloud run jobs update "$JOB_NAME" \
      --update-env-vars LOG_LEVEL=DEBUG \
      --region="$REGION" --project="$PROJECT" --quiet
    echo "Debug logging enabled. Run 'bash ops.sh logs' to view output."
    echo "Remember to run 'bash ops.sh debug-off' when done."
    ;;

  debug-off)
    gcloud run jobs update "$JOB_NAME" \
      --update-env-vars LOG_LEVEL=INFO \
      --region="$REGION" --project="$PROJECT" --quiet
    echo "Log level restored to INFO."
    ;;

  logs)
    FOLLOW="${2:-}"
    if [ "$FOLLOW" = "--follow" ]; then
      gcloud beta run jobs executions logs tail \
        --job="$JOB_NAME" --region="$REGION" --project="$PROJECT"
    else
      gcloud logging read \
        "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${JOB_NAME}\"" \
        --limit=50 --project="$PROJECT" \
        --format="table(timestamp, textPayload)"
    fi
    ;;

  status)
    echo "Recent executions:"
    gcloud run jobs executions list \
      --job="$JOB_NAME" --region="$REGION" --project="$PROJECT" \
      --format="table(name, completionTime, succeeded, failed)"
    ;;

  rotate-token)
    read -rsp "New SCIM token: " NEW_TOKEN && echo
    echo -n "$NEW_TOKEN" | gcloud secrets versions add outthink-scim-token \
      --data-file=- --project="$PROJECT"
    echo "Token updated. Agent picks it up on next execution."
    ;;

  update-admin)
    read -rp "New Google Workspace admin email: " NEW_ADMIN
    gcloud run jobs update "$JOB_NAME" \
      --update-env-vars "GOOGLE_ADMIN_EMAIL=${NEW_ADMIN}" \
      --region="$REGION" --project="$PROJECT" --quiet
    echo "Admin email updated to: $NEW_ADMIN"
    ;;

  uninstall)
    read -rp "This will delete the agent and all checkpoint state. Type 'yes' to confirm: " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then echo "Cancelled."; exit 0; fi
    gcloud run jobs delete "$JOB_NAME" --region="$REGION" --project="$PROJECT" --quiet
    gcloud scheduler jobs delete "${JOB_NAME}-sync" \
      --location="$REGION" --project="$PROJECT" --quiet 2>/dev/null || true
    BUCKET="${PROJECT}-outthink-sync-checkpoint"
    gsutil -m rm -r "gs://${BUCKET}" 2>/dev/null || true
    gcloud iam service-accounts delete \
      "outthink-sync-agent@${PROJECT}.iam.gserviceaccount.com" \
      --project="$PROJECT" --quiet 2>/dev/null || true
    echo "Agent uninstalled."
    ;;

  help|*)
    echo "Usage: bash ops.sh <command>"
    echo ""
    echo "Commands:"
    echo "  test           Dry-run sync — reads Workspace, logs what would change, writes nothing"
    echo "  sync           Trigger an immediate live sync"
    echo "  debug-on       Raise log level to DEBUG"
    echo "  debug-off      Restore log level to INFO"
    echo "  logs           Show last 50 log lines"
    echo "  logs --follow  Stream logs from a running execution"
    echo "  status         Show recent job execution history"
    echo "  rotate-token   Update the SCIM token in Secret Manager"
    echo "  update-admin   Update the Google Workspace admin email"
    echo "  uninstall      Remove all agent resources (irreversible)"
    ;;

esac
