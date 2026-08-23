#!/bin/bash
# Set up automatic OS security patching (first run only; Amazon Linux 2023)
# Installs dnf-automatic and configures it to apply security updates only, never rebooting.
# Usage: ./setup-auto-patch.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

echo "Installing dnf-automatic..."
sudo dnf install -y dnf-automatic

echo ""
echo "Installing the config (/etc/dnf/automatic.conf)..."
sudo cp "$ROOT_DIR/auto-patch/automatic.conf" /etc/dnf/automatic.conf
sudo sed -i "s|/path/to/edge|$ROOT_DIR|g" /etc/dnf/automatic.conf
# The notification sender is the host name; do not hard-code a name, since several hosts
# run the same repo
sudo sed -i "s|__HOSTNAME__|$(hostname)|g" /etc/dnf/automatic.conf
sudo chmod 644 /etc/dnf/automatic.conf

echo ""
echo "Installing the schedule override (quiet night-time slot)..."
sudo mkdir -p /etc/systemd/system/dnf-automatic.timer.d
sudo cp "$ROOT_DIR/systemd/dnf-automatic.timer.d/override.conf" \
  /etc/systemd/system/dnf-automatic.timer.d/override.conf
sudo chmod 644 /etc/systemd/system/dnf-automatic.timer.d/override.conf

echo ""
echo "Installing failure notification (through notify-failure@ to the hub)..."
sudo cp "$ROOT_DIR/systemd/notify-failure@.service" /etc/systemd/system/notify-failure@.service
sudo sed -i "s|/path/to/edge|$ROOT_DIR|g" /etc/systemd/system/notify-failure@.service
sudo chmod 644 /etc/systemd/system/notify-failure@.service
sudo mkdir -p /etc/systemd/system/dnf-automatic.service.d
sudo cp "$ROOT_DIR/systemd/dnf-automatic.service.d/override.conf" \
  /etc/systemd/system/dnf-automatic.service.d/override.conf
sudo chmod 644 /etc/systemd/system/dnf-automatic.service.d/override.conf
sudo systemctl daemon-reload

echo ""
echo "Enabling dnf-automatic.timer..."
sudo systemctl enable --now dnf-automatic.timer

echo ""
echo "Checking the timer..."
systemctl list-timers dnf-automatic.timer --no-pager || true

echo ""
echo "Automatic OS security patching configured"
echo "Security updates only, never rebooting; kernel updates wait for a manual reboot window"
echo "Check the outcome with: journalctl -u dnf-automatic"
