#!/bin/bash
# 初回セットアップ一括 wizard（make setup から呼ぶ。再実行可能・冪等）
#
# 流れ:
#   1. .env 準備: 無ければ .env.example からコピー → APP_ENV 未確定なら対話で確定
#      （非 tty で APP_ENV 未確定なら usage + exit 1。CI/SSM をハングさせない）
#   2. [APP_ENV≠local のみ] ホスト初期化:
#      init.sh（network・設定生成・スタック起動）→ host-apply.sh（/etc・systemd の一括反映）
#   3. スタック起動: up（Traefik / CrowdSec）
#   4. 検収: check-env + ps + 完了メッセージ
#
# Usage: scripts/setup.sh

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/choose.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

# ---- 1. .env 準備 ----------------------------------------------------------
created=0
if [ ! -f .env ]; then
  cp .env.example .env
  created=1
  echo "✔ .env を .env.example から生成"
fi

app_env="$(grep '^APP_ENV=' .env | head -1 | cut -d'=' -f2 | tr -d '"'"'" || true)"

# 新規生成直後（example 既定 = local のまま）か、APP_ENV 空なら対話で確定する
if [ "$created" = "1" ] || [ -z "$app_env" ]; then
  if [ ! -t 0 ]; then
    echo "❌ APP_ENV が未確定です（非対話環境では選択できない）" >&2
    echo "Usage: .env の APP_ENV に local|staging|production を設定してから make setup を再実行" >&2
    exit 1
  fi
  app_env=$(choose "APP_ENV（この環境の種別）" local staging production)
  if [ -z "$app_env" ]; then
    echo "❌ APP_ENV が選択されませんでした" >&2
    exit 1
  fi
  if grep -qE '^APP_ENV=' .env; then
    sed -i.bak "s/^APP_ENV=.*/APP_ENV=$app_env/" .env && rm -f .env.bak
  else
    printf 'APP_ENV=%s\n' "$app_env" >> .env
  fi
  echo "✔ APP_ENV=$app_env を .env に設定"
else
  echo "✔ APP_ENV=$app_env（設定済みのため変更しない）"
fi

# ---- 2. ホスト初期化（server のみ）-----------------------------------------
if [ "$app_env" != "local" ]; then
  echo ""
  echo "🖥  ホスト初期化（APP_ENV=$app_env）..."
  "$SCRIPT_DIR/init.sh"
  "$SCRIPT_DIR/host-apply.sh"
fi

# ---- 3. スタック起動 --------------------------------------------------------
echo ""
echo "📦 スタック起動..."
make --no-print-directory up

# ---- 4. 検収 ----------------------------------------------------------------
echo ""
echo "🔍 検収..."
"$SCRIPT_DIR/check-env.sh" || echo "⚠️  check-env で警告あり（上記を確認）"
make --no-print-directory ps
echo ""
echo "✅ setup 完了"
echo "💡 証明書は Traefik の ACME が自動で取る: docker compose logs traefik | grep -i acme"
