#!/usr/bin/env bash
# load-data-crash.sh — Download the NYC crash dataset and produce it into
# the crashdata-topic Redpanda topic.
#
# Run docker-compose-up.sh first to ensure the stack is ready.
# Run redpanda-create-topics.sh first to create the topic.
#
# Usage:
#   chmod +x load-data-crash.sh
#   ./load-data-crash.sh
#
# Requires: docker, curl.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"

CRASH_URL="https://raw.githubusercontent.com/StarRocks/demo/master/documentation-samples/quickstart/datasets/NYPD_Crash_Data.csv"
CRASH_FILE="$DATA_DIR/NYPD_Crash_Data.csv"
CRASH_TOPIC="crashdata-topic"

# ---------------------------------------------------------------------------
# 1. Download (skip if already present)
# ---------------------------------------------------------------------------
echo "=== Step 1: Downloading NYC crash dataset ==="
mkdir -p "$DATA_DIR"

if [ -f "$CRASH_FILE" ]; then
  echo "  already present: $CRASH_FILE"
else
  echo "  downloading (~96 MB)..."
  curl -fL --progress-bar -o "$CRASH_FILE" "$CRASH_URL"
  echo "  done."
fi

# ---------------------------------------------------------------------------
# 2. Produce → Redpanda (skip CSV header row)
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2: Producing crash data → $CRASH_TOPIC ==="
echo "  (streaming ~423k rows — may take a minute)"
tail -n +2 "$CRASH_FILE" \
  | docker exec -i redpanda rpk topic produce "$CRASH_TOPIC" --compression snappy
echo "  crash data produced."

echo ""
echo "=== Done ==="
echo "  Run load-quickstart-starrocks.sh to create tables and Routine Load jobs."
