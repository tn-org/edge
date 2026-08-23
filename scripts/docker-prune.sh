#!/bin/bash
# Weekly cleanup of unused docker images (run by docker-prune.service, or by hand)
#
# Every deployment pulls a new image, so previous versions accumulate on the host. Images
# in use by a running container are never removed, so nothing running is affected.
#
# Builds run in CI, not on the host: building here exhausts memory and takes everything
# down, so do not move image builds into this job.
#
# Usage: ./docker-prune.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "===== Unused image cleanup: start ====="

# Deliberately image prune only. system prune would also remove stopped containers, unused
# networks and the build cache: a container stopped on purpose would disappear over the
# weekend, and a run while everything is down would take the shared network (EDGE_NETWORK)
# with it, so the next start fails with "network not found".
# The only target here is the old images that pile up with each deployment.
#
# -a: remove tagged images no container uses, not just dangling ones
PRUNE_OUT="$(docker image prune -af)"
echo "$PRUNE_OUT"
RECLAIMED="$(printf '%s\n' "$PRUNE_OUT" | grep -i 'reclaimed' | tail -1 || true)"

echo ""
echo "===== Unused image cleanup: done ====="

# Report the result to the notification hub (journald only when unconfigured). A failed
# notification must not fail the job.
# It arrives every week, so a missing week means the timer stopped.
"$SCRIPT_DIR/notify.sh" "Unused image cleanup" <<EOF || true
Result: success
Duration: $((SECONDS / 60))m $((SECONDS % 60))s
Reclaimed: ${RECLAIMED:-prune done}
EOF
