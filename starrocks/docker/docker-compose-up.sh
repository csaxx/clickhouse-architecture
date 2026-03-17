#!/usr/bin/env bash
# docker-compose-up.sh — Start the StarRocks + Redpanda + MinIO stack and wait
# until every service is fully ready to accept work.
#
# Usage:
#   chmod +x docker-compose-up.sh
#   ./docker-compose-up.sh
#
# Requires: docker, mysql (or mariadb) CLI client.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SR_HOST="127.0.0.1"
SR_PORT="9030"
SR_USER="root"

# ---------------------------------------------------------------------------
# Resolve SQL client (mysql preferred; fall back to mariadb)
# ---------------------------------------------------------------------------
if command -v mysql &>/dev/null; then
  SR_CLIENT="mysql"
elif command -v mariadb &>/dev/null; then
  SR_CLIENT="mariadb"
else
  echo "ERROR: neither 'mysql' nor 'mariadb' CLI found. Install mysql-client and retry."
  exit 1
fi

sr_sql() {
  "$SR_CLIENT" -h "$SR_HOST" -P "$SR_PORT" -u "$SR_USER" --connect-timeout=10 "$@"
}

# ---------------------------------------------------------------------------
# 1. Start Docker Compose
# ---------------------------------------------------------------------------
echo "=== Step 1: Starting Docker Compose ==="
cd "$SCRIPT_DIR"
docker compose up -d
echo "  stack started."

# ---------------------------------------------------------------------------
# 2. Wait for starrocks-init to complete successfully
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2: Waiting for StarRocks init container to finish ==="
while true; do
  STATUS=$(docker inspect --format='{{.State.Status}}' starrocks-init 2>/dev/null || echo "missing")
  if [ "$STATUS" = "exited" ]; then
    EXIT_CODE=$(docker inspect --format='{{.State.ExitCode}}' starrocks-init)
    if [ "$EXIT_CODE" != "0" ]; then
      echo "ERROR: starrocks-init exited with code $EXIT_CODE"
      docker compose logs starrocks-init
      exit 1
    fi
    echo "  starrocks-init completed successfully."
    break
  fi
  echo "  starrocks-init status: $STATUS — waiting..."
  sleep 5
done

# ---------------------------------------------------------------------------
# 3. Wait for StarRocks FE MySQL port to be reachable from host
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 3: Waiting for StarRocks FE (host port $SR_PORT) ==="
until sr_sql -e "SELECT 1" >/dev/null 2>&1; do
  echo "  not ready yet, retrying in 5s..."
  sleep 5
done
echo "  StarRocks FE is reachable."

# ---------------------------------------------------------------------------
# 4. Wait for CN alive + tablet scheduler capacity report
# ---------------------------------------------------------------------------
# "Alive: true" only means the FE received the CN heartbeat. The tablet
# scheduler processes the CN's capacity report in a separate step that can
# lag 10-30s behind. CREATE TABLE fails with "Cluster has no available
# capacity" until that report arrives. We poll until the CN row appears
# with Alive: true, then keep retrying a dummy CREATE TABLE until the
# scheduler accepts it, then drop the dummy table.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 4: Waiting for both CNs alive ==="
until [ "$(sr_sql -e "SHOW COMPUTE NODES\G" 2>/dev/null | grep -c "Alive: true")" -ge 2 ]; do
  echo "  waiting for 2 alive CNs, retrying in 5s..."
  sleep 5
done
echo "  Both CN heartbeats received. Waiting for tablet scheduler capacity report..."

sr_sql -e "DROP DATABASE IF EXISTS _qs_probe;" 2>/dev/null || true
sr_sql -e "CREATE DATABASE IF NOT EXISTS _qs_probe;" 2>/dev/null || true
until sr_sql _qs_probe -e "
  CREATE TABLE _probe (k INT) ENGINE=OLAP
  DUPLICATE KEY(k) DISTRIBUTED BY HASH(k) BUCKETS 1
  PROPERTIES ('replication_num'='1');
" 2>/dev/null; do
  echo "  scheduler not ready yet, retrying in 5s..."
  sleep 5
done
sr_sql -e "DROP DATABASE IF EXISTS _qs_probe;" 2>/dev/null || true
echo "  Cluster has capacity — proceeding."

# ---------------------------------------------------------------------------
# 5. Wait for Redpanda
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 5: Waiting for Redpanda ==="
until docker exec redpanda rpk cluster health 2>/dev/null | grep -q "Healthy.*true"; do
  echo "  Redpanda not ready yet, retrying in 5s..."
  sleep 5
done
echo "  Redpanda is ready."

echo ""
echo "=== Stack is up and ready ==="
echo "  StarRocks: mysql -h 127.0.0.1 -P 9030 -u root"
echo "  CloudBeaver: http://localhost:8978  (cbadmin / cbadmin)"
echo "  MinIO:       http://localhost:9001  (minioadmin / minioadmin)"
echo "  Redpanda:    http://localhost:8080"
