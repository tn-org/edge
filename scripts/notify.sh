#!/bin/bash
# Notification script. Posts to the notification hub (the ops console's /internal/notify);
# if that is unreachable the message stays in journald.
# Usage:
#   notify.sh --failed <unit>          # for systemd OnFailure (error notice plus a journalctl hint)
#   notify.sh --error <title...>       # error notice (forwarded as mail immediately)
#   notify.sh --warn <title...>        # warning notice (also listed in the daily report)
#   notify.sh <title...>               # free-form message (info); the body comes from stdin:
#   notify.sh "title" <<EOF ... EOF
#
# The hub runs on the same host and its own compose file publishes it on 127.0.0.1:9090,
# loopback only. Point somewhere else with OPS_NOTIFY_URL in .env.

set -uo pipefail

# Read the edge .env (supplies INTERNAL_TOKEN and OPS_NOTIFY_URL, so the values are there
# even when systemd OnFailure invoked us). Same approach as report.sh; reading it twice
# does no harm.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
[ -f "$ROOT_DIR/.env" ] && { set -a; . "$ROOT_DIR/.env"; set +a; }

# The host name is not added; the "host" source field is enough
HUB_URL="${OPS_NOTIFY_URL:-http://127.0.0.1:9090}"

if [ "${1:-}" = "--failed" ]; then
  # The systemd OnFailure path. Build a fixed message from the unit name passed as %i.
  UNIT="${2:-unknown.unit}"
  LEVEL="error"
  TITLE="systemd unit failed: $UNIT"
  # The host name is not needed on every line: with the default format half of each line
  # is the internal host name and the message becomes unreadable.
  BODY="$(journalctl -u "$UNIT" -n 15 --no-pager -o short-iso --no-hostname 2>/dev/null || true)
Details: journalctl -u $UNIT -n 50"
else
  LEVEL="info"
  case "${1:-}" in
    --warn)  LEVEL="warning"; shift ;;
    --error) LEVEL="error";   shift ;;
  esac
  TITLE="$*"
  # The body only comes from stdin (a pipe or heredoc). Without one, send just the title.
  BODY=""
  if [ ! -t 0 ]; then
    BODY="$(cat)"
  fi
fi

# Keep the full text in journald, so nothing is lost if the hub is unreachable
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
# Shared token for internal calls (fail-closed: without it the hub returns 403 and the
# message only stays in journald)
token = os.environ.get("INTERNAL_TOKEN")
if token:
    headers["X-Internal-Token"] = token
req = urllib.request.Request(url.rstrip("/") + "/internal/notify", data=data,
                             headers=headers)
try:
    urllib.request.urlopen(req, timeout=10)
    print("Sent to the notification hub")
except Exception as e:
    print(f"Failed to reach the notification hub (journald only): {e}", file=sys.stderr)
PY
