#!/bin/bash
# ログローテーション設定スクリプト（何度実行しても壊れない）
# Usage: ./setup-logs.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

echo "📁 ログディレクトリ作成..."
# Traefik のアクセスログ 1 本。ドメイン別のディレクトリは作らない
# （どのドメイン宛かは JSON の RequestHost に入っている）
mkdir -p logs/traefik
echo "  logs/traefik"

echo ""
echo "🧹 旧 nginx 用のローテーション設定を削除..."
sudo rm -f /etc/logrotate.d/nginx-edge

echo ""
echo "📝 logrotate設定インストール..."
sudo cp "$ROOT_DIR/logrotate/traefik" /etc/logrotate.d/traefik
sudo sed -i "s|/path/to/edge|$ROOT_DIR|g" /etc/logrotate.d/traefik
sudo chmod 644 /etc/logrotate.d/traefik

echo ""
echo "🔍 設定テスト..."
sudo logrotate -d /etc/logrotate.d/traefik 2>&1 | head -10
echo "..."

echo ""
echo "✅ ログ設定完了"
