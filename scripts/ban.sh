#!/bin/bash
# Blocking and allowlist operations (what make ban and the console's operation requests
# both run).
#
# A block is a CrowdSec decision. The bouncer plugin in Traefik asks the LAPI and rejects
# the request, so only the application layer (HTTP) is affected.
# The allowlist source of truth is crowdsec/generated/allowlist.tsv, converted into a
# CrowdSec parser whitelist. An allowlisted IP never produces a decision at all.
#
# The operation names (list / ban / unban / allow / disallow / allowed) come from the
# fail2ban era and are kept, because the console queues requests using them.
#
# Usage:
#   ban.sh                    # choose interactively
#   ban.sh list               # list current blocks
#   ban.sh ban <ip>           # block manually (24h by default; override with BAN_DURATION)
#   ban.sh unban <ip>         # remove a block
#   ban.sh allow <ip> [note]  # add to the allowlist (and unblock if currently blocked)
#   ban.sh disallow <ip>      # remove from the allowlist
#   ban.sh allowed            # list the allowlist

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/choose.sh"
. "$SCRIPT_DIR/mode-lib.sh"

# Every operation here goes through the CrowdSec LAPI or the parser whitelist, and on a
# host without CrowdSec (origin-ca, or EDGE_CROWDSEC=off) neither exists. Stop with the
# reason rather than let cscli fail against a container that is not running.
edge_load_modes "$ROOT_DIR" || exit 1
if ! crowdsec_enabled; then
  echo "CrowdSec does not run on this host ($(crowdsec_off_reason)): nothing blocks here, so there is nothing to operate" >&2
  echo "Blocking runs only with EDGE_TLS_MODE=letsencrypt and EDGE_CROWDSEC=auto; behind Cloudflare, block at Cloudflare" >&2
  exit 1
fi

ALLOW_TSV="$ROOT_DIR/crowdsec/generated/allowlist.tsv"
# Duration of a manual block. CrowdSec's own scenarios use four hours to a day, so this
# stays in the same range. The record is kept permanently in the ops console, so the block
# itself does not need to be long lived.
BAN_DURATION="${BAN_DURATION:-24h}"

# The CrowdSec CLI only exists inside the container
cscli() {
  ( cd "$ROOT_DIR" && sudo docker compose exec -T crowdsec cscli "$@" )
}

# Make CrowdSec re-read the allowlist. It is parser config, so it needs a restart (seconds).
reload_allowlist() {
  "$SCRIPT_DIR/render-config.sh" allowlist || return 1
  ( cd "$ROOT_DIR" && sudo docker compose restart crowdsec > /dev/null )
}

# The IPs in the allowlist (comment lines excluded)
allowed_ips() {
  [ -f "$ALLOW_TSV" ] || return 0
  awk -F'\t' 'NF && $1 !~ /^#/ { print $1 }' "$ALLOW_TSV"
}

is_allowed() {
  allowed_ips | grep -qxF "$1"
}

# The currently blocked IPs, deduplicated
banned_ips() {
  cscli decisions list -o json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    raise SystemExit(0)
seen = set()
for item in data or []:
    nested = item.get("decisions")
    for d in (nested if isinstance(nested, list) else [item]):
        value = d.get("value")
        if value and value not in seen:
            seen.add(value)
            print(value)
' 2>/dev/null
}

# Ask when no argument was given; print usage and stop when not interactive.
# Pass the name of a function producing candidates as $2 to get a cursor selection when
# there are only a few.
ask_ip() {
  local given="${1:-}" from="${2:-}"
  if [ -n "$given" ]; then
    printf '%s' "$given"
    return 0
  fi
  if [ ! -t 0 ]; then
    echo "No IP given" >&2
    echo "Usage: make ban CMD=$CMD IP=<ip>" >&2
    exit 1
  fi

  if [ -n "$from" ]; then
    local candidates=()
    while IFS= read -r line; do
      [ -n "$line" ] && candidates+=("$line")
    done < <("$from")

    # A long list fills the screen, so fall back to typing it in
    if [ "${#candidates[@]}" -gt 0 ] && [ "${#candidates[@]}" -le 30 ]; then
      choose "IP" "${candidates[@]}"
      return $?
    fi
  fi

  read -rp "IP: " answer
  printf '%s' "$answer"
}

# Passing an unchecked value makes cscli fail quietly, leaving traffic through while you
# believe it is blocked.
# CrowdSec handles IPv6 and CIDR, so both are accepted.
require_ip() {
  local ip="$1"
  if [ -z "$ip" ]; then
    echo "IP is empty" >&2
    exit 1
  fi
  # Accept only IPv4, IPv6 and their CIDR forms; reject host names and anything with spaces
  if ! printf '%s' "$ip" | grep -qE '^([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9A-Fa-f:]+)(/[0-9]{1,3})?$'; then
    echo "Not a readable IP address: $ip" >&2
    exit 1
  fi
}

CMD="${1:-}"
if [ -z "$CMD" ]; then
  if [ ! -t 0 ]; then
    echo "Usage: make ban CMD=list|ban|unban|allow|disallow|allowed [IP=<ip>]" >&2
    exit 1
  fi
  CMD=$(choose "Operation" list ban unban allow disallow allowed)
  [ -n "$CMD" ] || exit 1
fi

case "$CMD" in
  list)
    cscli decisions list
    ;;

  ban)
    ip="$(ask_ip "${2:-}")"
    require_ip "$ip"
    # An allowlisted IP loses its decision at the next parse, so say so up front
    if is_allowed "$ip"; then
      echo "$ip is on the allowlist; run disallow first" >&2
      exit 1
    fi
    if ! cscli decisions add --ip "$ip" --duration "$BAN_DURATION" --type ban --reason "manual ban"; then
      echo "Failed to block $ip" >&2
      exit 1
    fi
    echo "Blocked $ip (${BAN_DURATION})"
    ;;

  unban)
    ip="$(ask_ip "${2:-}" banned_ips)"
    require_ip "$ip"
    if ! cscli decisions delete --ip "$ip"; then
      echo "Failed to unblock $ip" >&2
      exit 1
    fi
    echo "Unblocked $ip"
    ;;

  allow)
    ip="$(ask_ip "${2:-}")"
    require_ip "$ip"
    note="${3:-}"
    # Without a note there is no way to judge later whether the entry can be removed
    if [ -z "$note" ] && [ -t 0 ]; then
      read -rp "Note (optional): " note
    fi
    note="$(printf '%s' "$note" | tr -d '\t\n' | cut -c1-200)"

    mkdir -p "$(dirname "$ALLOW_TSV")"
    [ -f "$ALLOW_TSV" ] || : > "$ALLOW_TSV"
    # Remove any existing line for this IP first, so entries cannot pile up
    tmp="$(mktemp)"
    awk -F'\t' -v ip="$ip" 'NF && $1 != ip' "$ALLOW_TSV" > "$tmp"
    printf '%s\t%s\n' "$ip" "$note" >> "$tmp"
    sort -o "$tmp" "$tmp"
    mv "$tmp" "$ALLOW_TSV"

    if ! reload_allowlist; then
      echo "Failed to apply the allowlist" >&2
      exit 1
    fi
    # Drop the block at the same time if there is one. Allowlisting alone would let traffic
    # through, but leaving no record is clearer.
    cscli decisions delete --ip "$ip" > /dev/null 2>&1 || true
    echo "Added $ip to the allowlist (it will not be blocked)"
    ;;

  disallow)
    ip="$(ask_ip "${2:-}" allowed_ips)"
    require_ip "$ip"
    if ! is_allowed "$ip"; then
      echo "$ip is not on the allowlist" >&2
      exit 1
    fi
    tmp="$(mktemp)"
    awk -F'\t' -v ip="$ip" 'NF && $1 != ip' "$ALLOW_TSV" > "$tmp"
    mv "$tmp" "$ALLOW_TSV"
    if ! reload_allowlist; then
      echo "Failed to apply the allowlist" >&2
      exit 1
    fi
    echo "Removed $ip from the allowlist"
    ;;

  allowed)
    count="$(allowed_ips | wc -l | tr -d ' ')"
    echo "Allowlist: ${count:-0} entries"
    # For example 203.0.113.10<TAB>office static IP becomes 203.0.113.10  office static IP
    [ -f "$ALLOW_TSV" ] && awk -F'\t' 'NF && $1 !~ /^#/ { printf "  %s  %s\n", $1, $2 }' "$ALLOW_TSV"
    ;;

  *)
    echo "Usage: make ban CMD=list|ban|unban|allow|disallow|allowed [IP=<ip>]" >&2
    exit 2
    ;;
esac
