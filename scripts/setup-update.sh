#!/bin/bash
# Install the automatic update units (make update daily at 05:00 Asia/Tokyo)
# Places the .service, .timer and notify-failure@ units on the host without enabling the
# timer. Hosts that should follow automatically enable it afterwards:
#   sudo systemctl enable --now edge-update.timer
# Usage: ./setup-update.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

# git refuses a repo owned by another user as "dubious ownership"; run as the repo owner
RUN_AS="$(stat -c '%U' "$ROOT_DIR" 2>/dev/null || stat -f '%Su' "$ROOT_DIR")"

echo "Installing systemd units..."
for unit in edge-update.service edge-update.timer notify-failure@.service; do
  sudo cp "$ROOT_DIR/systemd/$unit" "/etc/systemd/system/$unit"
  # Replace the placeholder in ExecStart/EnvironmentFile/WorkingDirectory with the real path
  sudo sed -i "s|/path/to/edge|$ROOT_DIR|g" "/etc/systemd/system/$unit"
  # Fill in the user to run as (the repo owner)
  sudo sed -i "s|__RUN_AS__|$RUN_AS|g" "/etc/systemd/system/$unit"
  sudo chmod 644 "/etc/systemd/system/$unit"
  echo "  $unit"
done

echo ""
echo "Reloading systemd..."
sudo systemctl daemon-reload

echo ""
if systemctl is-enabled edge-update.timer >/dev/null 2>&1; then
  echo "edge-update.timer is enabled; restarting it to pick up the new definition"
  sudo systemctl restart edge-update.timer
  systemctl list-timers edge-update.timer --no-pager || true
else
  echo "edge-update.timer installed only (not enabled by default)"
  echo "To follow automatically: sudo systemctl enable --now edge-update.timer"
fi

echo ""
echo "Automatic update configured (running as: $RUN_AS)"
echo "Run it now: sudo systemctl start edge-update.service"
echo "Check the outcome with: journalctl -u edge-update -n 30"
