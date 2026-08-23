#!/bin/bash
# 未使用 docker イメージの週次掃除（docker-prune.service から実行 / 手動実行も可）
#
# デプロイのたびに新しいイメージを ECR から pull するため、前の版がホストに溜まる。
# 稼働中のコンテナが使っているイメージは消えないので、動いているものには影響しない。
#
# 以前はこのジョブが「土台イメージの週次作り直し」も担っていたが、
# ビルドは GitHub Actions へ移した（2026-08-04）。サーバー上で build すると
# メモリが尽きて全断するため、ここへ戻さないこと。
#
# Usage: ./docker-prune.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "===== 未使用イメージの掃除 開始 ====="

# image prune に絞る。system prune は停止中のコンテナ・未使用ネットワーク・build キャッシュも
# 消すため、手で止めておいたコンテナが週をまたぐと勝手に消え、全コンテナ停止中に走ると
# 共有ネットワーク（EDGE_NETWORK）ごと消えて次の起動が network not found で失敗する。
# ここが消したいのはデプロイのたびに積み上がる旧イメージだけ。
#
# -a: dangling だけでなく「どのコンテナも使っていない」タグ付き旧イメージも消す
PRUNE_OUT="$(docker image prune -af)"
echo "$PRUNE_OUT"
RECLAIMED="$(printf '%s\n' "$PRUNE_OUT" | grep -i 'reclaimed' | tail -1 || true)"

echo ""
echo "===== 未使用イメージの掃除 完了 ====="

# 掃除の結果を通知ハブへ（未設定なら journald のみ）。通知失敗でジョブは落とさない。
# 毎週必ず届くので、来ない週があればタイマーが止まったと分かる
"$SCRIPT_DIR/notify.sh" "未使用イメージの掃除" <<EOF || true
結果: 成功
所要: $((SECONDS / 60)) 分 $((SECONDS % 60)) 秒
掃除: ${RECLAIMED:-prune done}
EOF
