#!/bin/bash
# Install the hourly access log count per hostname and day (safe to run any number of times)
# Installs the .service, .timer and notify-failure@ units and enables the timer.
# Usage: ./setup-traffic.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

echo "Installing systemd units..."
for unit in report-traffic.service report-traffic.timer notify-failure@.service; do
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
echo "Enabling report-traffic.timer..."
sudo systemctl enable --now report-traffic.timer

echo ""
echo "Checking the timer..."
systemctl list-timers report-traffic.timer --no-pager || true

echo ""
echo "Hourly access log count configured"
echo "Run it now: sudo systemctl start report-traffic.service"
echo "Check the outcome with: journalctl -u report-traffic -n 30"
