#!/bin/bash
# Host-side setup for blocking (safe to run any number of times)
#
# CrowdSec itself is a docker container, so there is nothing to install. What is set up
# here is the daily report timer, plus cleanup of units from earlier versions.
#
# Usage: ./setup-bans.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

# ---- Remove units from earlier versions ------------------------------------
# Left in place, they keep creating blocks of their own alongside CrowdSec, and the two
# together make the cause of any block impossible to read.
if systemctl list-unit-files fail2ban.service > /dev/null 2>&1 \
  && systemctl list-unit-files --no-legend fail2ban.service 2>/dev/null | grep -q fail2ban; then
  echo "Stopping and disabling the old fail2ban..."
  sudo systemctl disable --now fail2ban 2>/dev/null || true
fi

for unit in report-fail2ban.timer cert-renew.timer ipset-persist.service; do
  if systemctl list-unit-files --no-legend "$unit" 2>/dev/null | grep -q "$unit"; then
    echo "Stopping and removing the old $unit..."
    sudo systemctl disable --now "$unit" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/$unit"
  fi
done
sudo rm -f /etc/systemd/system/report-fail2ban.service /etc/systemd/system/cert-renew.service

# ---- Daily report timer -----------------------------------------------------
echo ""
echo "Installing systemd units..."
for unit in report-bans.service report-bans.timer notify-failure@.service; do
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
echo "Enabling report-bans.timer..."
sudo systemctl enable --now report-bans.timer

echo ""
echo "Checking the timer..."
systemctl list-timers report-bans.timer --no-pager || true

echo ""
echo "Blocking setup complete"
echo "Blocking status: make bans"
echo "CrowdSec health: sudo docker compose exec crowdsec cscli metrics"
