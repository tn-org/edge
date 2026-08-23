#!/bin/bash
# ホスト状態同期 systemd timer 導入スクリプト（何度実行しても壊れない）
# .service / .timer / notify-failure@ をホストに入れ、タイマーを有効化する。
# 旧名 f2b-sync のユニットが残っていれば止めて消す（二重に走らせないため）。
# Usage: ./setup-host-sync.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

# 旧名の掃除。同じ処理が 2 つのタイマーから走ると、操作を取り合って結果が不定になる
if systemctl list-unit-files f2b-sync.timer >/dev/null 2>&1 \
  && systemctl list-unit-files --no-legend f2b-sync.timer 2>/dev/null | grep -q f2b-sync; then
  echo "🧹 旧 f2b-sync を停止・削除..."
  sudo systemctl disable --now f2b-sync.timer 2>/dev/null || true
  sudo rm -f /etc/systemd/system/f2b-sync.timer /etc/systemd/system/f2b-sync.service
fi

echo "📝 systemd ユニット インストール..."
for unit in host-sync.service host-sync.timer notify-failure@.service; do
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
echo "⏱️  host-sync.timer 有効化..."
sudo systemctl enable --now host-sync.timer

echo ""
echo "🔍 タイマー確認..."
systemctl list-timers host-sync.timer --no-pager || true

echo ""
echo "✅ ホスト状態同期 設定完了"
echo "💡 手動実行（即時テスト）: sudo systemctl start host-sync.service"
echo "💡 成否確認: journalctl -u host-sync -n 30"
