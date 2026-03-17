#!/usr/bin/env bash
# load-data-clicks.sh — Continuously generate synthetic site_clicks events and
# produce them to the site-clicks Redpanda topic.
#
# Replicates the logic of gen.py (StarRocks demo):
#   uid   — random integer 1–10 000
#   site  — weighted URL pool: 100× homepage, 55× docs, 34× blog, 12× community
#   vtime — unix timestamp with random look-back jitter (same formula as gen.py)
#
# Runs indefinitely, producing BATCH_SIZE messages every INTERVAL seconds.
# At the default values (25 msgs / 5 s) this matches gen.py's 1 msg per 200 ms.
#
# Usage:
#   chmod +x load-data-clicks.sh
#   ./load-data-clicks.sh [batch_size [interval_seconds]]
#
# Examples:
#   ./load-data-clicks.sh          # 25 msgs every 5 s (default)
#   ./load-data-clicks.sh 100 10   # 100 msgs every 10 s
#
# Requires: docker (Redpanda container must be running).

set -euo pipefail

BATCH_SIZE="${1:-25}"
INTERVAL="${2:-5}"
TOPIC="site-clicks"

# ---------------------------------------------------------------------------
# Weighted site pool — mirrors gen.py's site_scope list exactly:
#   ['https://www.starrocks.io/'] * 100
#   ['https://www.starrocks.io/blog'] * 34
#   ['https://www.starrocks.io/product/community'] * 12
#   ['https://docs.starrocks.io/'] * 55
#   total = 201
#
# We map ranges of a single random draw [0, 200] instead of building a 201-
# element array, which keeps the distribution identical without the overhead.
#
#   [  0,  99] → homepage   (100 / 201 ≈ 49.8 %)
#   [100, 154] → docs       ( 55 / 201 ≈ 27.4 %)
#   [155, 188] → blog       ( 34 / 201 ≈ 16.9 %)
#   [189, 200] → community  ( 12 / 201 ≈  6.0 %)
# ---------------------------------------------------------------------------
SITE_TOTAL=201

pick_site() {
  local r=$(( RANDOM % SITE_TOTAL ))
  if   (( r <  100 )); then printf 'https://www.starrocks.io/'
  elif (( r <  155 )); then printf 'https://docs.starrocks.io/'
  elif (( r <  189 )); then printf 'https://www.starrocks.io/blog'
  else                      printf 'https://www.starrocks.io/product/community'
  fi
}

# ---------------------------------------------------------------------------
# gen_message — produce one JSON line, matching gen.py's gen() exactly:
#   uid         = randint(1, 10000)
#   site        = pick from weighted pool
#   vtime       = int(time.time() + delay_jitter * chance)
#                   delay_jitter = randint(-1800, 0)
#                   chance       = randint(0, 3)
# ---------------------------------------------------------------------------
gen_message() {
  local uid=$(( RANDOM % 10000 + 1 ))
  local site; site=$(pick_site)
  local now;  now=$(date +%s)
  local jitter=$(( -(RANDOM % 1801) ))   # 0 to -1800  (mirrors randint(-1800, 0))
  local chance=$(( RANDOM % 4 ))         # 0, 1, 2, or 3
  local vtime=$(( now + jitter * chance ))
  printf '{ "uid": %d, "site": "%s", "vtime": %d }\n' "$uid" "$site" "$vtime"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
echo "Producing to '$TOPIC'  |  batch=$BATCH_SIZE msg  |  interval=${INTERVAL}s"
echo "Press Ctrl-C to stop."
echo ""

trap 'printf "\nStopped.\n"; exit 0' INT TERM

while true; do
  {
    for (( i = 0; i < BATCH_SIZE; i++ )); do
      gen_message
    done
  } | docker exec -i redpanda rpk topic produce "$TOPIC" --compression snappy

  printf "%s  +%d messages → %s\n" "$(date '+%H:%M:%S')" "$BATCH_SIZE" "$TOPIC"
  sleep "$INTERVAL"
done
