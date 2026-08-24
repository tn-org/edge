#!/bin/bash
# Interactive .env editor (cursor UI).
# Lists the entries from .env.example; move with the arrows and press Enter to edit one.
#   Up/Down or k/j  ... move the cursor
#   Enter           ... edit the selected key (known keys offer a numbered choice as well)
#   q / ESC / Ctrl+C... quit (always available)
# Markers: * unset (empty)   ~ still at the example default on a server   (blank = configured)
# Values of secret-looking keys (KEY/SECRET/PASSWORD/TOKEN) are masked.
#
# Speed: .env is read into arrays at startup and after each edit; drawing is pure bash
# lookup with no forks.
# Safety: keys are read in the main shell (never a subshell), so the Ctrl+C trap always works.
# Note: works with the bash 3.2 that ships with macOS (no associative arrays).
set -uo pipefail
cd "$(dirname "$0")/.."  # .env and .env.example live at the repo root

EXAMPLE=".env.example"
ENV=".env"

[ -f "$EXAMPLE" ] || { echo "$EXAMPLE is missing"; exit 2; }
if [ ! -f "$ENV" ]; then
  cp "$EXAMPLE" "$ENV"
  echo "Created $ENV from $EXAMPLE"
fi

# ---- Helpers ---------------------------------------------------------------
options_for() {
  case "$1" in
    APP_ENV)              echo "local staging production" ;;
    APP_DEBUG)            echo "true false" ;;
    MAIL_MAILER)          echo "ses log smtp" ;;
    LOG_LEVEL)            echo "debug info warning error" ;;
    LOG_CHANNEL)          echo "stack single daily" ;;
    QUEUE_CONNECTION)     echo "sync database redis" ;;
    CACHE_STORE)          echo "database redis file" ;;
    SESSION_DRIVER)       echo "database file redis" ;;
    SESSION_SECURE_COOKIE) echo "true" ;;
    DB_CONNECTION)        echo "pgsql mysql sqlite" ;;
    INQUIRY_INBOUND_DISK) echo "inquiry local" ;;
    *)                    echo "" ;;
  esac
}
is_secret() { case "$1" in *KEY*|*SECRET*|*PASSWORD*|*TOKEN*) return 0 ;; *) return 1 ;; esac; }

# Read .env into parallel arrays (EKEYS/EVALS) with a builtin loop, no forks.
# Called again after every edit.
EKEYS=(); EVALS=(); APP_ENV_CUR="local"
load_env() {
  EKEYS=(); EVALS=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      [A-Z]*=*) EKEYS+=("${line%%=*}"); EVALS+=("${line#*=}") ;;
    esac
  done < "$ENV"
  lookup APP_ENV; APP_ENV_CUR="${LOOKUP//\"/}"; APP_ENV_CUR="${APP_ENV_CUR//\'/}"
  [ -n "$APP_ENV_CUR" ] || APP_ENV_CUR="local"
}
# Put the current value of a key into $LOOKUP (pure bash linear search, no forks)
LOOKUP=""
lookup() {
  local i=0 n=${#EKEYS[@]}
  LOOKUP=""
  while [ "$i" -lt "$n" ]; do
    [ "${EKEYS[$i]}" = "$1" ] && { LOOKUP="${EVALS[$i]}"; return; }
    i=$((i+1))
  done
}

# Safely set a key in .env (replace if present, append otherwise). The value is passed
# through the environment.
setval() {
  local k="$1" v="$2"
  # .env is sourced by bash (set -a; . .env) across the repo, so characters bash
  # would expand or split on ($ ` " ' \ space #) must be neutralised. Single-quote
  # such values, escaping embedded single quotes as '\''. Without this, an htpasswd
  # hash (DASHBOARD_AUTH contains $apr1$) breaks every script that reads .env.
  case "$v" in
    \'*\') ;; # already single-quoted by the caller: leave as-is
    *[\$\`\"\'\\\ \#]*)
      v="${v//\'/\'\\\'\'}"
      v="'$v'"
      ;;
  esac
  if grep -qE "^$k=" "$ENV"; then
    K="$k" V="$v" awk '
      BEGIN{k=ENVIRON["K"]; v=ENVIRON["V"]; done=0}
      !done && index($0, k"=")==1 { print k"="v; done=1; next }
      { print }
    ' "$ENV" > "$ENV.tmp" && mv "$ENV.tmp" "$ENV"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENV"
  fi
}

# ---- Non-interactive set (what make env KEY= VALUE= runs; one key per call) ----
if [ "${1:-}" = "set" ]; then
  key="${2:-}"; value="${3:-}"
  [ -n "$key" ] || { echo "Usage: env-setup.sh set KEY VALUE"; exit 1; }
  grep -qE "^${key}=" "$EXAMPLE" || echo "${key} is not in ${EXAMPLE} (setting it anyway)"
  setval "$key" "$value"
  if is_secret "$key" && [ -n "$value" ]; then
    echo "Set ${key}=********"
  else
    echo "Set ${key}=${value}"
  fi
  exit 0
fi

# ---- Parse .env.example into parallel arrays (KEYS / EXDEF / DESC) ----------
KEYS=(); EXDEF=(); DESC=()
desc=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "# ==="*) desc="" ;;
    "#"*) c="${line#\# }"; c="${c#\#}"; [ -n "$c" ] && desc="${desc}${c} " ;;
    "" ) desc="" ;;
    [A-Z]*=*) KEYS+=("${line%%=*}"); EXDEF+=("${line#*=}"); DESC+=("$desc"); desc="" ;;
    *) desc="" ;;
  esac
done < "$EXAMPLE"

N=${#KEYS[@]}
[ "$N" -gt 0 ] || { echo "No keys to configure"; exit 0; }

# Display in alphabetical order, independent of the order in .env.example
sorted="$(i=0; while [ "$i" -lt "$N" ]; do printf '%s\t%d\n' "${KEYS[$i]}" "$i"; i=$((i+1)); done | sort | cut -f2)"
SK=(); SE=(); SD=()
for i in $sorted; do SK+=("${KEYS[$i]}"); SE+=("${EXDEF[$i]}"); SD+=("${DESC[$i]}"); done
KEYS=("${SK[@]}"); EXDEF=("${SE[@]}"); DESC=("${SD[@]}")

load_env

# ---- Terminal control ------------------------------------------------------
ALT_ON=0
enter_screen() { printf '\033[?1049h\033[?25l'; ALT_ON=1; }   # alternate screen, hide cursor
leave_screen() { [ "$ALT_ON" = "1" ] && printf '\033[?25h\033[?1049l'; ALT_ON=0; }
trap 'leave_screen; exit 130' INT TERM HUP   # always restore the screen, including on Ctrl+C
trap 'leave_screen' EXIT

term_rows() { local r; r="$(tput lines 2>/dev/null)"; [ -n "$r" ] && echo "$r" || echo "${LINES:-24}"; }

# Read one key in the main shell into $KEYPRESS (no subshell, so traps keep working)
KEYPRESS=""
read_one() {
  local k rest=""
  if ! IFS= read -rsn1 k </dev/tty; then KEYPRESS="q"; return; fi   # Ctrl+D / EOF
  if [ "$k" = $'\033' ]; then
    # Tell an arrow key (\033[A and friends) from a bare ESC. A short timeout keeps ESC snappy.
    IFS= read -rsn2 -t 0.3 rest </dev/tty
    KEYPRESS="$k$rest"
  else
    KEYPRESS="$k"
  fi
}

render() {
  local rows body start end maxstart i k ex cur m sh
  rows="$(term_rows)"; body=$((rows - 3)); [ "$body" -lt 5 ] && body=5
  start=0
  if [ "$N" -gt "$body" ]; then
    start=$((IDX - body / 2))
    [ "$start" -lt 0 ] && start=0
    maxstart=$((N - body)); [ "$start" -gt "$maxstart" ] && start="$maxstart"
  fi
  end=$((start + body)); [ "$end" -gt "$N" ] && end="$N"

  printf '\033[2J\033[H'
  printf '== .env  up/down or jk to move  Enter to edit  q/ESC/Ctrl+C to quit   * unset  ~ default ==\n'
  i="$start"
  while [ "$i" -lt "$end" ]; do
    k="${KEYS[$i]}"; ex="${EXDEF[$i]}"; lookup "$k"; cur="$LOOKUP"
    if [ -z "$cur" ]; then m="*"; sh="(unset)"
    elif [ "$APP_ENV_CUR" != "local" ] && [ "$cur" = "$ex" ]; then m="~"; sh="$cur"
    else m=" "; sh="$cur"; fi
    is_secret "$k" && [ -n "$cur" ] && sh="********"
    if [ "$i" -eq "$IDX" ]; then
      printf '\033[7m %s %-26s %s\033[0m\n' "$m" "$k" "$sh"
    else
      printf ' %s %-26s %s\n' "$m" "$k" "$sh"
    fi
    i=$((i + 1))
  done
  [ "$end" -lt "$N" ] || [ "$start" -gt 0 ] && printf '   ... %d/%d\n' "$((IDX + 1))" "$N"
}

edit_key() {
  local i="$1"
  local k="${KEYS[$i]}" ex="${EXDEF[$i]}" d="${DESC[$i]}" opts ans sel cur curdisp exdisp n o
  lookup "$k"; cur="$LOOKUP"
  opts="$(options_for "$k")"
  curdisp="(unset)"; [ -n "$cur" ] && curdisp="$cur"
  exdisp="(empty)"; [ -n "$ex" ] && exdisp="$ex"
  printf '\033[?25h\033[2J\033[H'
  printf '[%s]\n' "$k"
  [ -n "$d" ] && printf '%s\n' "$d"
  printf '\nCurrent: %s    Example: %s\n\n' "$curdisp" "$exdisp"
  if [ -n "$opts" ]; then
    n=1; for o in $opts; do printf '  %d) %s\n' "$n" "$o"; n=$((n + 1)); done
    printf '\nPick a number, or type a value (empty = cancel) > '
  else
    printf 'Enter a value (empty = cancel) > '
  fi
  IFS= read -r ans </dev/tty || ans=""
  printf '\033[?25l'
  [ -z "$ans" ] && return
  if [ -n "$opts" ] && printf '%s' "$ans" | grep -qE '^[0-9]+$'; then
    sel="$(printf '%s\n' $opts | sed -n "${ans}p")"
    [ -n "$sel" ] && ans="$sel"
  fi
  setval "$k" "$ans"
  load_env
}

# ---- Main loop -------------------------------------------------------------
IDX=0
enter_screen
while true; do
  render
  read_one
  case "$KEYPRESS" in
    $'\033[A'|k) IDX=$(( (IDX - 1 + N) % N )) ;;
    $'\033[B'|j) IDX=$(( (IDX + 1) % N )) ;;
    "") edit_key "$IDX" ;;          # Enter
    $'\033'|q|Q) break ;;           # bare ESC or q
  esac
done

leave_screen
echo "Saved: $ENV"
echo "Verify with: make env CMD=check"
