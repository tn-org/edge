#!/bin/bash
# First-run wizard (called by make setup; repeatable and idempotent)
#
# Steps:
#   1. Prepare .env: copy from .env.example when missing, then settle APP_ENV interactively
#      if it is undecided (without a tty, print usage and exit 1 so automation never hangs)
#   2. [only when APP_ENV is not local] initialise the host:
#      init.sh (network, config, start the stack), then host-apply.sh (/etc and systemd)
#   3. Start the stack: up (Traefik and CrowdSec)
#   4. Verify: check-env, ps, closing message
#
# Usage: scripts/setup.sh

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/choose.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

# ---- 1. Prepare .env -------------------------------------------------------
created=0
if [ ! -f .env ]; then
  cp .env.example .env
  created=1
  echo "Created .env from .env.example"
fi

app_env="$(grep '^APP_ENV=' .env | head -1 | cut -d'=' -f2 | tr -d '"'"'" || true)"

# Ask when the file was just created (still at the example default of local) or APP_ENV is empty
if [ "$created" = "1" ] || [ -z "$app_env" ]; then
  if [ ! -t 0 ]; then
    echo "APP_ENV is undecided (cannot ask in a non-interactive environment)" >&2
    echo "Usage: set APP_ENV to local|staging|production in .env, then run make setup again" >&2
    exit 1
  fi
  app_env=$(choose "APP_ENV (what kind of environment this is)" local staging production)
  if [ -z "$app_env" ]; then
    echo "No APP_ENV was selected" >&2
    exit 1
  fi
  if grep -qE '^APP_ENV=' .env; then
    sed -i.bak "s/^APP_ENV=.*/APP_ENV=$app_env/" .env && rm -f .env.bak
  else
    printf 'APP_ENV=%s\n' "$app_env" >> .env
  fi
  echo "Set APP_ENV=$app_env in .env"
else
  echo "APP_ENV=$app_env (already set, leaving it alone)"
fi

# ---- 2. Host initialisation (server only) ----------------------------------
if [ "$app_env" != "local" ]; then
  echo ""
  echo "Initialising the host (APP_ENV=$app_env)..."
  "$SCRIPT_DIR/init.sh"
  "$SCRIPT_DIR/host-apply.sh"
fi

# ---- 3. Start the stack -----------------------------------------------------
echo ""
echo "Starting the stack..."
make --no-print-directory up

# ---- 4. Verify --------------------------------------------------------------
echo ""
echo "Verifying..."
"$SCRIPT_DIR/check-env.sh" || echo "check-env reported warnings (see above)"
make --no-print-directory ps
echo ""
echo "Setup complete"
. "$SCRIPT_DIR/mode-lib.sh"
if edge_load_modes "$ROOT_DIR" && [ "$EDGE_TLS_MODE" = "origin-ca" ]; then
  echo "Certificates come from certs/ (EDGE_TLS_MODE=origin-ca); traefik/dynamic/generated-tls.yml lists them"
else
  echo "Traefik's ACME resolver obtains certificates on its own: docker compose logs traefik | grep -i acme"
fi
