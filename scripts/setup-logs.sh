#!/bin/bash
# Set up log rotation (safe to run any number of times)
# Usage: ./setup-logs.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

echo "Creating the log directory..."
# A single Traefik access log; no per-domain directories, since the destination is in the
# RequestHost field of the JSON.
mkdir -p logs/traefik
echo "  logs/traefik"

echo ""
echo "Removing the rotation config from earlier versions..."
sudo rm -f /etc/logrotate.d/nginx-edge

echo ""
echo "Installing the logrotate config..."
sudo cp "$ROOT_DIR/logrotate/traefik" /etc/logrotate.d/traefik
sudo sed -i "s|/path/to/edge|$ROOT_DIR|g" /etc/logrotate.d/traefik
sudo chmod 644 /etc/logrotate.d/traefik

echo ""
echo "Testing the config..."
sudo logrotate -d /etc/logrotate.d/traefik 2>&1 | head -10
echo "..."

echo ""
echo "Log setup complete"
