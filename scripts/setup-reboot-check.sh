#!/bin/bash
# Install the pending-reboot check timer (first run only)
# Installs needs-restarting (dnf-utils), places the .service and .timer units and enables
# the timer.
# Usage: ./setup-reboot-check.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

echo "Installing dnf-utils (which provides needs-restarting)..."
sudo dnf install -y dnf-utils

echo ""
echo "Installing systemd units..."
for unit in report-reboot-check.service report-reboot-check.timer notify-failure@.service; do
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
echo "Enabling report-reboot-check.timer..."
sudo systemctl enable --now report-reboot-check.timer

echo ""
echo "Checking the timer..."
systemctl list-timers report-reboot-check.timer --no-pager || true

echo ""
echo "Pending reboot check configured"
echo "Run it now: sudo systemctl start report-reboot-check.service"
echo "A warning arrives every morning while a reboot is due, and stops once you reboot"
