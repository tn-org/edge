#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Apply the host layer (what `make update` and edge-update.service actually run).
# Updating git happens outside this script, in the step before it, because a host that has
# not updated yet does not have the new version of this file.
#
# Order:
#   1. Substitute .env values into the config files (traefik/generated, crowdsec/generated)
#   2. Bring compose in line with the current definition. Containers for services that no
#      longer exist in the compose file are cleared with --remove-orphans.
#   3. Recreate containers only if the static config changed.
#
# Routing (domains and upstreams) lives in the applications' compose labels and Traefik
# picks it up from docker events. Middlewares and TLS settings (traefik/dynamic/) are
# watched by Traefik as well, so this script has nothing to do for either. A recreate is
# only needed after a change to Traefik's static config or the CrowdSec config.

# The host mode decides whether the CrowdSec container is part of the stack at all
. ./scripts/mode-lib.sh
edge_load_modes . || exit 1

STATE_FILE=".state/config-hash"

# Only look at config that requires a recreate. Dynamic config and the allowlist are
# watched or applied separately, so they are not included.
config_hash() {
  cat traefik/generated/traefik.yml crowdsec/acquis.yaml crowdsec/config.yaml.local 2>/dev/null \
    | sha256sum | cut -d' ' -f1
}

./scripts/render-config.sh

new_hash="$(config_hash)"
old_hash="$(cat "$STATE_FILE" 2>/dev/null || true)"

# Unquoted on purpose: edge_compose_up_args expands to nothing on letsencrypt hosts
sudo docker compose up -d --remove-orphans $(edge_compose_up_args)

# With CrowdSec off there is no container to restart, and naming one that is not running
# would fail the whole update
restart_services="traefik"
if crowdsec_enabled; then
  restart_services="traefik crowdsec"
fi

if [ "$new_hash" != "$old_hash" ]; then
  echo "Static config changed, recreating containers"
  sudo docker compose restart $restart_services
  mkdir -p "$(dirname "$STATE_FILE")"
  printf '%s' "$new_hash" > "$STATE_FILE"
else
  echo "Static config unchanged (no recreate)"
fi

# ---- Verify, and roll back a bad update -------------------------------------
# Applying is not the goal; serving is. Prove every labelled hostname still answers
# TLS (scripts/verify-routes.sh). If it does not:
#   - make update passes the commit it started from in EDGE_UPDATE_PREV. Reset back
#     to it and re-apply once (the old script version, EDGE_UPDATE_ROLLED_BACK guards
#     the recursion). A break caused by the new commit heals; a break caused by host
#     state (.env, certs/) stays, which the second verify then reports.
#   - Either way exit non-zero: the systemd unit fails and OnFailure= raises an error
#     notice through the file channel (mailed by the ops console).
if ! ./scripts/verify-routes.sh; then
  prev="${EDGE_UPDATE_PREV:-}"
  if [ -n "$prev" ] && [ -z "${EDGE_UPDATE_ROLLED_BACK:-}" ] \
    && [ "$prev" != "$(git rev-parse HEAD)" ]; then
    echo "Routing broken after update; rolling back to $prev" >&2
    ./scripts/notify.sh --error "edge update broke routing; rolled back to $prev" <<EOF
verify-routes failed after applying $(git rev-parse HEAD).
Rolled back to $prev and re-applied. If the second verify also failed, the cause
is host state (.env, certs/), not the update; see the unit log.
EOF
    git reset --hard "$prev"
    EDGE_UPDATE_ROLLED_BACK=1 ./scripts/deploy-host.sh || true
  else
    ./scripts/notify.sh --error "edge routing verification failed" <<EOF
verify-routes failed on $(git rev-parse HEAD) with no rollback target
(manual run, or already rolled back). See the unit log on the host.
EOF
  fi
  exit 1
fi

echo "Host layer applied"
