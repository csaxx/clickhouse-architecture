#!/usr/bin/env bash
# load-quickstart-redpanda.sh — Download NYC crash + weather datasets and
# produce them into Redpanda topics.
#
# Run docker-compose-up.sh first to ensure the stack is ready.
# Run this script before load-quickstart-starrocks.sh.
#
# Usage:
#   chmod +x load-quickstart-redpanda.sh
#   ./load-quickstart-redpanda.sh
#
# Requires: docker, curl.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"

CRASH_URL="https://raw.githubusercontent.com/StarRocks/demo/master/documentation-samples/quickstart/datasets/NYPD_Crash_Data.csv"
WEATHER_URL="https://raw.githubusercontent.com/StarRocks/demo/master/documentation-samples/quickstart/datasets/72505394728.csv"
CRASH_FILE="$DATA_DIR/NYPD_Crash_Data.csv"
WEATHER_FILE="$DATA_DIR/72505394728.csv"

CRASH_TOPIC="crashdata-topic"
WEATHER_TOPIC="weatherdata-topic"

# ---------------------------------------------------------------------------
# 1. Download data files (skip if already present)
# ---------------------------------------------------------------------------
echo "=== Step 1: Downloading datasets ==="
mkdir -p "$DATA_DIR"

if [ -f "$CRASH_FILE" ]; then
  echo "  crash data already present ($CRASH_FILE)"
else
  echo "  downloading NYC crash data (~96 MB)..."
  curl -fL --progress-bar -o "$CRASH_FILE" "$CRASH_URL"
  echo "  done."
fi

if [ -f "$WEATHER_FILE" ]; then
  echo "  weather data already present ($WEATHER_FILE)"
else
  echo "  downloading NOAA weather data..."
  curl -fL --progress-bar -o "$WEATHER_FILE" "$WEATHER_URL"
  echo "  done."
fi

# ---------------------------------------------------------------------------
# 2. Create Redpanda topics
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2: Creating Redpanda topics ==="
docker exec redpanda rpk topic create "$CRASH_TOPIC"   --partitions 3 --replicas 1 2>&1 | grep -v "already exists" || true
docker exec redpanda rpk topic create "$WEATHER_TOPIC" --partitions 3 --replicas 1 2>&1 | grep -v "already exists" || true
echo "  topics ready: $CRASH_TOPIC, $WEATHER_TOPIC"

# ---------------------------------------------------------------------------
# 3. Produce CSV data → Redpanda topics (skip header row with tail -n +2)
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 3: Producing crash data → $CRASH_TOPIC ==="
echo "  (streaming ~423k rows from $CRASH_FILE — may take a minute)"
tail -n +2 "$CRASH_FILE" \
  | docker exec -i redpanda rpk topic produce "$CRASH_TOPIC" --compression snappy
echo "  crash data produced."

echo ""
echo "=== Step 4: Producing weather data → $WEATHER_TOPIC ==="
tail -n +2 "$WEATHER_FILE" \
  | docker exec -i redpanda rpk topic produce "$WEATHER_TOPIC" --compression snappy
echo "  weather data produced."

echo ""
echo "=== Redpanda load complete ==="
echo "  Run load-quickstart-starrocks.sh to create tables and Routine Load jobs."
