#!/usr/bin/env bash
# redpanda-create-topics.sh — Create the Redpanda topics used by the quickstart.
#
# Idempotent: safe to run multiple times (existing topics are silently skipped).
# Run docker-compose-up.sh first to ensure Redpanda is ready.
#
# Usage:
#   chmod +x redpanda-create-topics.sh
#   ./redpanda-create-topics.sh
#
# Requires: docker.

set -euo pipefail

CRASH_TOPIC="crashdata-topic"
WEATHER_TOPIC="weatherdata-topic"
SITE_CLICKS_TOPIC="site-clicks"

echo "=== Creating Redpanda topics ==="
docker exec redpanda rpk topic create "$CRASH_TOPIC"        --partitions 3 --replicas 1 2>&1 | grep -v "already exists" || true
docker exec redpanda rpk topic create "$WEATHER_TOPIC"      --partitions 3 --replicas 1 2>&1 | grep -v "already exists" || true
docker exec redpanda rpk topic create "$SITE_CLICKS_TOPIC"  --partitions 1 --replicas 1 2>&1 | grep -v "already exists" || true
echo "  topics ready: $CRASH_TOPIC, $WEATHER_TOPIC, $SITE_CLICKS_TOPIC"
