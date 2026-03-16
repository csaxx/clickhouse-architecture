#!/usr/bin/env bash
# load-data-weather.sh — Download the NOAA weather dataset and produce it into
# the weatherdata-topic Redpanda topic.
#
# Run docker-compose-up.sh first to ensure the stack is ready.
# Run redpanda-create-topics.sh first to create the topic.
#
# Usage:
#   chmod +x load-data-weather.sh
#   ./load-data-weather.sh
#
# Requires: docker, curl.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"

WEATHER_URL="https://raw.githubusercontent.com/StarRocks/demo/master/documentation-samples/quickstart/datasets/72505394728.csv"
WEATHER_FILE="$DATA_DIR/72505394728.csv"
WEATHER_TOPIC="weatherdata-topic"

# ---------------------------------------------------------------------------
# 1. Download (skip if already present)
# ---------------------------------------------------------------------------
echo "=== Step 1: Downloading NOAA weather dataset ==="
mkdir -p "$DATA_DIR"

if [ -f "$WEATHER_FILE" ]; then
  echo "  already present: $WEATHER_FILE"
else
  echo "  downloading..."
  curl -fL --progress-bar -o "$WEATHER_FILE" "$WEATHER_URL"
  echo "  done."
fi

# ---------------------------------------------------------------------------
# 2. Produce → Redpanda (skip CSV header row)
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2: Producing weather data → $WEATHER_TOPIC ==="
tail -n +2 "$WEATHER_FILE" \
  | docker exec -i redpanda rpk topic produce "$WEATHER_TOPIC" --compression snappy
echo "  weather data produced."

echo ""
echo "=== Done ==="
echo "  Run load-quickstart-starrocks.sh to create tables and Routine Load jobs."
