#!/bin/bash
# 初期化スクリプト（docker network → 設定の生成 → スタック起動）
#
# 証明書は Traefik の ACME が起動後に自分で取りに行くので、ここでの発行作業は無い。
# ルーティングも各プロジェクトの compose のラベルが持つので、ここで vhost は作らない。
#
# Usage: ./init.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

echo "🚀 初期化開始..."

# 共有ネットワークの実名。docker-compose.yml の既定（${EDGE_NETWORK:-edge}）と揃える
[ -f .env ] && { set -a; . ./.env; set +a; }
EDGE_NETWORK="${EDGE_NETWORK:-edge}"

# ネットワーク作成。各プロジェクトの compose はこれに external で参加する
docker network create "$EDGE_NETWORK" 2>/dev/null || true
echo "✅ ネットワーク（$EDGE_NETWORK）"

# .env の値を設定ファイルへ埋める（未設定ならここで止まる）
"$SCRIPT_DIR/render-config.sh"

docker compose up -d
echo "✅ Traefik / CrowdSec 起動"

echo ""
echo "✅ 初期化完了"
echo "💡 証明書の取得状況: docker compose logs traefik | grep -i acme"
echo "💡 CrowdSec の稼働確認: docker compose exec crowdsec cscli metrics"
