#!/bin/bash
# 選択 UI 共通ヘルパー。`source scripts/choose.sh` して `choose "プロンプト" 候補...` で使う。
#
# カーソル（↑↓ / jk）で選び Enter で決定する。q または ESC で取り消し。
# fzf は Amazon Linux 2023 のリポジトリに無いため、依存を足さず bash だけで実装している。
#
# 選ばれた値を stdout に返す。UI は stderr へ出すので、呼び出し側は素直に $(choose ...) で受け取れる。
# tty が無い場合は何も出さず非ゼロ終了（呼び出し側が usage を出す）。

choose() {
  local prompt="$1"; shift
  local options=("$@")
  local count=${#options[@]}

  [ -t 0 ] || return 1
  [ "$count" -gt 0 ] || return 1

  # 候補が多いときは絞り込みが要るので fzf があれば任せる
  if command -v fzf > /dev/null 2>&1; then
    printf '%s\n' "${options[@]}" | fzf --height=~40% --reverse --prompt="$prompt > "
    return
  fi

  local index=0 key rest

  _choose_draw() {
    local i
    for ((i = 0; i < count; i++)); do
      if [ "$i" = "$index" ]; then
        # 反転表示で現在位置を示す
        printf '\033[7m❯ %s\033[0m\n' "${options[$i]}" >&2
      else
        printf '  %s\n' "${options[$i]}" >&2
      fi
    done
  }

  # 描画した行数ぶん戻して消す（選択確定後に一覧を残さない）
  _choose_clear() {
    printf '\033[%dA\033[J' "$count" >&2
  }

  printf '%s（↑↓ で選択・Enter で決定・q で取消）\n' "$prompt" >&2
  _choose_draw

  while true; do
    IFS= read -rsn1 key < /dev/tty || { _choose_clear; return 1; }
    case "$key" in
      '')
        break
        ;;
      $'\033')
        # 矢印キーは ESC [ A のような 3 バイト。単独 ESC は取消
        if ! IFS= read -rsn2 -t 0.1 rest < /dev/tty; then
          _choose_clear
          return 1
        fi
        case "$rest" in
          '[A') index=$(((index - 1 + count) % count)) ;;
          '[B') index=$(((index + 1) % count)) ;;
        esac
        ;;
      k) index=$(((index - 1 + count) % count)) ;;
      j) index=$(((index + 1) % count)) ;;
      q)
        _choose_clear
        return 1
        ;;
    esac
    printf '\033[%dA' "$count" >&2
    _choose_draw
  done

  _choose_clear
  printf '%s\n' "${options[$index]}"
}
