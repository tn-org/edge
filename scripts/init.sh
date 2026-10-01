#!/bin/bash
# Initialisation (docker network, render config, start the stack)
#
# Traefik's ACME resolver fetches certificates itself once it is up, so nothing is issued
# here. Routing comes from the applications' compose labels, so no virtual host is created
# here either.
#
# Usage: ./init.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

echo "Initialising..."

# The real name of the shared network; must match the compose default (${EDGE_NETWORK:-edge})
[ -f .env ] && { set -a; . ./.env; set +a; }
EDGE_NETWORK="${EDGE_NETWORK:-edge}"

# The host modes decide whether the CrowdSec container is started at all
. "$SCRIPT_DIR/mode-lib.sh"
edge_load_modes "$ROOT_DIR" || exit 1

# Create the network. Every application's compose file joins it as external.
docker network create "$EDGE_NETWORK" 2>/dev/null || true
echo "Network ready ($EDGE_NETWORK)"

# Substitute .env values into the config files (stops here when something is unset)
"$SCRIPT_DIR/render-config.sh"

# Unquoted on purpose: edge_compose_up_args expands to nothing when CrowdSec runs
docker compose up -d $(edge_compose_up_args)
if crowdsec_enabled; then
  echo "Traefik and CrowdSec started"
else
  echo "Traefik started (no CrowdSec on this host: $(crowdsec_off_reason))"
fi

echo ""
echo "Initialisation complete"
if [ "$EDGE_TLS_MODE" = "letsencrypt" ]; then
  echo "Certificate status: docker compose logs traefik | grep -i acme"
else
  echo "Certificates:       certs/, listed in traefik/dynamic/generated-tls.yml (origin-ca)"
fi
if crowdsec_enabled; then
  echo "CrowdSec health:    docker compose exec crowdsec cscli metrics"
fi
