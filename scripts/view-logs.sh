#!/bin/bash
# View the access log (the single Traefik JSON log)
#
# There are no per-domain files. The destination is in the RequestHost field, so passing a
# domain as an argument tails only those lines.
#
# Usage: ./view-logs.sh [domain]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="$ROOT_DIR/logs/traefik/access.log"

if [ ! -f "$LOG_FILE" ]; then
  echo "No log file at: $LOG_FILE" >&2
  echo "   Traefik may not be running (make ps)" >&2
  exit 1
fi

DOMAIN="${1:-}"

echo "$LOG_FILE${DOMAIN:+ ($DOMAIN only)}"
echo "---"

if [ -n "$DOMAIN" ]; then
  tail -f "$LOG_FILE" | grep --line-buffered -F "\"RequestHost\":\"$DOMAIN\""
else
  tail -f "$LOG_FILE"
fi
