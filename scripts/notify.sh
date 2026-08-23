#!/bin/bash
# 通知スクリプト（運用通知ハブ = console /internal/notify へ送信。未到達なら journald に残るのみ）
# Usage:
#   notify.sh --failed <unit>          # systemd OnFailure 用（error 通知＋journalctl 案内）
#   notify.sh --error <title...>       # error 通知（即時メール転送の対象）
#   notify.sh --warn <title...>        # warning 通知（要対応として日報にも載る）
#   notify.sh <title...>               # 任意メッセージ（info）。本文は stdin から渡せる:
#   notify.sh "タイトル" <<EOF ... EOF
#
# 旧 Slack webhook は廃止（無料枠上限で全通知が無音破棄された 2026-07 の事故を受け自前ハブ化）。
# ハブ（console）は同じホストで動き、自分の compose が 127.0.0.1:9090 に loopback 限定で
# 公開している。向き先は .env の OPS_NOTIFY_URL で変えられる。

set -uo pipefail

# edge .env を読む（INTERNAL_TOKEN・OPS_NOTIFY_URL 供給。systemd OnFailure 経由でも確実に届くように。
# report.sh と同じ方式。二重読み込みでも害はない）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
[ -f "$ROOT_DIR/.env" ] && { set -a; . "$ROOT_DIR/.env"; set +a; }

# 単一 EC2 のためホスト名は付けない（送信元 host 表示で足りる）
HUB_URL="${OPS_NOTIFY_URL:-http://127.0.0.1:9090}"

if [ "${1:-}" = "--failed" ]; then
  # systemd OnFailure 経路。%i で渡る失敗ユニット名から定型メッセージを組む。
  UNIT="${2:-unknown.unit}"
  LEVEL="error"
  TITLE="systemd ユニット失敗: $UNIT"
  # 単一 EC2 なのでホスト名は毎行に要らない。既定の書式は行の半分が
  # ip-10-0-1-186.ap-northeast-1.compute.internal で埋まって本文が読めない
  BODY="$(journalctl -u "$UNIT" -n 15 --no-pager -o short-iso --no-hostname 2>/dev/null || true)
詳細: journalctl -u $UNIT -n 50"
else
  LEVEL="info"
  case "${1:-}" in
    --warn)  LEVEL="warning"; shift ;;
    --error) LEVEL="error";   shift ;;
  esac
  TITLE="$*"
  # 本文は stdin（パイプ/ヒアドキュメント）からのみ。無ければタイトルだけ送る
  BODY=""
  if [ ! -t 0 ]; then
    BODY="$(cat)"
  fi
fi

# journald に全文を残す（ハブ未達でも痕跡が消えないように）
echo "$TITLE"
if [ -n "$BODY" ] && [ "$BODY" != "$TITLE" ]; then
  echo "$BODY"
fi

python3 - "$HUB_URL" "$LEVEL" "$TITLE" "$BODY" <<'PY'
import json, os, sys, urllib.request
url, level, title, body = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = json.dumps({
    "source": "host",
    "level": level,
    "title": title[:200],
    "body": body[:10000] or None,
}).encode()
headers = {"Content-Type": "application/json"}
# 内部通信の共有トークン（fail-closed。未設定だとハブが 403 を返す＝journald のみに残る）
token = os.environ.get("INTERNAL_TOKEN")
if token:
    headers["X-Internal-Token"] = token
req = urllib.request.Request(url.rstrip("/") + "/internal/notify", data=data,
                             headers=headers)
try:
    urllib.request.urlopen(req, timeout=10)
    print("✅ 通知ハブへ送信")
except Exception as e:
    print(f"⚠️ 通知ハブへの送信失敗（journald のみ）: {e}", file=sys.stderr)
PY
