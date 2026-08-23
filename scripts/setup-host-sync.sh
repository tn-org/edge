#!/bin/bash
# Install the host state sync timer (safe to run any number of times)
# Installs the .service, .timer and notify-failure@ units and enables the timer.
# Removes the unit from an earlier version if it is still present, so the job cannot run twice.
# Usage: ./setup-host-sync.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

# Clean up the unit from an earlier version. Two timers running the same job fight over the
# operations and the outcome becomes undefined.
if systemctl list-unit-files f2b-sync.timer >/dev/null 2>&1 \
  && systemctl list-unit-files --no-legend f2b-sync.timer 2>/dev/null | grep -q f2b-sync; then
  echo "Stopping and removing the old f2b-sync..."
  sudo systemctl disable --now f2b-sync.timer 2>/dev/null || true
  sudo rm -f /etc/systemd/system/f2b-sync.timer /etc/systemd/system/f2b-sync.service
fi

echo "Installing systemd units..."
for unit in host-sync.service host-sync.timer notify-failure@.service; do
  sudo cp "$ROOT_DIR/systemd/$unit" "/etc/systemd/system/$unit"
  # Replace the placeholder in ExecStart/EnvironmentFile/WorkingDirectory with the real path
  sudo sed -i "s|/path/to/edge|$ROOT_DIR|g" "/etc/systemd/system/$unit"
  sudo chmod 644 "/etc/systemd/system/$unit"
  echo "  $unit"
done

echo ""
echo "Reloading systemd..."
sudo systemctl daemon-reload

echo ""
echo "Enabling host-sync.timer..."
sudo systemctl enable --now host-sync.timer

echo ""
echo "Checking the timer..."
systemctl list-timers host-sync.timer --no-pager || true

echo ""
echo "Host state sync configured"
echo "Run it now: sudo systemctl start host-sync.service"
echo "Check the outcome with: journalctl -u host-sync -n 30"
