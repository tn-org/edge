#!/bin/bash
# Compare .env against .env.example.
#  (1) missing or extra keys (values are never printed)
#  (2) when APP_ENV is not local, flag keys still left at the example default
#      (a value that has to be set per environment but never was)
# The example values are public, so the names of keys still at their example value are
# printed, but no actual value from .env is ever output.
#
# Usage: scripts/check-env.sh
set -euo pipefail
cd "$(dirname "$0")/.."  # .env and .env.example live at the repo root

EXAMPLE=".env.example"
ENV=".env"

[ -f "$EXAMPLE" ] || { echo "$EXAMPLE not found"; exit 2; }
[ -f "$ENV" ] || { echo "$ENV is missing (run cp $EXAMPLE $ENV and configure it)"; exit 2; }

# Extract only the key names from KEY= at the start of a line (comments, blanks and values ignored)
keys() { grep -oE '^[A-Z][A-Z0-9_]*=' "$1" | sed 's/=$//' | sort -u; }
# The raw value of a key (first match, everything after KEY=)
val() { grep -E "^$1=" "$2" | head -1 | sed "s/^$1=//"; }

missing_in_env=$(comm -23 <(keys "$EXAMPLE") <(keys "$ENV"))
missing_in_example=$(comm -13 <(keys "$EXAMPLE") <(keys "$ENV"))

status=0
if [ -n "$missing_in_env" ]; then
  echo "Missing from .env (present in .env.example; possibly unconfigured):"
  echo "$missing_in_env" | sed 's/^/  - /'
  status=1
fi
if [ -n "$missing_in_example" ]; then
  echo "Missing from .env.example (present in .env; possibly undocumented):"
  echo "$missing_in_example" | sed 's/^/  - /'
  status=1
fi

# (2) Check for values left at the default. Skipped for local, where matching defaults are normal.
app_env=$(val APP_ENV "$ENV" | tr -d "\"'")
if [ -n "$app_env" ] && [ "$app_env" != "local" ]; then
  # Keys where the shared default is the right answer, so leaving them alone is correct
  # (the two mode keys default to what every host did before they existed)
  shared_defaults="APP_ENV EDGE_NETWORK EDGE_TLS_MODE EDGE_CROWDSEC"

  unchanged=""
  for k in $(comm -12 <(keys "$EXAMPLE") <(keys "$ENV")); do
    case " $shared_defaults " in *" $k "*) continue ;; esac
    if [ "$(val "$k" "$EXAMPLE")" = "$(val "$k" "$ENV")" ]; then
      unchanged="${unchanged}  - ${k}"$'\n'
    fi
  done
  if [ -n "$unchanged" ]; then
    echo "APP_ENV=$app_env but still at the example default (should be set per environment):"
    printf "%s" "$unchanged"
    status=1
  fi
fi

[ "$status" -eq 0 ] && echo ".env matches .env.example (same keys, no defaults left over)"
exit "$status"
