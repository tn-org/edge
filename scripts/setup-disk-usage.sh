#!/bin/bash
# ディレクトリ別ディスク使用量の日次記録 systemd timer 導入スクリプト（初回のみ）
# .service / .timer / notify-failure@ をホストに入れ、タイマーを有効化する。
# Usage: ./setup-disk-usage.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

echo "📝 systemd ユニット インストール..."
for unit in report-disk-usage.service report-disk-usage.timer notify-failure@.service; do
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
echo "⏱️  report-disk-usage.timer 有効化..."
sudo systemctl enable --now report-disk-usage.timer

echo ""
echo "🔍 タイマー確認..."
systemctl list-timers report-disk-usage.timer --no-pager || true

echo ""
echo "✅ ディスク使用量の日次記録 設定完了"
echo "💡 手動実行（即時テスト）: sudo systemctl start report-disk-usage.service"
echo "💡 成否確認: journalctl -u report-disk-usage -f"
