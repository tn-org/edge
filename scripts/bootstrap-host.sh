#!/usr/bin/env bash
# Bring a fresh Amazon Linux 2023 host to a running edge in one go: install the
# container runtime, write .env (generating the secrets) and run the full setup.
#
#   sudo dnf install -y git
#   sudo mkdir -p /app && sudo chown "$(id -un):$(id -gn)" /app
#   git clone https://github.com/tn-org/edge.git /app/edge
#   cd /app/edge && bash scripts/bootstrap-host.sh
#
# Prompts for the ACME e-mail and the shared-PostgreSQL choice; pass
# --acme-email <addr> and --db / --no-db to run unattended, or --prepare-only to
# stop after the runtime install (then continue by hand: cp .env.example .env,
# make env, make setup). Idempotent: existing .env values are kept, only empty
# ones are filled in.
#
# Afterwards log out and back in once so your own shell picks up the docker
# group; the script itself does not need it (it runs make setup through sg).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ACME_EMAIL_OPT=""
DB_OPT=""
PREPARE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --acme-email) ACME_EMAIL_OPT="${2:?--acme-email needs a value}"; shift 2 ;;
    --db) DB_OPT=y; shift ;;
    --no-db) DB_OPT=n; shift ;;
    --prepare-only) PREPARE_ONLY=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

echo "Installing packages (git, make, docker)..."
sudo dnf install -y git make docker

echo "Enabling docker..."
sudo systemctl enable --now docker

# $USER can be unset in a Session Manager shell; derive the name instead
user="$(id -un)"
echo "Adding ${user} to the docker group..."
sudo usermod -aG docker "${user}"

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

if [ "${PREPARE_ONLY}" = 1 ]; then
  echo ""
  echo "Runtime prepared (--prepare-only). Continue with:"
  echo "  cp .env.example .env && make env && make setup"
  exit 0
fi

# ---- .env -------------------------------------------------------------------
# Fill only keys that are still empty or carry the example placeholder, so an
# existing .env is never clobbered and the script can be re-run freely.
[ -f .env ] || cp .env.example .env

env_get() { grep -E "^$1=" .env | head -1 | cut -d= -f2-; }
env_set() {
  if grep -qE "^$1=" .env; then
    sed -i "s|^$1=.*|$1=$2|" .env
  else
    printf '%s=%s\n' "$1" "$2" >>.env
  fi
}

# This script only ever targets servers, never a workstation checkout
env_set APP_ENV production

acme="$(env_get ACME_EMAIL)"
if [ -z "${acme}" ] || [ "${acme}" = "your-email@example.com" ]; then
  acme="${ACME_EMAIL_OPT}"
  while [ -z "${acme}" ]; do
    read -rp "ACME e-mail (where Let's Encrypt expiry notices go): " acme
  done
  env_set ACME_EMAIL "${acme}"
fi

if [ -z "$(env_get CROWDSEC_BOUNCER_KEY)" ]; then
  env_set CROWDSEC_BOUNCER_KEY "$(openssl rand -hex 32)"
fi

if [ -n "$(env_get COMPOSE_PROFILES)" ]; then
  : # already decided in .env; leave as is
else
  db="${DB_OPT}"
  if [ -z "${db}" ]; then
    read -rp "Run the shared PostgreSQL on this host (db profile)? [Y/n] " answer
    case "${answer:-y}" in [nN]*) db=n ;; *) db=y ;; esac
  fi
  if [ "${db}" = y ]; then
    env_set COMPOSE_PROFILES db
    [ -n "$(env_get POSTGRES_PASSWORD)" ] || env_set POSTGRES_PASSWORD "$(openssl rand -hex 32)"
  fi
fi

# ---- full setup -------------------------------------------------------------
# The docker group added above only applies to new sessions; sg runs make setup
# with the group right away so no re-login is needed.
if docker info >/dev/null 2>&1; then
  make setup
else
  sg docker -c "make setup"
fi

echo ""
echo "Done. Log out and back in once so your own shell can use docker, then check:"
echo "  make ps"
