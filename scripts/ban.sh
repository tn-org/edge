#!/bin/bash
# 遮断と除外リストの操作（make ban と管理画面からの操作要求の実体）
#
# 遮断の実体は CrowdSec の decision。Traefik 側の bouncer プラグインが LAPI に
# 問い合わせて弾くので、アプリ層（HTTP）だけが対象になる。
# 除外リストは crowdsec/generated/allowlist.tsv が正で、CrowdSec のパーサ用 whitelist へ
# 変換して読ませる。除外した IP はそもそも decision を作られない。
#
# 操作名（list / ban / unban / allow / disallow / allowed）は fail2ban 時代のまま。
# console が積んでくる操作要求の action がこの名前なので変えない。
#
# Usage:
#   ban.sh                    # 対話で選ぶ
#   ban.sh list               # 遮断中の一覧
#   ban.sh ban <ip>           # 手動で遮断（既定 24 時間。BAN_DURATION で変えられる）
#   ban.sh unban <ip>         # 遮断を解除
#   ban.sh allow <ip> [理由]  # 除外リストに追加（遮断中なら同時に解除）
#   ban.sh disallow <ip>      # 除外リストから削除
#   ban.sh allowed            # 除外リストの一覧

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/choose.sh"

ALLOW_TSV="$ROOT_DIR/crowdsec/generated/allowlist.tsv"
# 手動遮断の長さ。CrowdSec の既定シナリオも 4 時間〜1 日なので揃えている。
# 記録は console に永続するので、遮断そのものを長く持つ必要はない
BAN_DURATION="${BAN_DURATION:-24h}"

# CrowdSec の CLI はコンテナの中にしか無い
cscli() {
  ( cd "$ROOT_DIR" && sudo docker compose exec -T crowdsec cscli "$@" )
}

# 除外リストを CrowdSec に読ませ直す。パーサの設定なので再起動が要る（数秒）
reload_allowlist() {
  "$SCRIPT_DIR/render-config.sh" allowlist || return 1
  ( cd "$ROOT_DIR" && sudo docker compose restart crowdsec > /dev/null )
}

# 除外リストの IP 一覧（コメント行を除く）
allowed_ips() {
  [ -f "$ALLOW_TSV" ] || return 0
  awk -F'\t' 'NF && $1 !~ /^#/ { print $1 }' "$ALLOW_TSV"
}

is_allowed() {
  allowed_ips | grep -qxF "$1"
}

# 遮断中の IP 一覧（重複なし）
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

# 引数が無ければ聞く。非対話なら usage を出して止める。
# $2 に候補を出す関数名を渡すと、件数が少ないときだけカーソル選択にする
ask_ip() {
  local given="${1:-}" from="${2:-}"
  if [ -n "$given" ]; then
    printf '%s' "$given"
    return 0
  fi
  if [ ! -t 0 ]; then
    echo "❌ IP が未指定です" >&2
    echo "Usage: make ban CMD=$CMD IP=<ip>" >&2
    exit 1
  fi

  if [ -n "$from" ]; then
    local candidates=()
    while IFS= read -r line; do
      [ -n "$line" ] && candidates+=("$line")
    done < <("$from")

    # 候補が多いと一覧が画面を埋めるので、その場合は打ち込みにする
    if [ "${#candidates[@]}" -gt 0 ] && [ "${#candidates[@]}" -le 30 ]; then
      choose "IP" "${candidates[@]}"
      return $?
    fi
  fi

  read -rp "IP: " answer
  printf '%s' "$answer"
}

# 書式を見ずに渡すと cscli が黙って失敗し、遮断したつもりで素通しになる。
# CrowdSec は IPv6 も CIDR も扱えるので、fail2ban + ipset 時代の IPv4 限定は外した
require_ip() {
  local ip="$1"
  if [ -z "$ip" ]; then
    echo "❌ IP が空です" >&2
    exit 1
  fi
  # IPv4 / IPv6 / それぞれの CIDR 表記だけ通す。ホスト名や空白混じりは弾く
  if ! printf '%s' "$ip" | grep -qE '^([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9A-Fa-f:]+)(/[0-9]{1,3})?$'; then
    echo "❌ IP アドレスとして読めません: $ip" >&2
    exit 1
  fi
}

CMD="${1:-}"
if [ -z "$CMD" ]; then
  if [ ! -t 0 ]; then
    echo "Usage: make ban CMD=list|ban|unban|allow|disallow|allowed [IP=<ip>]" >&2
    exit 1
  fi
  CMD=$(choose "操作" list ban unban allow disallow allowed)
  [ -n "$CMD" ] || exit 1
fi

case "$CMD" in
  list)
    cscli decisions list
    ;;

  ban)
    ip="$(ask_ip "${2:-}")"
    require_ip "$ip"
    # 除外リストにある IP は decision を作っても次の解析で外れるため、先に気付かせる
    if is_allowed "$ip"; then
      echo "❌ $ip は除外リストにあります。先に disallow してください" >&2
      exit 1
    fi
    if ! cscli decisions add --ip "$ip" --duration "$BAN_DURATION" --type ban --reason "手動遮断"; then
      echo "❌ $ip の遮断に失敗しました" >&2
      exit 1
    fi
    echo "✅ $ip を遮断しました（${BAN_DURATION}）"
    ;;

  unban)
    ip="$(ask_ip "${2:-}" banned_ips)"
    require_ip "$ip"
    if ! cscli decisions delete --ip "$ip"; then
      echo "❌ $ip の遮断解除に失敗しました" >&2
      exit 1
    fi
    echo "✅ $ip の遮断を解除しました"
    ;;

  allow)
    ip="$(ask_ip "${2:-}")"
    require_ip "$ip"
    note="${3:-}"
    # 理由が無いと、後から見て外していいのか判断できなくなる
    if [ -z "$note" ] && [ -t 0 ]; then
      read -rp "理由（任意）: " note
    fi
    note="$(printf '%s' "$note" | tr -d '\t\n' | cut -c1-200)"

    mkdir -p "$(dirname "$ALLOW_TSV")"
    [ -f "$ALLOW_TSV" ] || : > "$ALLOW_TSV"
    # 同じ IP の行が二重に積まれないよう、いったん外してから足す
    tmp="$(mktemp)"
    awk -F'\t' -v ip="$ip" 'NF && $1 != ip' "$ALLOW_TSV" > "$tmp"
    printf '%s\t%s\n' "$ip" "$note" >> "$tmp"
    sort -o "$tmp" "$tmp"
    mv "$tmp" "$ALLOW_TSV"

    if ! reload_allowlist; then
      echo "❌ 除外リストの反映に失敗しました" >&2
      exit 1
    fi
    # 現在遮断中なら同時に外す。除外しただけで通るようになるが、記録を残さない方が分かりやすい
    cscli decisions delete --ip "$ip" > /dev/null 2>&1 || true
    echo "✅ $ip を除外リストに追加しました（今後は遮断されません）"
    ;;

  disallow)
    ip="$(ask_ip "${2:-}" allowed_ips)"
    require_ip "$ip"
    if ! is_allowed "$ip"; then
      echo "❌ $ip は除外リストにありません" >&2
      exit 1
    fi
    tmp="$(mktemp)"
    awk -F'\t' -v ip="$ip" 'NF && $1 != ip' "$ALLOW_TSV" > "$tmp"
    mv "$tmp" "$ALLOW_TSV"
    if ! reload_allowlist; then
      echo "❌ 除外リストの反映に失敗しました" >&2
      exit 1
    fi
    echo "✅ $ip を除外リストから削除しました"
    ;;

  allowed)
    count="$(allowed_ips | wc -l | tr -d ' ')"
    echo "除外リスト: ${count:-0} 件"
    # 例: 203.0.113.10<TAB>社内固定IP → 203.0.113.10  社内固定IP
    [ -f "$ALLOW_TSV" ] && awk -F'\t' 'NF && $1 !~ /^#/ { printf "  %s  %s\n", $1, $2 }' "$ALLOW_TSV"
    ;;

  *)
    echo "Usage: make ban CMD=list|ban|unban|allow|disallow|allowed [IP=<ip>]" >&2
    exit 2
    ;;
esac
