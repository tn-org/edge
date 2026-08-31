#!/bin/bash
# Notification script. Writes the notice into the host's file channel
# (sync/state/events/YYYY-MM-DD.ndjson, one JSON object per line) and keeps the full text
# in journald. The ops console reads the file when it wants to; nothing is sent anywhere,
# so a host without a console behaves identically.
# Usage:
#   notify.sh --failed <unit>          # for systemd OnFailure (error notice plus a journalctl hint)
#   notify.sh --error <title...>       # error notice (forwarded as mail immediately)
#   notify.sh --warn <title...>        # warning notice (also listed in the daily report)
#   notify.sh <title...>               # free-form message (info); the body comes from stdin:
#   notify.sh "title" <<EOF ... EOF
#
# See scripts/sync-lib.sh for the layout of the channel.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
. "$SCRIPT_DIR/sync-lib.sh"

# The host name is not added; the "host" source field is enough.
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
  # The body only comes from stdin (a pipe or heredoc). Without one, record just the title.
  BODY=""
  if [ ! -t 0 ]; then
    BODY="$(cat)"
  fi
fi

# Keep the full text in journald as well, so nothing depends on the file being read
echo "$TITLE"
if [ -n "$BODY" ] && [ "$BODY" != "$TITLE" ]; then
  echo "$BODY"
fi

sync_append_event "$LEVEL" "$TITLE" "$BODY" ""
