#!/bin/bash
# Install the daily certificate expiry report timer (first run only)
# Installs the .service, .timer and notify-failure@ units and enables the timer.
# Usage: ./setup-certs.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

echo "Installing systemd units..."
for unit in report-certs.service report-certs.timer notify-failure@.service; do
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
echo "Enabling report-certs.timer..."
sudo systemctl enable --now report-certs.timer

echo ""
echo "Checking the timer..."
systemctl list-timers report-certs.timer --no-pager || true

echo ""
echo "Daily certificate expiry report configured"
echo "Run it now: sudo systemctl start report-certs.service"
echo "Check the outcome with: journalctl -u report-certs -n 30"
