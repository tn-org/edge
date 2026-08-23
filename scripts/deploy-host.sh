#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# ホスト層の反映（CI の release.yml が SSM 経由で呼ぶ実体）。
# git の更新はこのスクリプトの「外」（SSM の一行側）で先に済ませてある。
# pull 前のサーバーには新しい版が無いので、git 更新自体はここに書かない。
#
# 順序:
#   1. .env の値を設定ファイルへ埋める（traefik/generated・crowdsec/generated）
#   2. compose を最新定義に揃える。compose から消えたサービスのコンテナ（旧 nginx /
#      certbot 等）は --remove-orphans で片付ける
#   3. 静的設定が変わっていたときだけコンテナを入れ替える
#
# ルーティング（ドメイン・upstream）はプロジェクト側の compose ラベルが持ち、
# Traefik が docker のイベントで拾う。ミドルウェアと TLS 設定（traefik/dynamic/）も
# Traefik が watch しているので、どちらもこのスクリプトの出番は無い。
# 入れ替えが要るのは Traefik の静的設定と CrowdSec の設定を変えたときだけ。

STATE_FILE=".state/config-hash"

# 入れ替えが必要な設定だけを見る。動的設定と除外リストは watch / 個別反映なので含めない
config_hash() {
  cat traefik/generated/traefik.yml crowdsec/acquis.yaml crowdsec/config.yaml.local 2>/dev/null \
    | sha256sum | cut -d' ' -f1
}

./scripts/render-config.sh

new_hash="$(config_hash)"
old_hash="$(cat "$STATE_FILE" 2>/dev/null || true)"

sudo docker compose up -d --remove-orphans

if [ "$new_hash" != "$old_hash" ]; then
  echo "🔄 静的設定が変わったのでコンテナを入れ替える"
  sudo docker compose restart traefik crowdsec
  mkdir -p "$(dirname "$STATE_FILE")"
  printf '%s' "$new_hash" > "$STATE_FILE"
else
  echo "ℹ️ 静的設定に変更なし（入れ替えなし）"
fi

echo "✅ ホスト層の反映完了"
