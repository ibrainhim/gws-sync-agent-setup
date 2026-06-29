# OutThink Google Workspace Sync Agent — Setup

Deploy and manage the OutThink Google Workspace Sync Agent in your GCP project.

## Quick start

Click the button below. A pre-authenticated terminal opens in your browser inside your GCP project — no local tools needed.

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/open?cloudshell_git_repo=https://github.com/ibrainhim/gws-sync-agent-setup&cloudshell_tutorial=tutorial.md)

## What this does

The setup script creates the following in your GCP project:
- A service account (`outthink-sync-agent`) with minimal permissions
- A GCS bucket for checkpoint state
- A Cloud Run Job running the sync agent container
- A Cloud Scheduler trigger (every 12 hours)
- A Secret Manager secret for your OutThink SCIM token

After setup, you will receive a **Client ID** to give to your Google Workspace admin
to complete Domain-Wide Delegation.

## Ongoing operations

The same Cloud Shell button is your operations console. Open it any time to:
- Run a test sync (dry run)
- Trigger a manual sync
- Enable/disable debug logging
- View logs
- Rotate your SCIM token
- Uninstall

## Requirements

- A GCP project with billing enabled
- Owner or Editor role on the project
- A Google Workspace super-admin email for Domain-Wide Delegation
- OutThink Organisation ID and SCIM token (OutThink admin panel → Settings → SCIM Integration)
