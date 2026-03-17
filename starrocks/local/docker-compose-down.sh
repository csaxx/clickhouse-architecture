#!/usr/bin/env bash
# docker-compose-down.sh — Tear down the stack and remove all volumes.
# WARNING: this deletes all data in MinIO, StarRocks FE metadata, Redpanda,
# and CloudBeaver. Use it when you want a completely clean restart.
#
# Usage:
#   chmod +x docker-compose-down.sh
#   ./docker-compose-down.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

docker compose down -v --remove-orphans
echo "Stack stopped and all volumes removed."
