#!/usr/bin/env bash
# show-metrics.sh — StarRocks cluster metrics overview for the local test environment
#
# Displays: cluster topology, storage volumes, table row counts + data size,
# partition layout, tablet/rowset health, Routine Load ingest status,
# data cache performance, compaction state, cluster statistics,
# and Redpanda consumer lag.
#
# Usage:
#   chmod +x show-metrics.sh
#   ./show-metrics.sh
#
# Requires: docker, mysql (or mariadb) CLI client, StarRocks stack running.

set -euo pipefail

SR_HOST="127.0.0.1"
SR_PORT="9030"
SR_USER="root"

# ── ANSI formatting ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  B='\033[1m'; DIM='\033[2m'; RST='\033[0m'
  CY='\033[36m'; GR='\033[32m'; YL='\033[33m'; RD='\033[31m'; BL='\033[34m'; MG='\033[35m'
else
  B=''; DIM=''; RST=''; CY=''; GR=''; YL=''; RD=''; BL=''; MG=''
fi

# ── Resolve SQL client ─────────────────────────────────────────────────────────
if   command -v mysql   &>/dev/null; then SR_CLIENT="mysql"
elif command -v mariadb &>/dev/null; then SR_CLIENT="mariadb"
else echo "ERROR: mysql/mariadb client not found. Install mysql-client and retry."; exit 1
fi

# ── SQL helpers ────────────────────────────────────────────────────────────────
# q: silent, no column names — for programmatic use
q()  { "$SR_CLIENT" -h "$SR_HOST" -P "$SR_PORT" -u "$SR_USER" \
         --connect-timeout=10 --silent --skip-column-names "$@" 2>/dev/null; }
# qt: tabular display
qt() { "$SR_CLIENT" -h "$SR_HOST" -P "$SR_PORT" -u "$SR_USER" \
         --connect-timeout=10 "$@" 2>/dev/null; }
# qv: vertical (\G) display — filters to separator lines + chosen fields
qvf() {
  local sql="$1"; shift
  local pattern; pattern=$(printf '%s|' "$@"); pattern="${pattern%|}"
  "$SR_CLIENT" -h "$SR_HOST" -P "$SR_PORT" -u "$SR_USER" \
    --connect-timeout=10 -e "${sql}\G" 2>/dev/null \
    | grep -E "^\*+|[[:space:]]*(${pattern})[[:space:]]*:" \
    | sed 's/^/  /' || echo "  (no data)"
}

# ── Layout helpers ─────────────────────────────────────────────────────────────
SEP="$(printf '═%.0s' {1..64})"
sep2="$(printf '─%.0s' {1..64})"

hdr() { printf "\n${B}${BL}╔  %s${RST}\n${BL}%s${RST}\n" "$1" "$SEP"; }
sub() { printf "\n${B}${CY}   ▸ %s${RST}\n" "$1"; }
kv()  { printf "  ${DIM}%-32s${RST} %s\n" "$1" "$2"; }
ok()  { printf "  ${GR}●${RST} %s\n" "$1"; }
warn(){ printf "  ${YL}●${RST} %s\n" "$1"; }
err() { printf "  ${RD}●${RST} %s\n" "$1"; }

hr()  { printf "  ${DIM}%s${RST}\n" "$sep2"; }

# ── Banner ─────────────────────────────────────────────────────────────────────
printf "${B}${CY}\n"
printf "  ┌────────────────────────────────────────────────────────────┐\n"
printf "  │   StarRocks Local — Metrics Overview                       │\n"
printf "  │   %-58s │\n" "$(date '+%Y-%m-%d  %H:%M:%S')"
printf "  └────────────────────────────────────────────────────────────┘\n"
printf "${RST}\n"

# ── Connectivity ───────────────────────────────────────────────────────────────
if ! q -e "SELECT 1" >/dev/null; then
  err "Cannot connect to StarRocks at ${SR_HOST}:${SR_PORT}"
  echo "  → Start the stack: ./docker-compose-up.sh"
  exit 1
fi
ok "StarRocks FE reachable at ${SR_HOST}:${SR_PORT}"

# ── 1. Cluster Topology ────────────────────────────────────────────────────────
hdr "1. CLUSTER TOPOLOGY"

sub "Frontend Nodes (FEs)"
qvf "SHOW FRONTENDS" \
  Host QueryPort Role IsMaster Alive ReplayedJournalId Version

sub "Compute Nodes (CNs)"
qvf "SHOW COMPUTE NODES" \
  Host HeartbeatPort Alive SystemDecommissioned NumRunningQueries MemUsedPct CpuUsedPct DataCacheMetrics

# ── 2. Storage Volume ──────────────────────────────────────────────────────────
hdr "2. STORAGE VOLUME"

qvf "SHOW STORAGE VOLUMES" \
  Name Type IsDefault Enabled Locations Comment

# ── 3. Databases & Table Overview ─────────────────────────────────────────────
hdr "3. DATABASES & TABLES"

USER_DBS=$(q -e "SHOW DATABASES;" \
  | grep -vE "^(information_schema|_statistics_|sys|starrocks|mysql)$" || true)

if [[ -z "$USER_DBS" ]]; then
  warn "No user databases found. Run load-quickstart-starrocks.sh first."
else
  while IFS= read -r DB; do
    [[ -z "$DB" ]] && continue
    sub "Database: $DB"

    TABLES=$(q "$DB" -e "SHOW TABLES;" 2>/dev/null || true)
    if [[ -z "$TABLES" ]]; then
      warn "(no tables)"
      continue
    fi

    printf "  ${DIM}%-40s %15s   %12s   %12s${RST}\n" \
      "Table" "Rows (COUNT(*))" "Data size" "Index size"
    hr

    while IFS= read -r TBL; do
      [[ -z "$TBL" ]] && continue
      ROW_COUNT=$(q "$DB" -e "SELECT COUNT(*) FROM \`${TBL}\`;" 2>/dev/null || echo "?")
      DATA_SIZE=$(q -e "SELECT IFNULL(DATA_LENGTH,'?')  FROM information_schema.tables \
        WHERE TABLE_SCHEMA='${DB}' AND TABLE_NAME='${TBL}';" 2>/dev/null || echo "?")
      IDX_SIZE=$(q -e "SELECT IFNULL(INDEX_LENGTH,'?') FROM information_schema.tables \
        WHERE TABLE_SCHEMA='${DB}' AND TABLE_NAME='${TBL}';" 2>/dev/null || echo "?")
      printf "  %-40s %15s   %12s   %12s\n" \
        "$TBL" "$ROW_COUNT" "${DATA_SIZE} B" "${IDX_SIZE} B"
    done <<< "$TABLES"

  done <<< "$USER_DBS"
fi

# ── 4. Partitions ─────────────────────────────────────────────────────────────
hdr "4. PARTITIONS"

if [[ -n "$USER_DBS" ]]; then
  while IFS= read -r DB; do
    [[ -z "$DB" ]] && continue
    TABLES=$(q "$DB" -e "SHOW TABLES;" 2>/dev/null || true)
    while IFS= read -r TBL; do
      [[ -z "$TBL" ]] && continue
      sub "${DB}.${TBL}"
      qt "$DB" -e "
        SELECT
          PartitionName  AS Partition,
          VisibleVersion AS Version,
          Buckets,
          ReplicationNum AS Replicas,
          DataSize,
          RowCount,
          State
        FROM information_schema.partitions_meta
        WHERE TABLE_SCHEMA = '${DB}' AND TABLE_NAME = '${TBL}'
        ORDER BY PartitionName;" 2>/dev/null \
      || qt "$DB" -e "SHOW PARTITIONS FROM \`${TBL}\`;" 2>/dev/null \
      || warn "(partition info unavailable)"
    done <<< "$TABLES"
  done <<< "$USER_DBS"
fi

# ── 5. Tablets & Rowsets ──────────────────────────────────────────────────────
hdr "5. TABLETS & ROWSETS"

# SHOW TABLETS FROM table returns one row per tablet.
# Key columns (tab-separated, --silent):
#   1:TabletId  2:ReplicaId  3:BackendId  4:SchemaHash  5:Version
#   6:LstSuccessVersion  7:LstFailedVersion  8:LstFailedTime
#   9:LocalDataSize  10:RemoteDataSize  11:RowCount  12:State
#   13:LstConsistencyCheckTime  14:CheckVersion  15:VersionCount  ...
tablet_summary() {
  local db_table="$1"
  local raw
  raw=$(q -e "SHOW TABLETS FROM ${db_table};" 2>/dev/null) || { warn "(tablets unavailable for ${db_table})"; return; }
  if [[ -z "$raw" ]]; then warn "(no tablets for ${db_table})"; return; fi

  echo "$raw" | awk -F'\t' '
  {
    n++
    row_sum   += $11
    ver_sum   += $15
    local_sum += $9
    remote_sum+= $10
    if ($15 > max_ver || max_ver == "") max_ver = $15
    if ($15 < min_ver || min_ver == "") min_ver = $15
    if ($12 != "NORMAL") bad++
  }
  END {
    if (n == 0) { print "  (no tablets)"; exit }
    printf "  Tablets    : %d\n", n
    printf "  Rows total : %d\n", row_sum
    printf "  Rowsets    : avg %.1f  |  min %d  |  max %d%s\n",
      ver_sum/n, min_ver, max_ver,
      (max_ver > 20 ? "  ⚠ high — compaction lagging?" : "")
    printf "  Data size  : local %d B  |  remote %d B\n", local_sum, remote_sum
    if (bad > 0) printf "  ⚠  %d tablet(s) not in NORMAL state\n", bad
  }'
}

if [[ -n "$USER_DBS" ]]; then
  while IFS= read -r DB; do
    [[ -z "$DB" ]] && continue
    TABLES=$(q "$DB" -e "SHOW TABLES;" 2>/dev/null || true)
    while IFS= read -r TBL; do
      [[ -z "$TBL" ]] && continue
      sub "${DB}.${TBL}"
      tablet_summary "${DB}.${TBL}"
    done <<< "$TABLES"
  done <<< "$USER_DBS"
fi

# ── 6. Routine Load — Ingest Status ───────────────────────────────────────────
hdr "6. ROUTINE LOAD — INGEST STATUS"

RL_RAW=$(qt -e "SHOW ALL ROUTINE LOAD\G" 2>/dev/null || qt -e "SHOW ROUTINE LOAD\G" 2>/dev/null || true)

if [[ -z "$RL_RAW" ]]; then
  warn "No Routine Load jobs found. Run load-quickstart-starrocks.sh first."
else
  echo "$RL_RAW" | grep -E \
    "^\*+|[[:space:]]*(Name|DbName|TableName|State|LoadedRows|FilteredRows|\
ErrorRows|TotalRows|LoadedBytes|LoadRowsRate|OffsetOfPartition|\
CurrentTaskNum|OtherMsg|ReasonOfStateChanged)[[:space:]]*:" \
    | sed 's/^/  /' || true

  # Deduplication estimate: compare LoadedRows vs actual table COUNT(*)
  printf "\n  ${DIM}Deduplication estimate (PRIMARY KEY model):${RST}\n"
  printf "  ${DIM}  LoadedRows = rows consumed from Kafka (including PK updates)${RST}\n"
  printf "  ${DIM}  COUNT(*)   = unique PKs currently stored${RST}\n"
  printf "  ${DIM}  Effective dedup = LoadedRows − COUNT(*) rows replaced/overwritten${RST}\n"

  if [[ -n "$USER_DBS" ]]; then
    while IFS= read -r DB; do
      [[ -z "$DB" ]] && continue
      TABLES=$(q "$DB" -e "SHOW TABLES;" 2>/dev/null || true)
      while IFS= read -r TBL; do
        [[ -z "$TBL" ]] && continue
        RL_ROWS=$(echo "$RL_RAW" | awk -F': ' \
          "/TableName.*${TBL}/{found=1} found && /LoadedRows/{print \$2; exit}" \
          | tr -d ' ' || echo "?")
        TBL_CNT=$(q "$DB" -e "SELECT COUNT(*) FROM \`${TBL}\`;" 2>/dev/null || echo "?")
        printf "  %-40s  LoadedRows: %-12s  COUNT(*): %s\n" \
          "${DB}.${TBL}" "${RL_ROWS}" "${TBL_CNT}"
      done <<< "$TABLES"
    done <<< "$USER_DBS"
  fi
fi

# ── 7. Data Cache Performance ──────────────────────────────────────────────────
hdr "7. DATA CACHE (per CN)"

CACHE_DATA=$(qt -e "SELECT * FROM information_schema.datacache_stats;" 2>/dev/null || true)
if [[ -z "$CACHE_DATA" ]]; then
  warn "datacache_stats unavailable (no queries run yet, or view not supported)"
else
  echo "$CACHE_DATA"
fi

# ── 8. Compaction Status ───────────────────────────────────────────────────────
hdr "8. COMPACTION"

COMPACT=$(qt -e "SHOW PROC '/compactions'\G" 2>/dev/null || true)
if [[ -z "$COMPACT" ]] || echo "$COMPACT" | grep -q "Empty set"; then
  ok "No compactions currently running (idle)"
else
  echo "$COMPACT" | grep -E "^\*+|[[:space:]]*(DbName|TableName|PartitionName|State|Type|Progress|ElapseTime)[[:space:]]*:" \
    | sed 's/^/  /' || true
fi

# ── 9. Cluster Statistics ──────────────────────────────────────────────────────
hdr "9. CLUSTER STATISTICS"

qvf "SHOW PROC '/statistic'" \
  DbId DbName TableNum PartitionNum IndexNum TabletNum ReplicaNum UnhealthyTabletNum

# ── 10. Redpanda Consumer Groups & Lag ────────────────────────────────────────
hdr "10. REDPANDA — CONSUMER LAG"

if ! docker inspect redpanda &>/dev/null 2>&1; then
  warn "Redpanda container not running"
else
  GROUPS=$(docker exec redpanda rpk group list 2>/dev/null | tail -n +2 || true)
  if [[ -z "$GROUPS" ]]; then
    warn "No consumer groups found (no Routine Load jobs active?)"
  else
    printf "  ${DIM}%-40s  %s${RST}\n" "Consumer Group" "Lag"
    hr
    while IFS= read -r GRP; do
      [[ -z "$GRP" ]] && continue
      LAG=$(docker exec redpanda rpk group describe "$GRP" 2>/dev/null \
        | awk '/LAG/{total+=$NF} END{print total+0}' || echo "?")
      printf "  %-40s  %s\n" "$GRP" "$LAG"
    done <<< "$GROUPS"

    # Show full describe for groups with lag > 0
    sub "Consumer group detail"
    while IFS= read -r GRP; do
      [[ -z "$GRP" ]] && continue
      docker exec redpanda rpk group describe "$GRP" 2>/dev/null \
        | sed 's/^/    /' || true
    done <<< "$GROUPS"
  fi
fi

# ── 11. MinIO Bucket Usage ────────────────────────────────────────────────────
hdr "11. MINIO STORAGE USAGE"

if ! docker inspect minio &>/dev/null 2>&1; then
  warn "MinIO container not running"
else
  MINIO_INFO=$(docker exec minio du -sh /data 2>/dev/null | head -3 || true)
  if [[ -n "$MINIO_INFO" ]]; then
    echo "$MINIO_INFO" | sed 's/^/  /'
  fi
  MINIO_OBJECTS=$(docker exec minio find /data -type f 2>/dev/null | wc -l || echo "?")
  kv "Total objects in /data:" "$MINIO_OBJECTS files"
  kv "MinIO console:" "http://localhost:9001  (minioadmin / minioadmin)"
fi

# ── Footer ─────────────────────────────────────────────────────────────────────
printf "\n${DIM}%s${RST}\n" "$SEP"
printf "${DIM}  Connect:      mysql -h 127.0.0.1 -P 9030 -u root${RST}\n"
printf "${DIM}  FE1 web UI:   http://localhost:8030  (query profiler)${RST}\n"
printf "${DIM}  CloudBeaver:  http://localhost:8978  (cbadmin / cbadmin)${RST}\n"
printf "${DIM}  Redpanda UI:  http://localhost:8080${RST}\n"
printf "${DIM}%s${RST}\n\n" "$SEP"
