#!/bin/bash
# .env 対話設定（カーソル UI）。
# .env.example を項目一覧として表示し、↑↓ で選んで Enter で 1 件ずつ編集する。
#   ↑/↓ または k/j … カーソル移動
#   Enter            … 選択中のキーを編集（既知キーは番号選択＋自由入力）
#   q / ESC / Ctrl+C … 終了（いつでも抜けられる）
# 印:  ●未設定（空）   ◐本番で example 既定のまま   （無印＝設定済み）
# 秘密っぽいキー（KEY/SECRET/PASSWORD/TOKEN）は値をマスク表示する。
#
# 速度: .env は起動時と編集後だけ配列に読み込み、描画は純 bash 検索（fork しない）。
# 安全: キー入力はメインシェルで読む（サブシェル化しない）ため Ctrl+C のトラップが必ず効く。
# 注意: macOS 既定の bash 3.2 でも動く（連想配列なし）。
set -uo pipefail
cd "$(dirname "$0")/.."  # .env/.env.example は repo ルート

EXAMPLE=".env.example"
ENV=".env"

[ -f "$EXAMPLE" ] || { echo "✗ $EXAMPLE が無い"; exit 2; }
if [ ! -f "$ENV" ]; then
  cp "$EXAMPLE" "$ENV"
  echo "→ $ENV を $EXAMPLE から作成した"
fi

# ---- ヘルパ ----------------------------------------------------------------
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

# .env を配列(EKEYS/EVALS)に読み込む（fork なしの builtin ループ）。編集後に呼び直す。
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
# キーの現在値を $LOOKUP に入れる（純 bash 線形検索・fork しない）
LOOKUP=""
lookup() {
  local i=0 n=${#EKEYS[@]}
  LOOKUP=""
  while [ "$i" -lt "$n" ]; do
    [ "${EKEYS[$i]}" = "$1" ] && { LOOKUP="${EVALS[$i]}"; return; }
    i=$((i+1))
  done
}

# .env のキーを安全に set（あれば置換・無ければ追記）。値は ENVIRON 経由で渡す。
setval() {
  local k="$1" v="$2"
  case "$v" in *" "*) case "$v" in \"*\") ;; *) v="\"$v\"" ;; esac ;; esac
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

# ---- 非対話 set（make env KEY= VALUE= の実体。1 キー 1 実行）------------------
if [ "${1:-}" = "set" ]; then
  key="${2:-}"; value="${3:-}"
  [ -n "$key" ] || { echo "Usage: env-setup.sh set KEY VALUE"; exit 1; }
  grep -qE "^${key}=" "$EXAMPLE" || echo "⚠ ${key} は ${EXAMPLE} に無いキー（そのまま設定はする）"
  setval "$key" "$value"
  if is_secret "$key" && [ -n "$value" ]; then
    echo "✓ ${key}=******** を設定した"
  else
    echo "✓ ${key}=${value} を設定した"
  fi
  exit 0
fi

# ---- .env.example をパース（KEYS / EXDEF / DESC を平行配列に）----------------
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
[ "$N" -gt 0 ] || { echo "設定対象キーが無い"; exit 0; }

# 表示はアルファベット順（.env.example の記載順に依存しない）
sorted="$(i=0; while [ "$i" -lt "$N" ]; do printf '%s\t%d\n' "${KEYS[$i]}" "$i"; i=$((i+1)); done | sort | cut -f2)"
SK=(); SE=(); SD=()
for i in $sorted; do SK+=("${KEYS[$i]}"); SE+=("${EXDEF[$i]}"); SD+=("${DESC[$i]}"); done
KEYS=("${SK[@]}"); EXDEF=("${SE[@]}"); DESC=("${SD[@]}")

load_env

# ---- ターミナル制御 --------------------------------------------------------
ALT_ON=0
enter_screen() { printf '\033[?1049h\033[?25l'; ALT_ON=1; }   # 代替スクリーン + カーソル非表示
leave_screen() { [ "$ALT_ON" = "1" ] && printf '\033[?25h\033[?1049l'; ALT_ON=0; }
trap 'leave_screen; exit 130' INT TERM HUP   # Ctrl+C 等でも必ず復帰して抜ける
trap 'leave_screen' EXIT

term_rows() { local r; r="$(tput lines 2>/dev/null)"; [ -n "$r" ] && echo "$r" || echo "${LINES:-24}"; }

# 1 キー入力をメインシェルで読み $KEYPRESS に入れる（サブシェル化しない＝トラップが効く）
KEYPRESS=""
read_one() {
  local k rest=""
  if ! IFS= read -rsn1 k </dev/tty; then KEYPRESS="q"; return; fi   # Ctrl+D / EOF
  if [ "$k" = $'\033' ]; then
    # 矢印(\033[A 等)と単独 ESC を判別。短いタイムアウトで ESC をキビキビ終了に。
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
  printf '== .env 設定  ↑↓/jk 選択  Enter 編集  q/ESC/Ctrl+C 終了   ●未設定 ◐既定のまま ==\n'
  i="$start"
  while [ "$i" -lt "$end" ]; do
    k="${KEYS[$i]}"; ex="${EXDEF[$i]}"; lookup "$k"; cur="$LOOKUP"
    if [ -z "$cur" ]; then m="●"; sh="（未設定）"
    elif [ "$APP_ENV_CUR" != "local" ] && [ "$cur" = "$ex" ]; then m="◐"; sh="$cur"
    else m=" "; sh="$cur"; fi
    is_secret "$k" && [ -n "$cur" ] && sh="********"
    if [ "$i" -eq "$IDX" ]; then
      printf '\033[7m %s %-26s %s\033[0m\n' "$m" "$k" "$sh"
    else
      printf ' %s %-26s %s\n' "$m" "$k" "$sh"
    fi
    i=$((i + 1))
  done
  [ "$end" -lt "$N" ] || [ "$start" -gt 0 ] && printf '   … %d/%d\n' "$((IDX + 1))" "$N"
}

edit_key() {
  local i="$1"
  local k="${KEYS[$i]}" ex="${EXDEF[$i]}" d="${DESC[$i]}" opts ans sel cur curdisp exdisp n o
  lookup "$k"; cur="$LOOKUP"
  opts="$(options_for "$k")"
  curdisp="（未設定）"; [ -n "$cur" ] && curdisp="$cur"
  exdisp="（空）"; [ -n "$ex" ] && exdisp="$ex"
  printf '\033[?25h\033[2J\033[H'
  printf '[%s]\n' "$k"
  [ -n "$d" ] && printf '%s\n' "$d"
  printf '\n現在: %s    例: %s\n\n' "$curdisp" "$exdisp"
  if [ -n "$opts" ]; then
    n=1; for o in $opts; do printf '  %d) %s\n' "$n" "$o"; n=$((n + 1)); done
    printf '\n番号で選択、または自由入力（空=取消） > '
  else
    printf '値を入力（空=取消） > '
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

# ---- メインループ ----------------------------------------------------------
IDX=0
enter_screen
while true; do
  render
  read_one
  case "$KEYPRESS" in
    $'\033[A'|k) IDX=$(( (IDX - 1 + N) % N )) ;;
    $'\033[B'|j) IDX=$(( (IDX + 1) % N )) ;;
    "") edit_key "$IDX" ;;          # Enter
    $'\033'|q|Q) break ;;           # 単独 ESC / q
  esac
done

leave_screen
echo "保存しました: $ENV"
echo "検証: make env CMD=check"
