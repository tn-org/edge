#!/bin/bash
# Apply the host-side configuration (safe to run any number of times)
#
# Installs this repo's config files under /etc and enables the systemd timers.
# `make update` only follows git and applies compose, so changes under /etc and to systemd
# units need this run by hand.
#
# setup-update (the auto-follow timer) is only installed, never enabled. Hosts that should
# follow automatically enable it as described in the README.
#
# Usage: ./host-apply.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

for step in \
  setup-logs \
  setup-auto-patch \
  setup-bans \
  setup-docker-prune \
  setup-disk-usage \
  setup-certs \
  setup-host-sync \
  setup-update
do
  echo ""
  echo "--------- $step ---------"
  "$SCRIPT_DIR/$step.sh"
done

echo ""
echo "--------- Sync to the ops console ---------"
sudo systemctl start host-sync.service && echo "Synced"

echo ""
echo "Host configuration applied"
