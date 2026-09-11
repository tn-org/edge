# The optional host mode, with its default, its validation and the compose arguments it
# implies, in one place. Sourced by the scripts that behave differently per mode (not
# executable on its own).
#
#   EDGE_TLS_MODE=letsencrypt|origin-ca   where the certificates come from
#
# letsencrypt is the default and what every host did before the key existed. The mode
# also decides whether the CrowdSec container runs: it does with letsencrypt, and it
# retires with origin-ca — origin-ca means the host sits behind Cloudflare with the
# security group admitting only Cloudflare, so edge-level IP banning is redundant there.
# There is deliberately no separate switch for it: a knob nobody sets is dead weight.
# If a host ever needs banning behind Cloudflare, reintroduce one then.

# Read the key straight out of .env and check its value.
#   $1 = repo root (default: $ROOT_DIR, else the current directory)
# Only this key is read. The scripts that ask for the mode also run as root from the
# systemd timers, and there is no reason for them to hold the LAPI key or the dashboard
# password as well, which sourcing the whole file would do.
# A value already in the environment (a caller that did source .env) is kept.
edge_load_modes() {
  local root="${1:-${ROOT_DIR:-.}}" value

  if [ -f "$root/.env" ]; then
    value="$(sed -n 's/^EDGE_TLS_MODE=//p' "$root/.env" | head -1 | tr -d "\"' ")"
    [ -n "$value" ] && EDGE_TLS_MODE="$value"
    # The switch this derivation replaced (removed 2026-09-11). A host still carrying the
    # line must hear that it stopped doing anything, not discover it during an incident.
    if grep -q '^EDGE_CROWDSEC=' "$root/.env"; then
      echo "EDGE_CROWDSEC has been removed: CrowdSec now follows EDGE_TLS_MODE" >&2
      echo "(runs with letsencrypt, retires with origin-ca). Delete the line from .env" >&2
      return 1
    fi
  fi
  EDGE_TLS_MODE="${EDGE_TLS_MODE:-letsencrypt}"

  # A typo must stop the run. Falling back to the default would quietly leave the host in
  # the mode it was trying to leave.
  case "$EDGE_TLS_MODE" in
    letsencrypt | origin-ca) ;;
    *)
      echo "EDGE_TLS_MODE in .env must be letsencrypt or origin-ca (got: $EDGE_TLS_MODE)" >&2
      return 1
      ;;
  esac
  return 0
}

# Does the CrowdSec container run on this host? Call edge_load_modes first.
crowdsec_enabled() { [ "${EDGE_TLS_MODE:-letsencrypt}" != "origin-ca" ]; }

# Extra arguments for `docker compose up` (empty with letsencrypt, so the command is
# unchanged). Use unquoted: edge_compose_up_args either expands to nothing or to two words.
#
# Why not a compose profile: enabling a profile on the command line *replaces*
# COMPOSE_PROFILES from .env instead of adding to it, which would silently drop the db
# profile on every host that runs the shared PostgreSQL — and `up --remove-orphans` in
# deploy-host.sh would then delete that running container. Scaling the service to zero
# needs no profile: it removes the CrowdSec container if one is there and leaves the rest
# of the project, db profile included, exactly as it is.
edge_compose_up_args() {
  crowdsec_enabled || printf '%s' "--scale crowdsec=0"
}
