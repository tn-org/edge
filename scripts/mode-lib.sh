# The optional host modes, with their defaults, their validation and the compose arguments
# they imply, in one place. Sourced by the scripts that behave differently per mode (not
# executable on its own).
#
#   EDGE_TLS_MODE=letsencrypt|origin-ca   where the certificates come from
#   EDGE_CROWDSEC=auto|off                whether the CrowdSec container may run at all
#
# Both defaults are what every host did before these keys existed, so a .env that does not
# mention them behaves exactly as before.
#
# CrowdSec follows EDGE_TLS_MODE by default (auto): it runs with letsencrypt, and it
# retires with origin-ca — origin-ca means the host sits behind Cloudflare with the
# security group admitting only Cloudflare, so edge-level IP banning is redundant there.
#
# EDGE_CROWDSEC=off turns it off on a letsencrypt host as well. The key exists because a
# host can serve an application whose legitimate traffic matches the HTTP detection
# scenarios (many requests for extension-less image URLs at once, a run of 404s that the
# application returns by design); until the application changes, the host would keep
# blocking its own users. Off means exactly what origin-ca means for CrowdSec.
#
# There is deliberately no "on": no host needs banning behind Cloudflare, and a value
# nobody uses is dead weight. If such a host ever appears, add the value then.

# Read the two keys straight out of .env and check their values.
#   $1 = repo root (default: $ROOT_DIR, else the current directory)
# Only these two keys are read. The scripts that ask for a mode also run as root from the
# systemd timers, and there is no reason for them to hold the LAPI key or the dashboard
# password as well, which sourcing the whole file would do.
# A value already in the environment (a caller that did source .env) is kept.
edge_load_modes() {
  local root="${1:-${ROOT_DIR:-.}}" value

  if [ -f "$root/.env" ]; then
    value="$(sed -n 's/^EDGE_TLS_MODE=//p' "$root/.env" | head -1 | tr -d "\"' ")"
    [ -n "$value" ] && EDGE_TLS_MODE="$value"
    value="$(sed -n 's/^EDGE_CROWDSEC=//p' "$root/.env" | head -1 | tr -d "\"' ")"
    [ -n "$value" ] && EDGE_CROWDSEC="$value"
  fi
  EDGE_TLS_MODE="${EDGE_TLS_MODE:-letsencrypt}"
  EDGE_CROWDSEC="${EDGE_CROWDSEC:-auto}"

  # A typo must stop the run. Falling back to the default would quietly leave the host in
  # the mode it was trying to leave.
  case "$EDGE_TLS_MODE" in
    letsencrypt | origin-ca) ;;
    *)
      echo "EDGE_TLS_MODE in .env must be letsencrypt or origin-ca (got: $EDGE_TLS_MODE)" >&2
      return 1
      ;;
  esac
  case "$EDGE_CROWDSEC" in
    auto | off) ;;
    *)
      echo "EDGE_CROWDSEC in .env must be auto or off (got: $EDGE_CROWDSEC)" >&2
      return 1
      ;;
  esac
  return 0
}

# Does the CrowdSec container run on this host? Call edge_load_modes first.
# Only when EDGE_CROWDSEC is not off and the host is not behind Cloudflare (origin-ca).
crowdsec_enabled() {
  [ "${EDGE_CROWDSEC:-auto}" != "off" ] && [ "${EDGE_TLS_MODE:-letsencrypt}" != "origin-ca" ]
}

# Why CrowdSec does not run on this host, as one phrase for messages
# ("CrowdSec does not run on this host ($(crowdsec_off_reason))"). Only meaningful when
# crowdsec_enabled is false. EDGE_CROWDSEC=off is named first: it is the explicit choice,
# and it stays the reason even on an origin-ca host.
crowdsec_off_reason() {
  if [ "${EDGE_CROWDSEC:-auto}" = "off" ]; then
    printf '%s' "EDGE_CROWDSEC=off"
  else
    printf '%s' "EDGE_TLS_MODE=origin-ca, behind Cloudflare"
  fi
}

# Extra arguments for `docker compose up` (empty when CrowdSec runs, so the command is
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
