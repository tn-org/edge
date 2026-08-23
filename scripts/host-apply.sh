#!/bin/bash
# ホスト側設定の一括反映（何度実行しても壊れない）
#
# repo の設定ファイルを /etc 配下へ配置し、systemd タイマーを有効化する。
# 自動デプロイ（release.yml）は git の追従と compose の反映しかしないので、
# /etc 配下・systemd に関わる変更はこれを手で流して追従させる。
#
# Usage: ./host-apply.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

for step in \
  setup-logs \
  setup-auto-patch \
  setup-bans \
  setup-docker-prune \
  setup-disk-usage \
  setup-host-sync
do
  echo ""
  echo "───────── $step ─────────"
  "$SCRIPT_DIR/$step.sh"
done

echo ""
echo "───────── 管理画面へ同期 ─────────"
sudo systemctl start host-sync.service && echo "✔ 同期しました"

echo ""
echo "✅ ホスト設定の反映が完了しました"
