#!/bin/bash
# アクセスログ閲覧（Traefik の JSON ログ 1 本）
#
# ドメイン別のファイルは無い。宛先は JSON の RequestHost に入っているので、
# 引数でドメインを渡すとその行だけを流す。
#
# Usage: ./view-logs.sh [domain]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="$ROOT_DIR/logs/traefik/access.log"

if [ ! -f "$LOG_FILE" ]; then
  echo "❌ ログファイルがありません: $LOG_FILE" >&2
  echo "   Traefik が起動していない可能性がある（make ps）" >&2
  exit 1
fi

DOMAIN="${1:-}"

echo "📄 $LOG_FILE${DOMAIN:+（$DOMAIN のみ）}"
echo "---"

if [ -n "$DOMAIN" ]; then
  tail -f "$LOG_FILE" | grep --line-buffered -F "\"RequestHost\":\"$DOMAIN\""
else
  tail -f "$LOG_FILE"
fi
