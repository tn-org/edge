#!/bin/bash
# Install the weekly unused-image cleanup timer (first run only)
# Installs the .service, .timer and notify-failure@ units and enables the timer.
# Usage: ./setup-docker-prune.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

# Remove a unit from earlier versions. Builds run in CI, so only the cleanup remains on the
# host; left in place, the old unit would keep building every week.
for old in base-refresh.timer base-refresh.service; do
  if systemctl list-unit-files "$old" >/dev/null 2>&1 && [ -f "/etc/systemd/system/$old" ]; then
    echo "Removing old unit: $old"
    sudo systemctl disable --now "$old" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/$old"
  fi
done

echo "Installing systemd units..."
for unit in docker-prune.service docker-prune.timer notify-failure@.service; do
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
echo "Enabling docker-prune.timer..."
sudo systemctl enable --now docker-prune.timer

echo ""
echo "Checking the timer..."
systemctl list-timers docker-prune.timer --no-pager || true

echo ""
echo "Weekly unused image cleanup configured"
echo "Run it now: sudo systemctl start docker-prune.service"
echo "Check the outcome with: journalctl -u docker-prune -f"
