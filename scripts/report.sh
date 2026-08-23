#!/bin/bash
# 運用レポート送信（イベント駆動）。運用通知ハブ（console /internal/notify）へ、未達なら journald のみ。
# 複数行本文は python3 で JSON エンコードして送る（改行/特殊文字で壊さない）。
# Usage:
#   report.sh os          # dnf-automatic の本文を stdin で受け、適用があれば通知
#   report.sh bans        # 遮断状況のサマリを通知（旧 fail2ban）
#   report.sh disk-usage  # ディレクトリ別の使用量を console へ記録（通知はしない）
#   report.sh bans-sync   # 遮断の状態を console へ同期し、解除要求を実行（通知はしない。旧 f2b-sync）
#   report.sh timers      # systemd timer の状態を console へ同期し、操作を実行（通知はしない）
#   report.sh reboot-sync # 再起動待ちの状態を console へ同期し、予約を実行（通知はしない）
#   report.sh host-sync   # 上の bans-sync・timers・reboot-sync をまとめて実行（host-sync.timer から呼ぶ）
#   report.sh reboot-check # kernel 更新後の再起動待ちを検知し、待ちがある間は毎日 warning

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
[ -f "$ROOT_DIR/.env" ] && { set -a; . "$ROOT_DIR/.env"; set +a; }

# CrowdSec の CLI。実体はコンテナの中にしか無いので compose 越しに叩く。
# 出力が空 / 非 JSON でも呼び出し側が落ちないよう、失敗は呼び出し側で見る
cscli() {
  ( cd "$ROOT_DIR" && sudo docker compose exec -T crowdsec cscli "$@" )
}

# console への同期を数回まで再試行する。
#
# 相手は同じホストの console コンテナで、デプロイでの入れ替わりや一瞬の詰まりで
# 接続リセットになる。5 分後の次回実行では復旧するのに、その 1 回で unit が失敗し
# OnFailure の通知が飛んでいた（2026-08-09 の遮断状態の同期）。
# 送っているのは状態のスナップショットなので、同じ内容を送り直しても副作用は無い。
retry_sync() {
  local attempt=1
  while true; do
    "$@" && return 0
    if [ "$attempt" -ge 3 ]; then
      return 1
    fi
    echo "⏳ 同期に失敗したため再試行する（${attempt}/2）" >&2
    attempt=$((attempt + 1))
    sleep 5
  done
}

# $1=タイトル, stdin=本文（複数行可）。journald に残しつつ通知ハブへ送る。
# $1=タイトル, $2="routine" なら定例便（一覧・未読バッジから既定で除外される生存信号）
send() {
  local title="$1" routine="${2:-}" body
  body="$(cat)"
  echo "=== $title ==="
  echo "$body"
  # 表示のみモード（make bans 等）。ハブには送らず標準出力だけ。
  [ "${NOTIFY_DISABLE:-}" = 1 ] && return 0
  python3 - "${OPS_NOTIFY_URL:-http://127.0.0.1:9090}" "$title" "$body" "$routine" <<'PY'
import json, os, sys, urllib.request
url, title, body, routine = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = json.dumps({
    "source": "host",
    "level": "info",
    "routine": routine == "routine",
    "title": title[:200],
    "body": body[:10000] or None,
}).encode()
# Accept が無いと Laravel はエラーを HTML で返し、原因が読めなくなる
headers = {"Content-Type": "application/json", "Accept": "application/json"}
# 内部通信の共有トークン（fail-closed。未設定だとハブが 403 を返す＝journald のみに残る）
token = os.environ.get("INTERNAL_TOKEN")
if token:
    headers["X-Internal-Token"] = token
req = urllib.request.Request(url.rstrip("/") + "/internal/notify", data=data,
                             headers=headers)
try:
    urllib.request.urlopen(req, timeout=10)
    print("✅ 通知ハブへ送信")
except Exception as e:
    print(f"⚠️ 通知ハブへの送信失敗: {e}", file=sys.stderr)
PY
}

case "${1:-}" in
  os)
    # dnf-automatic の command emitter から本文を stdin で受ける。
    body="$(cat)"
    # 適用が無い場合（"No updates available." 等）は通知しない＝イベント駆動。
    if printf '%s\n' "$body" | grep -qiE 'upgrad|install'; then
      printf '%s\n' "$body" | send "🟢 OS security 更新を適用"
    else
      echo "ℹ️ OS 更新の適用なし（通知スキップ）"
    fi
    ;;
  bans)
    # --no-notify で通知ハブ送信を抑止（表示のみ。make bans 用）
    [ "${2:-}" = "--no-notify" ] && NOTIFY_DISABLE=1

    # 「新規」は alert（検知した出来事）の 24 時間ぶんを数える。
    # fail2ban 時代は累計カウンタの差分を .state に持って計算していたが、
    # CrowdSec は alert に時刻が入るので状態を持たずに正確な件数が出せる
    DEC_FILE="$(mktemp)"; ALERT_FILE="$(mktemp)"
    trap 'rm -f "$DEC_FILE" "$ALERT_FILE"' EXIT

    cscli decisions list -o json > "$DEC_FILE" 2>/dev/null || : > "$DEC_FILE"
    cscli alerts list --since 24h -o json > "$ALERT_FILE" 2>/dev/null || : > "$ALERT_FILE"

    python3 - "$SCRIPT_DIR" "$DEC_FILE" "$ALERT_FILE" <<'PY' | send "🛡️ 不正アクセス遮断 日報" routine
import sys
sys.path.insert(0, sys.argv[1])
from crowdsec_json import iter_decisions, label_of, load

decisions = load(sys.argv[2])
alerts = load(sys.argv[3])

if decisions is None and alerts is None:
    print("（CrowdSec に問い合わせできなかった。docker compose ps crowdsec を確認）")
    raise SystemExit(0)

# 過去 24 時間の新規（alert 単位。同じ IP が別シナリオで挙がれば別件）
new_by = {}
for alert in alerts or []:
    if not isinstance(alert, dict):
        continue
    scenario = alert.get("scenario") or "unknown"
    new_by[scenario] = new_by.get(scenario, 0) + 1
new_total = sum(new_by.values())

# 遮断継続中（decision 単位）
active = {}
for alert, decision in iter_decisions(decisions):
    scenario = decision.get("scenario") or alert.get("scenario") or "manual"
    active.setdefault(scenario, []).append(decision.get("value") or "?")

print(f"過去 24 時間の新規遮断: {new_total} 件")
for scenario, count in sorted(new_by.items(), key=lambda kv: -kv[1]):
    print(f"- {label_of(scenario)}: {count} 件")
print()

if active:
    print("遮断継続中（期限で自動解除）:")
    for scenario, ips in sorted(active.items(), key=lambda kv: -len(kv[1])):
        print(f"- {label_of(scenario)}: {len(ips)} 件")
        for ip in sorted(set(ips))[:20]:
            print(f"  - {ip}")
        if len(ips) > 20:
            print(f"  - ほか {len(ips) - 20} 件（make bans）")
else:
    print("遮断継続中: なし")
PY
    ;;
  disk-usage)
    # console はコンテナなので du ではホストの /var/lib/docker 等が見えない。
    # 計測はホスト側で行い、記録だけ送る（通知はしない。増えた時に画面で辿るための材料）。
    # 全域を walk するため数十秒かかる。日次タイマー前提
    # 計測結果は一時ファイルで渡す。python3 のプログラム自体をヒアドキュメント（stdin）で
    # 与えているため、同じ stdin にパイプを流しても読めない
    # 深さ 3 まで取る。/var/lib/docker まで見えれば「何が太ったか」は特定でき、
    # その先はツール側（docker system df 等）で見る話になる
    DU_FILE="$(mktemp)"
    trap 'rm -f "$DU_FILE"' EXIT
    sudo du -x --max-depth=3 -B1 / 2>/dev/null > "$DU_FILE"
    if [ ! -s "$DU_FILE" ]; then
      echo "⚠️ du に失敗したため記録をスキップ" >&2
      exit 1
    fi

    python3 - "${OPS_NOTIFY_URL:-http://127.0.0.1:9090}" "$DU_FILE" <<'PY'
import json, os, sys, urllib.request

url, du_file = sys.argv[1], sys.argv[2]
# 2 階層目より深いものは大きいものだけ残す（/var/lib/docker は見たいが、細かい枝は要らない）。
# 1 階層目（/var /home 等）はサイズを問わず全部残す — 画面の入口になるため
MIN_DEEP_BYTES = 100 * 1024 * 1024

entries = []
with open(du_file, encoding="utf-8", errors="replace") as f:
    for line in f:
        parts = line.rstrip("\n").split("\t", 1)
        if len(parts) != 2:
            continue
        try:
            size = int(parts[0])
        except ValueError:
            continue
        path = parts[1]
        # ルート合計は console が df から記録済みなので送らない
        if path == "/":
            continue
        if path.count("/") >= 2 and size < MIN_DEEP_BYTES:
            continue
        entries.append({"name": path[:200], "bytes": size})

# 掘って見る画面にするので、深い枝を落とすときも親は必ず残す
entries.sort(key=lambda e: -e["bytes"])
entries = entries[:400]
if not entries:
    print("⚠️ 記録対象が空", file=sys.stderr)
    sys.exit(1)

data = json.dumps({"scope": "/", "entries": entries}).encode()
# Accept が無いと Laravel はエラーを HTML で返し、原因が読めなくなる
headers = {"Content-Type": "application/json", "Accept": "application/json"}
token = os.environ.get("INTERNAL_TOKEN")
if token:
    headers["X-Internal-Token"] = token
req = urllib.request.Request(url.rstrip("/") + "/internal/capacity", data=data, headers=headers)
try:
    urllib.request.urlopen(req, timeout=30)
    print(f"✅ ディレクトリ別使用量を記録（{len(entries)} 件）")
except Exception as e:
    print(f"⚠️ 使用量の記録に失敗: {e}", file=sys.stderr)
    sys.exit(1)
PY
    ;;
  bans-sync)
    # CrowdSec はコンテナの中にしか無いので、状態を console へ送り、溜まっている操作要求を
    # 受け取って実行する。1 回の実行で「送る → 実行する → 結果を返す」まで終わらせる。
    #
    # console 側の受け口（POST /internal/fail2ban）とその JSON の形は fail2ban 時代のまま。
    # 「ジェイル」に相当するものは CrowdSec のシナリオ名（crowdsecurity/http-probing 等）。
    DEC_FILE="$(mktemp)"; REQ_FILE="$(mktemp)"; RES_FILE="$(mktemp)"; ALLOW_FILE="$(mktemp)"
    trap 'rm -f "$DEC_FILE" "$REQ_FILE" "$RES_FILE" "$ALLOW_FILE"' EXIT
    : > "$RES_FILE"

    # 遮断中の decision を JSON のまま取る。
    # 中身が空でも空ファイルにしておき、python 側で「問い合わせ失敗」と区別する
    collect_decisions() {
      cscli decisions list -o json > "$DEC_FILE" 2>/dev/null || : > "$DEC_FILE"
    }

    # 除外リストの中身も送る。画面から中身を見て操作できるようにするため。
    # 正は crowdsec/generated/allowlist.tsv（1 行 = IP<TAB>理由）
    collect_allowed() {
      cat "$ROOT_DIR/crowdsec/generated/allowlist.tsv" > "$ALLOW_FILE" 2>/dev/null || : > "$ALLOW_FILE"
    }

    # REQ_FILE に未処理の操作（id<TAB>action<TAB>ip<TAB>理由）を書き出す
    sync_once() {
      python3 - "${OPS_NOTIFY_URL:-http://127.0.0.1:9090}" "$DEC_FILE" "$RES_FILE" "$REQ_FILE" "$ALLOW_FILE" "$SCRIPT_DIR" <<'PY'
import json, os, sys, urllib.request

url, dec_file, res_file, req_file, allow_file, script_dir = sys.argv[1:7]
sys.path.insert(0, script_dir)
from crowdsec_json import banned_at, expires_at, iter_decisions, load

decisions = load(dec_file)
if decisions is None:
    print("⚠️ CrowdSec に問い合わせできなかったので同期しない", file=sys.stderr)
    sys.exit(1)

# シナリオごとにまとめる。fail2ban のジェイル 1 件に相当する
jails = {}
for alert, decision in iter_decisions(decisions):
    scenario = (decision.get("scenario") or alert.get("scenario") or "manual")[:50]
    jail = jails.setdefault(scenario, {
        "name": scenario,
        "currentlyBanned": 0,
        # CrowdSec には「導入からの累計」に当たるカウンタが無い。
        # 長期の通算は console の ban_records が持っているので、ここは現在数と同じ値を送る
        "totalBanned": 0,
        "ips": [],
    })
    if len(jail["ips"]) >= 1000:
        continue
    jail["ips"].append({
        "ip": str(decision.get("value"))[:45],
        "bannedAt": banned_at(alert),
        "expiresAt": expires_at(decision),
    })

for jail in jails.values():
    jail["currentlyBanned"] = len(jail["ips"])
    jail["totalBanned"] = len(jail["ips"])

jails = list(jails.values())[:50]

results = []
with open(res_file, encoding="utf-8", errors="replace") as f:
    for line in f:
        cols = line.rstrip("\n").split("\t", 1)
        if not cols[0]:
            continue
        results.append({"id": int(cols[0]), "error": (cols[1] if len(cols) > 1 and cols[1] else None)})

allowed = []
try:
    with open(allow_file, encoding="utf-8", errors="replace") as f:
        for line in f:
            cols = line.rstrip("\n").split("\t", 1)
            ip = cols[0].strip()
            if not ip or ip.startswith("#"):
                continue
            allowed.append({
                "ip": ip[:45],
                "note": (cols[1].strip()[:200] if len(cols) > 1 and cols[1].strip() else None),
            })
    allowed = allowed[:1000]
except FileNotFoundError:
    pass

data = json.dumps({"jails": jails, "allowed": allowed, "results": results}).encode()
# Accept が無いと Laravel はエラーを HTML で返し、原因が読めなくなる
headers = {"Content-Type": "application/json", "Accept": "application/json"}
token = os.environ.get("INTERNAL_TOKEN")
if token:
    headers["X-Internal-Token"] = token
# 受け口のパスは fail2ban 時代のまま（console 側の契約は変えていない）
req = urllib.request.Request(url.rstrip("/") + "/internal/fail2ban", data=data, headers=headers)
try:
    with urllib.request.urlopen(req, timeout=30) as res:
        raw = res.read().decode(errors="replace")
except urllib.error.HTTPError as e:
    detail = e.read().decode(errors="replace")[:300]
    print(f"⚠️ 遮断状態の同期に失敗: HTTP {e.code} {detail}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"⚠️ 遮断状態の同期に失敗: {e}", file=sys.stderr)
    sys.exit(1)

try:
    body = json.loads(raw)
except ValueError:
    # デプロイ中は console が入れ替わり、JSON 以外が返ることがある。次回の実行で復旧する
    print(f"⚠️ 遮断状態の同期の応答が JSON でない: {raw[:300]!r}", file=sys.stderr)
    sys.exit(1)

pending = body.get("operations") or []
with open(req_file, "w", encoding="utf-8") as f:
    for r in pending:
        note = (r.get("note") or "").replace("\t", " ").replace("\n", " ")
        f.write(f"{r['id']}\t{r['action']}\t{r['ip']}\t{note}\n")

print(f"✅ 遮断状態を同期（シナリオ {len(jails)} 件・除外 {len(allowed)} 件・操作 {len(pending)} 件）")
PY
    }

    collect_decisions
    collect_allowed
    retry_sync sync_once || exit 1

    # 操作があれば実行し、状態を取り直して結果ごと送り返す。
    # 実体は ban.sh に寄せる（make ban と管理画面で同じ処理を通す）
    if [ -s "$REQ_FILE" ]; then
      while IFS=$'\t' read -r id action ip note; do
        [ -n "$id" ] || continue
        if err="$("$SCRIPT_DIR/ban.sh" "$action" "$ip" "$note" 2>&1)"; then
          printf '%s\t\n' "$id" >> "$RES_FILE"
          echo "✅ $action $ip"
        else
          printf '%s\t%s\n' "$id" "$(printf '%s' "$err" | tail -1 | cut -c1-300)" >> "$RES_FILE"
          echo "⚠️ $action 失敗 $ip: $err" >&2
        fi
      done < "$REQ_FILE"

      collect_decisions
      collect_allowed
      retry_sync sync_once || exit 1
    fi
    ;;
  timers)
    # 自動実行の一覧を console へ送り、画面から積まれた操作を実行する。
    # 「失敗したら通知」だけでは timer 自体が止まった時に気づけないため、
    # 動いていること・次の予定・前回の結果をまとめて送って画面で見えるようにする。
    TASK_FILE="$(mktemp)"; TREQ_FILE="$(mktemp)"; TRES_FILE="$(mktemp)"
    trap 'rm -f "$TASK_FILE" "$TREQ_FILE" "$TRES_FILE"' EXIT
    : > "$TRES_FILE"

    # systemctl show の出力から 1 プロパティを取り出す
    prop() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

    # --timestamp=unix の値（@1754179800）を秒に。未実行なら空
    epoch_of() { case "$1" in @[0-9]*) printf '%s' "${1#@}" ;; *) printf '' ;; esac; }

    # 直近の実行が何を出力したか。改行を含むので base64 にして 1 列へ収める。
    # 成功・失敗と所要時間だけでは中身が分からず、結局ここを見にサーバーへ入ることになっていた
    last_log() {
      # 時刻は残したいがホスト名は要らない（単一 EC2 で毎行同じ値が入るだけ）
      journalctl -u "$1" -n 20 --no-pager -o short-iso --no-hostname 2>/dev/null \
        | tail -c 4000 | base64 | tr -d '\n'
    }

    # unit 1 件を TSV 1 行にする。
    # key/ラベル/間隔/自前か/有効か/状態/前回時刻/前回結果/所要ms/次回時刻/直近ログ(base64)
    # 扱ってよい unit はここで決め打つ。一覧に出す側と操作する側の両方がこれを見る。
    #
    # 「実体が repo を指しているか」で判定していた時期があるが、systemd の標準の置き場所へ
    # コピーして使うものが自前なのに落ちた（2026-08-04）。
    # OS が最初から持っていて、こちらが何も設定していないもの（man の索引更新など）は送らない。
    # logrotate は unit こそ OS のものだが設定はこちらが配っているので出す。
    #
    # 証明書更新（cert-renew.timer）と遮断リストの保存（ipset-persist.service）は
    # Traefik + CrowdSec への切替で無くなった。証明書は Traefik の ACME が自動更新し、
    # 遮断は CrowdSec の DB（名前付き volume）に残るので、どちらも timer が要らない。
    is_managed_unit() {
      case "$1" in
        dnf-automatic.timer|report-bans.timer|report-disk-usage.timer|\
        report-reboot-check.timer|host-sync.timer|docker-prune.timer|logrotate.timer) return 0 ;;
        *) return 1 ;;
      esac
    }

    emit_unit() {
      local unit="$1" schedule="$2" next="$3" enabled="$4" state="$5" label="$6" svc="$7"
      local s start exit_ts result status last_result duration

      is_managed_unit "$unit" || return 0

      s="$(systemctl show "$svc" --timestamp=unix --no-pager \
        -p Result,ExecMainStatus,ExecMainStartTimestamp,ExecMainExitTimestamp 2>/dev/null)"

      start="$(epoch_of "$(prop "$s" ExecMainStartTimestamp)")"
      exit_ts="$(epoch_of "$(prop "$s" ExecMainExitTimestamp)")"
      result="$(prop "$s" Result)"; status="$(prop "$s" ExecMainStatus)"

      last_result=""; duration=""
      if [ -n "$start" ]; then
        if [ "$result" = "success" ] && { [ -z "$status" ] || [ "$status" = "0" ]; }; then
          last_result="ok"
        else
          last_result="failed"
        fi
        [ -n "$exit_ts" ] && [ "$exit_ts" -ge "$start" ] && duration=$(( (exit_ts - start) * 1000 ))
      fi

      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$unit" "${label:-$unit}" "$schedule" "true" "$enabled" "$state" \
        "$start" "$last_result" "$duration" "$next" "$(last_log "$svc")" >> "$TASK_FILE"
    }

    collect_tasks() {
      : > "$TASK_FILE"
      local units u t svc schedule next enabled state

      units="$(systemctl list-units --type=timer --all --no-legend --plain --no-pager 2>/dev/null \
        | awk '{print $1}' | grep '\.timer$' || true)"

      for u in $units; do
        t="$(systemctl show "$u" --timestamp=unix --no-pager \
          -p Description,ActiveState,NextElapseUSecRealtime,Unit,TimersCalendar,TimersMonotonic 2>/dev/null)"
        svc="$(prop "$t" Unit)"; [ -n "$svc" ] || svc="${u%.timer}.service"

        # 間隔は OnCalendar（絶対時刻）を優先し、無ければ相対指定を使う。
        # 相対は OnUnitActive / OnUnitInactive / OnBoot / OnStartup と種類があるので
        # 最初に出てくる *USec= の値を取る（どれも「この間隔ごと」として読める）
        schedule="$(prop "$t" TimersCalendar | sed -E 's/.*OnCalendar=([^;]*).*/\1/; s/[[:space:]]+$//')"
        if [ -z "$schedule" ]; then
          schedule="$(prop "$t" TimersMonotonic \
            | sed -E 's/^\{[[:space:]]*[A-Za-z]+USec=([^;[:space:]]*).*/\1/; s/[[:space:]]+$//')"
        fi

        # --timestamp=unix では @秒 で来る。古い systemd では µs の生値なので両対応。
        # 予定が無い場合は n/a や 0、infinity（桁あふれ）で来るのでいずれも空にする
        next="$(prop "$t" NextElapseUSecRealtime)"
        case "$next" in
          @[0-9]*) next="${next#@}" ;;
          [0-9]*)
            if [ "${#next}" -le 18 ] && [ "$next" -gt 0 ] 2>/dev/null; then
              next=$(( next / 1000000 ))
            else
              next=""
            fi
            ;;
          *) next="" ;;
        esac

        state="$(prop "$t" ActiveState)"
        enabled=false; [ "$state" = "active" ] && enabled=true

        emit_unit "$u" "$schedule" "$next" "$enabled" "$state" "$(prop "$t" Description)" "$svc"
      done
    }

    sync_tasks() {
      python3 - "${OPS_NOTIFY_URL:-http://127.0.0.1:9090}" "$TASK_FILE" "$TRES_FILE" "$TREQ_FILE" <<'PY'
import base64, json, os, sys, urllib.request

url, task_file, res_file, req_file = sys.argv[1:5]

def num(v):
    return int(v) if v.strip().isdigit() else None

def logs(v):
    # 直近ログは base64。壊れていても同期そのものは止めない
    if not v:
        return None
    try:
        text = base64.b64decode(v).decode("utf-8", "replace").strip()
    except Exception:
        return None
    return text[-8000:] or None

def stamp(v):
    # epoch 秒 → ISO8601（UTC）。console 側は date で受ける
    import datetime
    n = num(v)
    if n is None:
        return None
    return datetime.datetime.fromtimestamp(n, datetime.timezone.utc).isoformat()

tasks = []
with open(task_file, encoding="utf-8", errors="replace") as f:
    for line in f:
        c = line.rstrip("\n").split("\t")
        if len(c) < 11 or not c[0]:
            continue
        tasks.append({
            "key": c[0][:120],
            "label": (c[1] or c[0])[:200],
            "schedule": (c[2][:120] or None),
            "managed": c[3] == "true",
            "enabled": c[4] == "true",
            "state": (c[5][:30] or None),
            "lastRunAt": stamp(c[6]),
            "lastResult": (c[7] or None),
            "lastDurationMs": num(c[8]),
            "nextRunAt": stamp(c[9]),
            "lastOutput": logs(c[10]),
        })
tasks = tasks[:100]

results = []
with open(res_file, encoding="utf-8", errors="replace") as f:
    for line in f:
        c = line.rstrip("\n").split("\t", 1)
        if not c[0]:
            continue
        results.append({"id": int(c[0]), "error": (c[1] if len(c) > 1 and c[1] else None)})

data = json.dumps({"tasks": tasks, "results": results}).encode()
# Accept が無いと Laravel はエラーを HTML で返し、原因が読めなくなる
headers = {"Content-Type": "application/json", "Accept": "application/json"}
token = os.environ.get("INTERNAL_TOKEN")
if token:
    headers["X-Internal-Token"] = token
req = urllib.request.Request(url.rstrip("/") + "/internal/scheduled-tasks", data=data, headers=headers)
try:
    with urllib.request.urlopen(req, timeout=30) as res:
        raw = res.read().decode(errors="replace")
except urllib.error.HTTPError as e:
    detail = e.read().decode(errors="replace")[:300]
    print(f"⚠️ 定期実行の同期に失敗: HTTP {e.code} {detail}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"⚠️ 定期実行の同期に失敗: {e}", file=sys.stderr)
    sys.exit(1)

try:
    body = json.loads(raw)
except ValueError:
    # デプロイ中は console が入れ替わり、JSON 以外が返ることがある。次回の実行で復旧する
    print(f"⚠️ 定期実行の同期の応答が JSON でない: {raw[:300]!r}", file=sys.stderr)
    sys.exit(1)

pending = body.get("operations") or []
with open(req_file, "w", encoding="utf-8") as f:
    for r in pending:
        f.write(f"{r['id']}\t{r['action']}\t{r['key']}\n")

print(f"✅ 定期実行を同期（{len(tasks)} 件・操作 {len(pending)} 件）")
PY
    }

    # 操作の実体。run は完了を待たない（週次 refresh 等は数分かかり、同期がタイムアウトするため）
    operate_unit() {
      local action="$1" unit="$2" svc

      # 操作指示は console の DB 経由で届く。console 側でも扱える unit に絞っているが、
      # DB へ書き込める者に root の systemctl をそのまま渡す形になるので、ここでも見る。
      # 一覧に出さない unit（sshd 等）は名前を指定されても動かさない
      if ! is_managed_unit "$unit"; then
        echo "扱わない unit: $unit" >&2
        return 1
      fi

      case "$action" in
        run)
          svc="$(systemctl show "$unit" --no-pager -p Unit 2>/dev/null | sed -n 's/^Unit=//p' | head -1)"
          case "$unit" in *.service) svc="$unit" ;; esac
          [ -n "$svc" ] || svc="${unit%.timer}.service"
          sudo systemctl start --no-block "$svc"
          ;;
        enable) sudo systemctl enable --now "$unit" ;;
        disable) sudo systemctl disable --now "$unit" ;;
        *) echo "未対応の操作: $action" >&2; return 1 ;;
      esac
    }

    collect_tasks
    retry_sync sync_tasks || exit 1

    if [ -s "$TREQ_FILE" ]; then
      while IFS=$'\t' read -r id action unit; do
        [ -n "$id" ] || continue
        if err="$(operate_unit "$action" "$unit" 2>&1)"; then
          printf '%s\t\n' "$id" >> "$TRES_FILE"
          echo "✅ $action $unit"
        else
          printf '%s\t%s\n' "$id" "$(printf '%s' "$err" | tail -1 | cut -c1-500)" >> "$TRES_FILE"
          echo "⚠️ $action 失敗 $unit: $err" >&2
        fi
      done < "$TREQ_FILE"

      collect_tasks
      retry_sync sync_tasks || exit 1
    fi
    ;;
  reboot-sync)
    # 再起動待ちの状態を console へ送り、画面から積まれた予約を受け取って実行する。
    # console はコンテナなのでホストを再起動できない。ここが唯一の実行役。
    RES_FILE="$(mktemp)"; REQ_FILE="$(mktemp)"
    trap 'rm -f "$RES_FILE" "$REQ_FILE"' EXIT
    : > "$RES_FILE"

    # kernel 等の更新で再起動待ちか
    reboot_required() {
      command -v needs-restarting >/dev/null 2>&1 || return 1
      ! needs-restarting -r >/dev/null 2>&1
    }

    # OS に入っている予約。systemd は予定時刻をここに置く
    scheduled_at() {
      local usec
      [ -f /run/systemd/shutdown/scheduled ] || return 0
      usec="$(sed -n 's/^USEC=//p' /run/systemd/shutdown/scheduled | head -1)"
      [ -n "$usec" ] || return 0
      date -u -d "@$(( usec / 1000000 ))" +%Y-%m-%dT%H:%M:%SZ
    }

    # 最後に起動した時刻。予約どおりに落ちたのか、勝手に落ちたのかの区別に使う
    booted_at() {
      date -u -d "$(uptime -s)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true
    }

    sync_reboot() {
      python3 - "${OPS_NOTIFY_URL:-http://127.0.0.1:9090}" "$1" "$2" "$3" "$4" "$RES_FILE" "$REQ_FILE" <<'PY'
import json, os, sys, urllib.request

url, required, since, scheduled, booted, res_file, req_file = sys.argv[1:8]

results = []
with open(res_file, encoding="utf-8", errors="replace") as f:
    for line in f:
        c = line.rstrip("\n").split("\t", 1)
        if not c[0]:
            continue
        results.append({"id": int(c[0]), "error": (c[1] if len(c) > 1 and c[1] else None)})

data = json.dumps({
    "required": required == "1",
    "requiredSince": since or None,
    "scheduledFor": scheduled or None,
    "bootedAt": booted or None,
    "results": results,
}).encode()
# Accept が無いと Laravel はエラーを HTML で返し、原因が読めなくなる
headers = {"Content-Type": "application/json", "Accept": "application/json"}
token = os.environ.get("INTERNAL_TOKEN")
if token:
    headers["X-Internal-Token"] = token
req = urllib.request.Request(url.rstrip("/") + "/internal/reboot", data=data, headers=headers)
try:
    with urllib.request.urlopen(req, timeout=30) as res:
        raw = res.read().decode(errors="replace")
except urllib.error.HTTPError as e:
    detail = e.read().decode(errors="replace")[:300]
    print(f"⚠️ 再起動状態の同期に失敗: HTTP {e.code} {detail}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"⚠️ 再起動状態の同期に失敗: {e}", file=sys.stderr)
    sys.exit(1)

try:
    body = json.loads(raw)
except ValueError:
    # デプロイ中は console が入れ替わり、JSON 以外が返ることがある。次回の実行で復旧する
    print(f"⚠️ 再起動状態の同期の応答が JSON でない: {raw[:300]!r}", file=sys.stderr)
    sys.exit(1)

pending = body.get("operations") or []
with open(req_file, "w", encoding="utf-8") as f:
    for r in pending:
        f.write(f"{r['id']}\t{r['action']}\t{r.get('scheduledFor') or ''}\n")

print(f"✅ 再起動状態を同期（操作 {len(pending)} 件）")
PY
    }

    # 予約は systemd の shutdown に任せる。プロセス常駐で待たない
    operate_reboot() {
      local action="$1" at="$2" local_time
      case "$action" in
        schedule)
          [ -n "$at" ] || { echo "予定時刻がありません" >&2; return 1; }
          # shutdown が受けるのはローカル時刻の hh:mm。console からは UTC の ISO8601 で来る
          local_time="$(date -d "$at" +%H:%M)" || return 1
          sudo shutdown -r "$local_time" "管理画面からの予約による再起動"
          ;;
        cancel) sudo shutdown -c ;;
        *) echo "未対応の操作: $action" >&2; return 1 ;;
      esac
    }

    STATE_FILE="$ROOT_DIR/.state/reboot-required"
    required=0; since=""
    if reboot_required; then
      required=1
      mkdir -p "$(dirname "$STATE_FILE")"
      [ -f "$STATE_FILE" ] || date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE_FILE"
      since="$(cat "$STATE_FILE")"
    else
      rm -f "$STATE_FILE"
    fi

    retry_sync sync_reboot "$required" "$since" "$(scheduled_at)" "$(booted_at)" || exit 1

    if [ -s "$REQ_FILE" ]; then
      while IFS=$'\t' read -r id action at; do
        [ -n "$id" ] || continue
        if err="$(operate_reboot "$action" "$at" 2>&1)"; then
          printf '%s\t\n' "$id" >> "$RES_FILE"
          echo "✅ $action ${at:-now}"
        else
          printf '%s\t%s\n' "$id" "$(printf '%s' "$err" | tail -1 | cut -c1-300)" >> "$RES_FILE"
          echo "⚠️ $action 失敗: $err" >&2
        fi
      done < "$REQ_FILE"

      retry_sync sync_reboot "$required" "$since" "$(scheduled_at)" "$(booted_at)" || exit 1
    fi
    ;;
  host-sync)
    # 5 分ごとの定期同期。1 つ失敗しても残りは実行する
    rc=0
    "$0" bans-sync || rc=1
    "$0" timers || rc=1
    "$0" reboot-sync || rc=1
    exit "$rc"
    ;;
  reboot-check)
    # dnf-automatic は security 更新を自動で当てるが reboot = never。
    # kernel の更新は再起動するまで効かないので、待ちが出ていることを毎日鳴らし続ける。
    # 鳴らさないと、脆弱な kernel のまま走っていることに誰も気づけない。
    if ! command -v needs-restarting >/dev/null 2>&1; then
      echo "⚠️ needs-restarting がありません（dnf-utils 未導入）" >&2
      exit 1
    fi

    STATE_FILE="$ROOT_DIR/.state/reboot-required"
    detail="$(needs-restarting -r 2>&1)"; rc=$?

    if [ "$rc" -eq 0 ]; then
      # 再起動が済んだら「いつから待っているか」の記録も畳む
      rm -f "$STATE_FILE"
      echo "ℹ️ 再起動待ちなし（通知スキップ）"
      exit 0
    fi

    mkdir -p "$(dirname "$STATE_FILE")"
    [ -f "$STATE_FILE" ] || date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE_FILE"
    since="$(cat "$STATE_FILE")"
    days=$(( ( $(date -u +%s) - $(date -u -d "$since" +%s) ) / 86400 ))

    printf '%s\n\n最初に検知: %s（%d 日経過）\n対応: 利用の少ない時間帯に sudo reboot\n' \
      "$detail" "$since" "$days" \
      | "$SCRIPT_DIR/notify.sh" --warn "再起動待ち: kernel 等の更新が未反映（${days} 日経過）"
    ;;
  *)
    echo "usage: report.sh {os|bans|disk-usage|bans-sync|timers|reboot-sync|host-sync|reboot-check}" >&2
    exit 2
    ;;
esac
