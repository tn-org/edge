#!/bin/bash
# kernel 更新後の再起動待ち検知 systemd timer 導入スクリプト（初回のみ）
# needs-restarting（dnf-utils）を入れ、.service / .timer を配置してタイマーを有効化する。
# Usage: ./setup-reboot-check.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

echo "📦 dnf-utils インストール（needs-restarting の提供元）..."
sudo dnf install -y dnf-utils

echo ""
echo "📝 systemd ユニット インストール..."
for unit in report-reboot-check.service report-reboot-check.timer notify-failure@.service; do
  sudo cp "$ROOT_DIR/systemd/$unit" "/etc/systemd/system/$unit"
  # ExecStart/EnvironmentFile/WorkingDirectory のプレースホルダを実パスに置換
  sudo sed -i "s|/path/to/edge|$ROOT_DIR|g" "/etc/systemd/system/$unit"
  sudo chmod 644 "/etc/systemd/system/$unit"
  echo "  $unit"
done

echo ""
echo "🔄 daemon-reload..."
sudo systemctl daemon-reload

echo ""
echo "⏱️  report-reboot-check.timer 有効化..."
sudo systemctl enable --now report-reboot-check.timer

echo ""
echo "🔍 タイマー確認..."
systemctl list-timers report-reboot-check.timer --no-pager || true

echo ""
echo "✅ 再起動待ちの検知 設定完了"
echo "💡 手動実行（即時テスト）: sudo systemctl start report-reboot-check.service"
echo "💡 待ちがある間は毎朝 warning が届く。再起動すると自動で止まる"
