#!/bin/bash
# Shared selection helper. Use it with `source scripts/choose.sh` and
# `choose "prompt" option...`.
#
# Move with the arrow keys or j/k, confirm with Enter, cancel with q or ESC.
# fzf is not in the Amazon Linux 2023 repositories, so this is plain bash with no extra
# dependency.
#
# The chosen value goes to stdout and the UI to stderr, so callers can simply use
# $(choose ...). Without a tty it prints nothing and returns non-zero, and the caller
# prints usage.

choose() {
  local prompt="$1"; shift
  local options=("$@")
  local count=${#options[@]}

  [ -t 0 ] || return 1
  [ "$count" -gt 0 ] || return 1

  # A long list needs filtering, so hand over to fzf when it is available
  if command -v fzf > /dev/null 2>&1; then
    printf '%s\n' "${options[@]}" | fzf --height=~40% --reverse --prompt="$prompt > "
    return
  fi

  local index=0 key rest

  _choose_draw() {
    local i
    for ((i = 0; i < count; i++)); do
      if [ "$i" = "$index" ]; then
        # Reverse video marks the current position
        printf '\033[7m> %s\033[0m\n' "${options[$i]}" >&2
      else
        printf '  %s\n' "${options[$i]}" >&2
      fi
    done
  }

  # Move back over the lines just drawn and erase them, so no list is left behind
  _choose_clear() {
    printf '\033[%dA\033[J' "$count" >&2
  }

  printf '%s (arrows to move, Enter to confirm, q to cancel)\n' "$prompt" >&2
  _choose_draw

  while true; do
    IFS= read -rsn1 key < /dev/tty || { _choose_clear; return 1; }
    case "$key" in
      '')
        break
        ;;
      $'\033')
        # An arrow key is three bytes such as ESC [ A; a bare ESC cancels
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
