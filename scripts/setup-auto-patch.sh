#!/bin/bash
# OS自動セキュリティパッチ設定スクリプト（初回のみ / Amazon Linux 2023）
# dnf-automatic を導入し、security のみ自動適用・自動再起動なしにする。
# Usage: ./setup-auto-patch.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

echo "📦 dnf-automatic インストール..."
sudo dnf install -y dnf-automatic

echo ""
echo "📝 設定インストール (/etc/dnf/automatic.conf)..."
sudo cp "$ROOT_DIR/auto-patch/automatic.conf" /etc/dnf/automatic.conf
sudo sed -i "s|/path/to/edge|$ROOT_DIR|g" /etc/dnf/automatic.conf
# 通知の差出人表示はホスト名にする（複数ホストで同じ repo を使うため固定名にしない）
sudo sed -i "s|__HOSTNAME__|$(hostname)|g" /etc/dnf/automatic.conf
sudo chmod 644 /etc/dnf/automatic.conf

echo ""
echo "🕐 実行時刻の上書き（日本時間 深夜帯）をインストール..."
sudo mkdir -p /etc/systemd/system/dnf-automatic.timer.d
sudo cp "$ROOT_DIR/systemd/dnf-automatic.timer.d/override.conf" \
  /etc/systemd/system/dnf-automatic.timer.d/override.conf
sudo chmod 644 /etc/systemd/system/dnf-automatic.timer.d/override.conf

echo ""
echo "📣 失敗通知（notify-failure@ 経由でハブへ）をインストール..."
sudo cp "$ROOT_DIR/systemd/notify-failure@.service" /etc/systemd/system/notify-failure@.service
sudo sed -i "s|/path/to/edge|$ROOT_DIR|g" /etc/systemd/system/notify-failure@.service
sudo chmod 644 /etc/systemd/system/notify-failure@.service
sudo mkdir -p /etc/systemd/system/dnf-automatic.service.d
sudo cp "$ROOT_DIR/systemd/dnf-automatic.service.d/override.conf" \
  /etc/systemd/system/dnf-automatic.service.d/override.conf
sudo chmod 644 /etc/systemd/system/dnf-automatic.service.d/override.conf
sudo systemctl daemon-reload

echo ""
echo "⏱️  dnf-automatic.timer 有効化..."
sudo systemctl enable --now dnf-automatic.timer

echo ""
echo "🔍 タイマー確認..."
systemctl list-timers dnf-automatic.timer --no-pager || true

echo ""
echo "✅ OS自動セキュリティパッチ設定完了"
echo "💡 security のみ自動適用・自動再起動なし。kernel 更新は手動再起動窓で対応"
echo "💡 成否確認: journalctl -u dnf-automatic"
