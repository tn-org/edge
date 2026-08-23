#!/bin/bash
# 遮断まわりのホスト設定（何度実行しても壊れない）
#
# CrowdSec 本体は docker コンテナなのでインストール作業は無い。ここで入れるのは
# 日次レポートの systemd timer と、旧構成（fail2ban / ipset）の後片付けだけ。
#
# Usage: ./setup-bans.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

# ---- 旧構成の後片付け -------------------------------------------------------
# 残しておくと fail2ban が古い nginx ログを読んだまま ban を作り続け、
# DOCKER-USER の ipset ルールも残る。CrowdSec と二重に効いて原因が読めなくなる
if systemctl list-unit-files fail2ban.service > /dev/null 2>&1 \
  && systemctl list-unit-files --no-legend fail2ban.service 2>/dev/null | grep -q fail2ban; then
  echo "🧹 旧 fail2ban を停止・無効化..."
  sudo systemctl disable --now fail2ban 2>/dev/null || true
fi

for unit in report-fail2ban.timer cert-renew.timer ipset-persist.service; do
  if systemctl list-unit-files --no-legend "$unit" 2>/dev/null | grep -q "$unit"; then
    echo "🧹 旧 $unit を停止・削除..."
    sudo systemctl disable --now "$unit" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/$unit"
  fi
done
sudo rm -f /etc/systemd/system/report-fail2ban.service /etc/systemd/system/cert-renew.service

# ---- 日次レポートの timer ---------------------------------------------------
echo ""
echo "📝 systemd ユニット インストール..."
for unit in report-bans.service report-bans.timer notify-failure@.service; do
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
echo "⏱️  report-bans.timer 有効化..."
sudo systemctl enable --now report-bans.timer

echo ""
echo "🔍 タイマー確認..."
systemctl list-timers report-bans.timer --no-pager || true

echo ""
echo "✅ 遮断まわりの設定完了"
echo "💡 遮断状況: make bans"
echo "💡 CrowdSec の稼働確認: sudo docker compose exec crowdsec cscli metrics"
