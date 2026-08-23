#!/bin/bash
# .env と .env.example を照合する。
#  (1) キーの過不足（値は出力しない）
#  (2) APP_ENV が local 以外のとき、example の既定値のまま放置されたキーを炙り出す
#      （MAIL_MAILER=log のまま・AWS_* 空・*_REGION 不一致 等、環境ごとに設定すべき項目の漏れ）
# example の値は公開情報なので「example のまま」のキー名は表示するが、
# .env 固有の実値は一切出力しない（秘密を漏らさない）。
#
# 使い方: scripts/check-env.sh
set -euo pipefail
cd "$(dirname "$0")/.."  # .env/.env.example は repo ルート

EXAMPLE=".env.example"
ENV=".env"

[ -f "$EXAMPLE" ] || { echo "✗ $EXAMPLE が見つからない"; exit 2; }
[ -f "$ENV" ] || { echo "✗ $ENV が無い（cp $EXAMPLE $ENV してから設定する）"; exit 2; }

# 行頭の KEY= からキー名のみ抽出（コメント・空行・値は無視）
keys() { grep -oE '^[A-Z][A-Z0-9_]*=' "$1" | sed 's/=$//' | sort -u; }
# 指定キーの生値（最初の一致・KEY= 以降そのまま）
val() { grep -E "^$1=" "$2" | head -1 | sed "s/^$1=//"; }

missing_in_env=$(comm -23 <(keys "$EXAMPLE") <(keys "$ENV"))
missing_in_example=$(comm -13 <(keys "$EXAMPLE") <(keys "$ENV"))

status=0
if [ -n "$missing_in_env" ]; then
  echo "⚠ .env に無いキー（.env.example にあり / 設定漏れの可能性）:"
  echo "$missing_in_env" | sed 's/^/  - /'
  status=1
fi
if [ -n "$missing_in_example" ]; then
  echo "⚠ .env.example に無いキー（.env にあり / ドキュメント漏れの可能性）:"
  echo "$missing_in_example" | sed 's/^/  - /'
  status=1
fi

# (2) 環境ごとに設定すべき値の据え置き検査（local では既定一致が普通なのでスキップ）
app_env=$(val APP_ENV "$ENV" | tr -d "\"'")
if [ -n "$app_env" ] && [ "$app_env" != "local" ]; then
  # ホスト共通の既定値でよいキー。据え置きが正常なので検査から外す
  # （EDGE_NETWORK・OPS_NOTIFY_URL は既定のまま使うのが普通の構成）
  shared_defaults="APP_ENV EDGE_NETWORK OPS_NOTIFY_URL"

  unchanged=""
  for k in $(comm -12 <(keys "$EXAMPLE") <(keys "$ENV")); do
    case " $shared_defaults " in *" $k "*) continue ;; esac
    if [ "$(val "$k" "$EXAMPLE")" = "$(val "$k" "$ENV")" ]; then
      unchanged="${unchanged}  - ${k}"$'\n'
    fi
  done
  if [ -n "$unchanged" ]; then
    echo "⚠ APP_ENV=$app_env だが example 既定値のまま（環境ごとに設定すべき / 要確認）:"
    printf "%s" "$unchanged"
    status=1
  fi
fi

[ "$status" -eq 0 ] && echo "✓ .env は .env.example と整合（キー一致・既定据え置きなし）"
exit "$status"
