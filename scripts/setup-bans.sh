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
. "$SCRIPT_DIR/mode-lib.sh"

cd "$ROOT_DIR"

edge_load_modes "$ROOT_DIR" || exit 1

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

# ---- Nothing to set up when there is no blocking ----------------------------
# Say so in one line instead of installing a timer whose daily run has nothing to report.
# A timer left over from the previous mode is removed, so the console's task list shows
# what the host actually runs.
if ! crowdsec_enabled; then
  echo ""
  echo "CrowdSec does not run on this host ($(crowdsec_off_reason)): the blocking report timer is not installed"
  if systemctl list-unit-files --no-legend report-bans.timer 2>/dev/null | grep -q report-bans; then
    echo "Removing the report-bans timer left from the previous mode..."
    sudo systemctl disable --now report-bans.timer 2>/dev/null || true
    sudo rm -f /etc/systemd/system/report-bans.timer /etc/systemd/system/report-bans.service
    sudo systemctl daemon-reload
  fi
  echo ""
  echo "Blocking setup skipped (it comes back once CrowdSec runs: EDGE_TLS_MODE=letsencrypt and EDGE_CROWDSEC=auto)"
  exit 0
fi

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
