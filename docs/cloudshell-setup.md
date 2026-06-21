# OutThink Google Workspace Sync Agent

Welcome. Use the arrows at the bottom to navigate between pages.
Each code block is clickable — it runs directly in the terminal on the left.

<walkthrough-project-setup></walkthrough-project-setup>

---

## First-time Setup

**Step 1 — Run setup**

Runs once. Safe to click again — the script detects an existing deployment and stops.

```bash
bash setup.sh
```

You will be asked for:
- Your Google Workspace super-admin email
- Your OutThink Organisation ID (OutThink admin panel → Settings → SCIM Integration)
- Your OutThink SCIM token

After the script completes, a **Client ID** will be printed. Send it to your Google Workspace
admin to complete Domain-Wide Delegation (exact instructions are printed by the script).

---

## Test Sync (Dry Run)

Runs a full sync cycle without writing anything to OutThink.
Use this after DWD is configured to verify the agent can read your Workspace directory.

```bash
bash ops.sh test
```

Check the output for:
- ✓ Directory API accessible — N users found
- ✓ SCIM connection verified
- A list of users that *would* be created/updated/disabled

No changes are made to OutThink.

---

## Manual Sync

Triggers an immediate live sync. Use this any time you want to force a sync rather
than waiting for the next scheduled run (every 12 hours by default).

```bash
bash ops.sh sync
```

A summary line at the end shows users created / updated / disabled.

---

## Enable Debug Logging

Raises log verbosity to DEBUG for troubleshooting.
Shows per-user operations, field-level diffs, and SCIM request/response bodies.

```bash
bash ops.sh debug-on
```

Disable when done — debug logs are verbose:

```bash
bash ops.sh debug-off
```

---

## View Logs

Shows the last 50 log lines from recent sync executions.

```bash
bash ops.sh logs
```

To stream logs live from a currently-running execution:

```bash
bash ops.sh logs --follow
```

---

## Check Status

Shows recent job executions — succeeded, failed, running — with timestamps.

```bash
bash ops.sh status
```

---

## Rotate SCIM Token

Updates the SCIM token in Secret Manager. The agent picks it up automatically
on the next execution — no redeployment needed.

```bash
bash ops.sh rotate-token
```

You will be prompted to enter the new token (input is hidden).

---

## Update Admin Email

Updates the Google Workspace super-admin email used for Domain-Wide Delegation.
Run this if the admin account changes.

```bash
bash ops.sh update-admin
```

---

## Uninstall

Removes the Cloud Run Job, Cloud Scheduler triggers, service account, and checkpoint bucket.

> ⚠ **This is irreversible. All checkpoint state will be deleted.**

```bash
bash ops.sh uninstall
```
