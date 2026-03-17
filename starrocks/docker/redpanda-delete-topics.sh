#!/usr/bin/env bash
# redpanda-delete-topics.sh — Delete the quickstart Redpanda topics and all
# consumer groups (created by StarRocks Routine Load jobs).
#
# Idempotent: safe to run even if topics or groups do not exist.
#
# Usage:
#   chmod +x redpanda-delete-topics.sh
#   ./redpanda-delete-topics.sh
#
# Requires: docker (Redpanda container must be running).

set -euo pipefail

CRASH_TOPIC="crashdata-topic"
WEATHER_TOPIC="weatherdata-topic"
SITE_CLICKS_TOPIC="site-clicks"

rpk() { docker exec redpanda rpk "$@"; }

# ---------------------------------------------------------------------------
# 1. Delete topics
# ---------------------------------------------------------------------------
echo "=== Step 1: Deleting topics ==="

for TOPIC in "$CRASH_TOPIC" "$WEATHER_TOPIC" "$SITE_CLICKS_TOPIC"; do
  if rpk topic delete "$TOPIC" 2>/dev/null; then
    echo "  $TOPIC — deleted"
  else
    echo "  $TOPIC — not found, skipping"
  fi
done

# ---------------------------------------------------------------------------
# 2. Delete consumer groups
#    rpk group list output: header line + one row per group (first column = name)
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2: Deleting consumer groups ==="

GROUPS=$(rpk group list 2>/dev/null | awk 'NR>1 && $1 != "" {print $1}' || true)

if [[ -z "$GROUPS" ]]; then
  echo "  no consumer groups found"
else
  while IFS= read -r GRP; do
    [[ -z "$GRP" ]] && continue
    if rpk group delete "$GRP" 2>/dev/null; then
      echo "  $GRP — deleted"
    else
      echo "  $GRP — could not delete (may still have active members)"
    fi
  done <<< "$GROUPS"
fi

echo ""
echo "=== Done ==="
echo "  Run redpanda-create-topics.sh to recreate topics."
