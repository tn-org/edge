#!/bin/bash
# Post-apply routing check: prove that Traefik actually serves every HTTPS host
# this machine is supposed to serve, from the outside of the containers.
#
# Why: an update can leave Traefik running but with every router dead (2026-09-11:
# a stray EDGE_TLS_MODE=origin-ca removed the ACME resolver, every router that
# referenced it was dropped, and the update still reported success). Traefik keeps
# answering TLS in that state, so only a real handshake per hostname tells the truth.
#
# What it does:
#   - Collects the hostnames to serve: every Host(`...`) in the Traefik labels of
#     running containers, plus DASHBOARD_HOST from .env when set.
#   - For each, performs a TLS handshake + HTTP request against 127.0.0.1:443 with
#     the hostname as SNI (curl --resolve). Any HTTP status counts as alive; what is
#     checked is that a certificate is served and a router answers. -k on purpose:
#     in origin-ca mode the certificate is not publicly trusted, and certificate
#     validity is not this script's question.
#   - Retries for a while before failing: after a restart Traefik needs a moment,
#     and a genuinely new domain may be waiting on its first ACME issuance.
#
# Exit codes: 0 = every hostname answered (or there was nothing to verify),
# 1 = at least one hostname still failing after the retries.
#
# Used by deploy-host.sh after applying the host layer; run it by hand as make verify.

set -uo pipefail
cd "$(dirname "$0")/.."

ATTEMPTS="${EDGE_VERIFY_ATTEMPTS:-6}"
SLEEP_BETWEEN=15

# Nothing to verify without a running proxy (a workstation, or a host mid-bootstrap)
if ! sudo docker ps --format '{{.Names}}' | grep -qx 'edge-traefik'; then
  echo "verify-routes: Traefik is not running; nothing to verify"
  exit 0
fi

# ---- Collect the hostnames --------------------------------------------------
hosts=()
for id in $(sudo docker ps -q --filter label=traefik.enable=true); do
  while IFS= read -r h; do
    hosts+=("$h")
  done < <(sudo docker inspect --format \
      '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' "$id" \
    | grep -oE 'Host\(`[^`]+`\)' | sed -E 's/Host\(`([^`]+)`\)/\1/')
done

dash="$(grep '^DASHBOARD_HOST=' .env 2>/dev/null | cut -d'=' -f2)"
dash="${dash//\"/}"; dash="${dash//\'/}"
[ -n "$dash" ] && hosts+=("$dash")

# De-duplicate (the same Host() appears in http and https router rules)
uniq_hosts=()
for h in "${hosts[@]:-}"; do
  [ -n "$h" ] || continue
  case " ${uniq_hosts[*]:-} " in
    *" $h "*) ;;
    *) uniq_hosts+=("$h") ;;
  esac
done

if [ "${#uniq_hosts[@]}" -eq 0 ]; then
  echo "verify-routes: no Traefik-labelled containers and no DASHBOARD_HOST; nothing to verify"
  exit 0
fi

# ---- Handshake per hostname, with retries -----------------------------------
attempt=1
failing=()
while :; do
  failing=()
  for h in "${uniq_hosts[@]}"; do
    if ! curl -sk -o /dev/null --max-time 10 --resolve "$h:443:127.0.0.1" "https://$h/"; then
      failing+=("$h")
    fi
  done
  if [ "${#failing[@]}" -eq 0 ]; then
    echo "verify-routes: ${#uniq_hosts[@]} hostname(s) answering on 443"
    exit 0
  fi
  if [ "$attempt" -ge "$ATTEMPTS" ]; then
    break
  fi
  echo "verify-routes: ${#failing[@]}/${#uniq_hosts[@]} not answering yet (attempt $attempt/$ATTEMPTS): ${failing[*]}"
  attempt=$((attempt + 1))
  sleep "$SLEEP_BETWEEN"
done

echo "verify-routes: FAILED - no TLS answer for: ${failing[*]}" >&2
echo "Look at: sudo docker compose logs --tail=50 traefik (dead routers log 'ERR Router ...')" >&2
exit 1
