#!/usr/bin/env bash
# Backfill digests for a date range, one day at a time.
# Waits for each run to complete before dispatching the next.
#
# Usage:
#   ./scripts/backfill-digests.sh 2026-02-08 2026-03-09
#   ./scripts/backfill-digests.sh 2026-02-08 2026-03-09 --telegram  # include telegram
set -euo pipefail

START_DATE="${1:?Usage: $0 START_DATE END_DATE [--telegram]}"
END_DATE="${2:?Usage: $0 START_DATE END_DATE [--telegram]}"
PUBLISH_TELEGRAM="${3:-false}"
[ "$PUBLISH_TELEGRAM" = "--telegram" ] && PUBLISH_TELEGRAM=true

WORKFLOW="Generate Digest"
CURRENT="$START_DATE"

echo "=== Backfill: $START_DATE → $END_DATE ==="
echo "    Telegram: $PUBLISH_TELEGRAM"
echo ""

while [[ "$CURRENT" < "$END_DATE" ]] || [[ "$CURRENT" == "$END_DATE" ]]; do
  echo "[$CURRENT] Dispatching..."

  gh workflow run "$WORKFLOW" \
    -f start_date="$CURRENT" \
    -f end_date="$CURRENT" \
    -f publish_telegram="$PUBLISH_TELEGRAM" \
    -f publish_ghost=true \
    -f publish_substack=true

  # Wait for the run to appear (gh needs a moment to register it)
  sleep 5

  # Find the run we just dispatched
  RUN_ID=$(gh run list --workflow="$WORKFLOW" --limit=1 --json databaseId --jq '.[0].databaseId')

  if [ -z "$RUN_ID" ]; then
    echo "[$CURRENT] ERROR: Could not find run ID, skipping"
    CURRENT=$(date -j -v+1d -f "%Y-%m-%d" "$CURRENT" +%Y-%m-%d 2>/dev/null || date -d "$CURRENT + 1 day" +%Y-%m-%d)
    continue
  fi

  echo "[$CURRENT] Run #$RUN_ID — waiting..."

  # Poll until complete
  while true; do
    STATUS=$(gh run view "$RUN_ID" --json status,conclusion --jq '.status')
    if [ "$STATUS" = "completed" ]; then
      CONCLUSION=$(gh run view "$RUN_ID" --json conclusion --jq '.conclusion')
      if [ "$CONCLUSION" = "success" ]; then
        echo "[$CURRENT] ✓ Success"
      else
        echo "[$CURRENT] ✗ Failed ($CONCLUSION)"
        echo "    https://github.com/$(gh repo view --json nameWithOwner --jq '.nameWithOwner')/actions/runs/$RUN_ID"
      fi
      break
    fi
    sleep 15
  done

  # Next day
  CURRENT=$(date -j -v+1d -f "%Y-%m-%d" "$CURRENT" +%Y-%m-%d 2>/dev/null || date -d "$CURRENT + 1 day" +%Y-%m-%d)
done

echo ""
echo "=== Backfill complete ==="
