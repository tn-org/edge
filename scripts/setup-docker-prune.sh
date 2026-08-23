#!/bin/bash
# 未使用 docker イメージ週次掃除の systemd timer 導入スクリプト（初回のみ）
# .service / .timer / notify-failure@ をホストに入れ、タイマーを有効化する。
# Usage: ./setup-docker-prune.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

# 旧ユニット（base-refresh）の後始末。イメージのビルドは GitHub Actions へ移したため
# サーバー側には掃除だけが残る（2026-08-04）。残っていると週次で build が走り続ける
for old in base-refresh.timer base-refresh.service; do
  if systemctl list-unit-files "$old" >/dev/null 2>&1 && [ -f "/etc/systemd/system/$old" ]; then
    echo "🧹 旧ユニット削除: $old"
    sudo systemctl disable --now "$old" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/$old"
  fi
done

echo "📝 systemd ユニット インストール..."
for unit in docker-prune.service docker-prune.timer notify-failure@.service; do
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
echo "⏱️  docker-prune.timer 有効化..."
sudo systemctl enable --now docker-prune.timer

echo ""
echo "🔍 タイマー確認..."
systemctl list-timers docker-prune.timer --no-pager || true

echo ""
echo "✅ 未使用イメージ週次掃除の設定完了"
echo "💡 手動実行（即時テスト）: sudo systemctl start docker-prune.service"
echo "💡 成否確認: journalctl -u docker-prune -f"
