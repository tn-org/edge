#!/bin/bash
# .env の値を設定ファイルへ埋め込み、compose が mount する実体を作る（何度実行してもよい）。
#
# なぜ必要か:
#   - Traefik の静的設定は「ファイル・環境変数・引数」のいずれか 1 つしか使えず、
#     ファイルの中で環境変数は展開されない。ホストごとに違う値（ACME_EMAIL・EDGE_NETWORK）を
#     traefik/traefik.yml に直書きできないので、ここで埋める。
#   - CrowdSec の LAPI キーも同じ理由で動的設定に直書きできない。
#     bouncer プラグインが用意している crowdsecLapiKeyFile 用にファイルへ書き出す。
#
# 生成物（すべて git 管理外）:
#   traefik/generated/traefik.yml     … 静的設定の実体
#   traefik/generated/lapi-key        … CrowdSec LAPI のキー（600）
#   crowdsec/generated/allowlist.tsv  … 除外 IP の正（IP<TAB>理由）。ban.sh が編集する
#   crowdsec/generated/whitelist.yaml … 上記から作る CrowdSec のパーサ用 whitelist
#
# Usage:
#   render-config.sh            # 全部
#   render-config.sh allowlist  # 除外リストだけ作り直す（ban.sh から呼ぶ）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

ALLOW_TSV="crowdsec/generated/allowlist.tsv"
ALLOW_YAML="crowdsec/generated/whitelist.yaml"

# 除外 IP の一覧（allowlist.tsv）を CrowdSec のパーサ用 whitelist に変換する。
# パーサ段で落とすので、除外した IP はそもそも decision を作られない
# （旧構成の ipset 許可リスト + fail2ban ignorecommand と同じ役割）。
render_allowlist() {
  mkdir -p crowdsec/generated
  [ -f "$ALLOW_TSV" ] || : > "$ALLOW_TSV"

  local ips=() cidrs=() ip note
  while IFS=$'\t' read -r ip note || [ -n "${ip:-}" ]; do
    ip="${ip%%$'\r'}"
    [ -n "$ip" ] || continue
    case "$ip" in
      \#*) continue ;;
      */*) cidrs+=("$ip") ;;
      *) ips+=("$ip") ;;
    esac
  done < "$ALLOW_TSV"

  {
    echo "# 自動生成（scripts/render-config.sh）。直接編集しない。"
    echo "# 正は crowdsec/generated/allowlist.tsv。操作は make ban CMD=allow|disallow"
    echo "name: edge/allowlist"
    echo 'description: "運用で除外した IP（遮断の対象外にする）"'
    echo "whitelist:"
    echo '  reason: "edge allowlist"'
    if [ "${#ips[@]}" -gt 0 ]; then
      echo "  ip:"
      for ip in "${ips[@]}"; do printf '    - "%s"\n' "$ip"; done
    else
      echo "  ip: []"
    fi
    if [ "${#cidrs[@]}" -gt 0 ]; then
      echo "  cidr:"
      for ip in "${cidrs[@]}"; do printf '    - "%s"\n' "$ip"; done
    else
      echo "  cidr: []"
    fi
  } > "$ALLOW_YAML.tmp"
  mv "$ALLOW_YAML.tmp" "$ALLOW_YAML"
}

if [ "${1:-all}" = "allowlist" ]; then
  render_allowlist
  echo "✔ 除外リストを反映: $ALLOW_YAML"
  exit 0
fi

# ---- .env の読み込みと必須チェック -----------------------------------------
if [ ! -f .env ]; then
  echo "❌ .env がありません（cp .env.example .env してから make env で設定）" >&2
  exit 1
fi
set -a; . ./.env; set +a

fail=0
for key in ACME_EMAIL CROWDSEC_BOUNCER_KEY; do
  if [ -z "${!key:-}" ]; then
    echo "❌ $key が .env に設定されていません" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] || { echo "👉 make env で設定してから再実行" >&2; exit 1; }

# 共有ネットワーク名。docker-compose.yml の既定（${EDGE_NETWORK:-edge}）と必ず同じにする
EDGE_NETWORK="${EDGE_NETWORK:-edge}"

# ---- Traefik の静的設定 -----------------------------------------------------
mkdir -p traefik/generated
# sed の置換文字列で & は「一致した文字列」の意味になるためエスケープする
esc_email="${ACME_EMAIL//&/\\&}"
esc_network="${EDGE_NETWORK//&/\\&}"
sed -e "s|__ACME_EMAIL__|${esc_email}|g" \
    -e "s|__EDGE_NETWORK__|${esc_network}|g" \
    traefik/traefik.yml > traefik/generated/traefik.yml.tmp
if grep -q '__ACME_EMAIL__\|__EDGE_NETWORK__' traefik/generated/traefik.yml.tmp; then
  rm -f traefik/generated/traefik.yml.tmp
  echo "❌ 静的設定への差し込みに失敗した（ACME_EMAIL / EDGE_NETWORK）" >&2
  exit 1
fi
mv traefik/generated/traefik.yml.tmp traefik/generated/traefik.yml
chmod 644 traefik/generated/traefik.yml

# ---- CrowdSec LAPI のキー ---------------------------------------------------
umask 077
printf '%s' "$CROWDSEC_BOUNCER_KEY" > traefik/generated/lapi-key.tmp
mv traefik/generated/lapi-key.tmp traefik/generated/lapi-key
chmod 600 traefik/generated/lapi-key
umask 022

# ---- 置き場 -----------------------------------------------------------------
# acme.json は先に作っておく。無いと Traefik 3.7 は
# 「unable to get ACME account: open /acme/acme.json: no such file or directory」で
# resolver をリストから外し、証明書を 1 枚も取らないまま起動してしまう
# （その後 acme-http@internal も "HTTP challenge is not enabled" で落ちる）。
# 中身が空のままでも Traefik は新規登録として扱う
mkdir -p traefik/acme
chmod 700 traefik/acme
if [ ! -f traefik/acme/acme.json ]; then
  umask 077
  : > traefik/acme/acme.json
  umask 022
fi
chmod 600 traefik/acme/acme.json
mkdir -p logs/traefik

render_allowlist

echo "✅ 設定を生成した（traefik/generated・crowdsec/generated）"
