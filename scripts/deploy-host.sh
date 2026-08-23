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

sudo docker compose up -d --remove-orphans

if [ "$new_hash" != "$old_hash" ]; then
  echo "Static config changed, recreating containers"
  sudo docker compose restart traefik crowdsec
  mkdir -p "$(dirname "$STATE_FILE")"
  printf '%s' "$new_hash" > "$STATE_FILE"
else
  echo "Static config unchanged (no recreate)"
fi

echo "Host layer applied"
