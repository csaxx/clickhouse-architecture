#!/usr/bin/env bash
# starrocks-drop-tables.sh — Stop Routine Load jobs and drop tables in the
# quickstart database.
#
# Idempotent: safe to run even if jobs or tables do not exist.
# Stops jobs before dropping tables so no in-flight writes are lost to errors.
#
# Usage:
#   chmod +x starrocks-drop-tables.sh
#   ./starrocks-drop-tables.sh
#
# Requires: mysql (or mariadb) CLI client, StarRocks stack running.

set -euo pipefail

SR_HOST="127.0.0.1"
SR_PORT="9030"
SR_USER="root"

# ---------------------------------------------------------------------------
# Resolve SQL client
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

# Run a SQL statement, swallowing errors (used for STOP which fails if job is
# already stopped, paused, or never existed).
sr_sql_soft() {
  sr_sql -e "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 1. Stop Routine Load jobs
#    STOP transitions a job to STOPPED state permanently. It errors if the job
#    does not exist or is already stopped — sr_sql_soft ignores those errors.
# ---------------------------------------------------------------------------
echo "=== Step 1: Stopping Routine Load jobs ==="

sr_sql_soft "STOP ROUTINE LOAD FOR quickstart.crash_load;"
echo "  crash_load   — stopped (or was already stopped/absent)"

sr_sql_soft "STOP ROUTINE LOAD FOR quickstart.weather_load;"
echo "  weather_load — stopped (or was already stopped/absent)"

sr_sql_soft "STOP ROUTINE LOAD FOR quickstart.clicks;"
echo "  clicks       — stopped (or was already stopped/absent)"

# ---------------------------------------------------------------------------
# 2. Drop tables
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2: Dropping tables ==="

sr_sql quickstart -e "DROP TABLE IF EXISTS crashdata;"
echo "  crashdata    — dropped"

sr_sql quickstart -e "DROP TABLE IF EXISTS weatherdata;"
echo "  weatherdata  — dropped"

sr_sql quickstart -e "DROP TABLE IF EXISTS site_clicks;"
echo "  site_clicks  — dropped"

echo ""
echo "=== Done ==="
echo "  Run starrocks-create-tables.sh to recreate tables and Routine Load jobs."
