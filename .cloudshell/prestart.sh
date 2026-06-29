#!/bin/bash
# Auto-runs when Cloud Shell opens this repo.
# Only triggers setup when env vars are present (customer arrived via OutThink dashboard link).
# Without env vars (CS team opening manually), does nothing — terminal opens normally.
echo "prestart.sh fired"
if [ -n "${SETUP_TOKEN:-}${OUTTHINK_ORG_ID:-}" ]; then
  bash setup.sh
else
  echo "No env vars set — skipping setup. Run 'bash setup.sh' manually if needed."
fi
