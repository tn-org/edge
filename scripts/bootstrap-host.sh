#!/usr/bin/env bash
# Prepare a fresh Amazon Linux 2023 host for edge: install the container runtime
# and helpers. Run once right after cloning this repo; safe to re-run (idempotent).
#
#   sudo dnf install -y git
#   sudo mkdir -p /app && sudo chown "$USER:$USER" /app
#   git clone https://github.com/tn-org/edge.git /app/edge
#   cd /app/edge && bash scripts/bootstrap-host.sh
#
# When it finishes, log out and back in once (the docker group membership only
# applies to new sessions), then continue with:
#   cp .env.example .env && make env && make setup
set -euo pipefail

echo "Installing packages (git, make, docker)..."
sudo dnf install -y git make docker

echo "Enabling docker..."
sudo systemctl enable --now docker

echo "Adding $USER to the docker group..."
sudo usermod -aG docker "$USER"

# docker compose is a CLI plugin; AL2023's docker rpm does not ship it
if docker compose version >/dev/null 2>&1; then
  echo "docker compose already installed"
else
  arch="$(uname -m)" # x86_64 / aarch64 both exist on EC2
  echo "Installing the docker compose plugin (${arch})..."
  sudo mkdir -p /usr/local/lib/docker/cli-plugins
  sudo curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi

echo ""
echo "Done. Next steps:"
echo "  1. exit and open a new session (picks up the docker group)"
echo "  2. cd /app/edge && cp .env.example .env && make env"
echo "  3. make setup"
