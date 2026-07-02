# OutThink Google Workspace Sync Agent — Customer Guide

## What this is

The OutThink Google Workspace Sync Agent runs inside your own Google Cloud project and
syncs your Workspace user directory to OutThink every 2 hours. It uses no always-on
servers — it wakes up on a schedule, does its work, and stops. OutThink never has access
to your GCP project or your Workspace directory.

---

## Requirements

Before starting, you will need:

- A Google Cloud project with billing enabled
- Owner or Editor role on that project
- A Google Workspace super-admin account on your domain
- Your OutThink Agent Key (OutThink dashboard → Settings → Integrations → Google Workspace)

---

## Setup

Click the **Open in Cloud Shell** button on the repository page. A browser terminal opens
inside your GCP project — no local tools needed.

When the terminal is ready, run:

```bash
curl -fsSL https://raw.githubusercontent.com/ibrainhim/gws-sync-agent-setup/main/setup.sh | bash -s -- \
  --gcp-project YOUR_PROJECT_ID \
  --admin-email admin@yourdomain.com \
  --agent-key YOUR_AGENT_KEY \
  --region europe-west1
```

Replace `YOUR_PROJECT_ID`, `admin@yourdomain.com`, and `YOUR_AGENT_KEY` with your values.
`--region` is optional and defaults to `europe-west1`.

The script creates everything automatically. At the end it prints a **Client ID** — you
will need this for the next step.

**Grant Workspace access (one-time manual step)**

The agent reads your Workspace directory via Domain-Wide Delegation. Your Google Workspace
super-admin needs to authorise this once:

1. Go to [Google Admin](https://admin.google.com) → Security → API controls → Domain-wide delegation
2. Click **Add new**
3. Enter the Client ID printed by the setup script
4. Paste these scopes (all on one line):

```
https://www.googleapis.com/auth/admin.directory.user.readonly,https://www.googleapis.com/auth/admin.directory.group.readonly,https://www.googleapis.com/auth/admin.directory.group.member.readonly,https://www.googleapis.com/auth/admin.reports.audit.readonly
```

5. Click **Authorize**

The first sync runs within 2 hours of completing this step.

---

## Operations

To trigger a manual sync or check status, open Cloud Shell:

| Task | Command |
|---|---|
| Trigger a sync immediately | `gcloud run jobs execute outthink-sync-agent --region=REGION --project=PROJECT` |
| View recent logs | `gcloud logging read 'resource.labels.job_name="outthink-sync-agent"' --project=PROJECT --limit=50` |
| Check job execution status | `gcloud run jobs executions list --job=outthink-sync-agent --region=REGION --project=PROJECT` |

---

## Removing all resources

To fully remove the sync agent from your GCP project, open Cloud Shell and run:

```bash
curl -fsSL https://raw.githubusercontent.com/ibrainhim/gws-sync-agent-setup/main/teardown.sh | bash -s -- \
  --gcp-project YOUR_PROJECT_ID \
  --agent-key YOUR_AGENT_KEY \
  --region europe-west1
```

Type your project ID when prompted to confirm. The script removes:

- The Cloud Run Job (`outthink-sync-agent`)
- The Cloud Scheduler trigger
- The service account (`outthink-sync-agent@YOUR_PROJECT.iam.gserviceaccount.com`)
- The agent key stored in Secret Manager (`outthink-agent-key`)

**The checkpoint bucket is kept by default** to preserve sync history. To delete it as well, add `--delete-bucket`:

```bash
curl -fsSL https://raw.githubusercontent.com/ibrainhim/gws-sync-agent-setup/main/teardown.sh | bash -s -- \
  --gcp-project YOUR_PROJECT_ID \
  --agent-key YOUR_AGENT_KEY \
  --region europe-west1 \
  --delete-bucket
```

Note: removing the checkpoint means the agent has no memory of what it previously synced.
If you reinstall later, it will perform a full initial sync from scratch.

After teardown, remove the Domain-Wide Delegation grant from Google Admin:

1. Go to [Google Admin](https://admin.google.com) → Security → API controls → Domain-wide delegation
2. Find the entry for the Client ID you added during setup
3. Click **Delete**
