#!/bin/bash
# Event-driven operational reports. Posts to the notification hub (the ops console's
# /internal/notify); if that fails, the message stays in journald.
# Multi-line bodies are JSON-encoded with python3 so newlines and special characters
# cannot break the payload.
# Usage:
#   report.sh os          # read the dnf-automatic body on stdin, notify if anything was applied
#   report.sh bans        # notify a summary of blocking status
#   report.sh disk-usage  # record usage per directory in the console (no notification)
#   report.sh bans-sync   # sync blocking state to the console and run unblock requests (no notification)
#   report.sh timers      # sync systemd timer state to the console and run operations (no notification)
#   report.sh reboot-sync # sync reboot state to the console and apply scheduled reboots (no notification)
#   report.sh host-sync   # run bans-sync, timers and reboot-sync together (called by host-sync.timer)
#   report.sh reboot-check # detect a pending reboot after a kernel update and warn daily while it lasts

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
[ -f "$ROOT_DIR/.env" ] && { set -a; . "$ROOT_DIR/.env"; set +a; }

# A host without an ops console sets OPS_NOTIFY_URL to empty in .env. Every report and
# sync here targets the console, so exit quietly instead of failing the timers daily.
# Unset still means the default URL (a console on the same host).
if [ -n "${OPS_NOTIFY_URL+x}" ] && [ -z "$OPS_NOTIFY_URL" ]; then
  echo "No ops console configured (OPS_NOTIFY_URL is empty); nothing to report"
  exit 0
fi

# The CrowdSec CLI only exists inside the container, so go through compose.
# Empty or non-JSON output must not crash the caller; callers check the result themselves.
cscli() {
  ( cd "$ROOT_DIR" && sudo docker compose exec -T crowdsec cscli "$@" )
}

# Retry a sync to the console a few times.
#
# The peer is the ops console container on the same host, and a deployment or a brief
# stall shows up as a connection reset. The next run five minutes later would succeed, but
# that single failure fails the unit and fires an OnFailure notification.
# What is sent is a snapshot of current state, so resending the same content is harmless.
retry_sync() {
  local attempt=1
  while true; do
    "$@" && return 0
    if [ "$attempt" -ge 3 ]; then
      return 1
    fi
    echo "Sync failed, retrying (${attempt}/2)" >&2
    attempt=$((attempt + 1))
    sleep 5
  done
}

# $1=title, stdin=body (may be multi-line). Keeps it in journald and posts it to the hub.
# $2="routine" marks it as a routine heartbeat, which the hub excludes from lists and
# unread badges by default.
send() {
  local title="$1" routine="${2:-}" body
  body="$(cat)"
  echo "=== $title ==="
  echo "$body"
  # Display-only mode (make bans and friends): print to stdout, do not post.
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
# Without Accept the hub returns errors as HTML and the cause becomes unreadable
headers = {"Content-Type": "application/json", "Accept": "application/json"}
# Shared token for internal calls (fail-closed: without it the hub returns 403 and the
# message only stays in journald)
token = os.environ.get("INTERNAL_TOKEN")
if token:
    headers["X-Internal-Token"] = token
req = urllib.request.Request(url.rstrip("/") + "/internal/notify", data=data,
                             headers=headers)
try:
    urllib.request.urlopen(req, timeout=10)
    print("Sent to the notification hub")
except Exception as e:
    print(f"Failed to reach the notification hub: {e}", file=sys.stderr)
PY
}

case "${1:-}" in
  os)
    # The body arrives on stdin from the dnf-automatic command emitter.
    body="$(cat)"
    # Nothing applied ("No updates available." and similar) means no notification.
    if printf '%s\n' "$body" | grep -qiE 'upgrad|install'; then
      printf '%s\n' "$body" | send "OS security updates applied"
    else
      echo "No OS updates applied (notification skipped)"
    fi
    ;;
  bans)
    # --no-notify suppresses the post to the hub (display only, used by make bans)
    [ "${2:-}" = "--no-notify" ] && NOTIFY_DISABLE=1

    # "New" counts alerts (detected events) over the last 24 hours.
    # Alerts carry a timestamp, so an exact count needs no state of its own.
    DEC_FILE="$(mktemp)"; ALERT_FILE="$(mktemp)"
    trap 'rm -f "$DEC_FILE" "$ALERT_FILE"' EXIT

    cscli decisions list -o json > "$DEC_FILE" 2>/dev/null || : > "$DEC_FILE"
    cscli alerts list --since 24h -o json > "$ALERT_FILE" 2>/dev/null || : > "$ALERT_FILE"

    python3 - "$SCRIPT_DIR" "$DEC_FILE" "$ALERT_FILE" <<'PY' | send "Abuse blocking daily report" routine
import sys
sys.path.insert(0, sys.argv[1])
from crowdsec_json import iter_decisions, label_of, load

decisions = load(sys.argv[2])
alerts = load(sys.argv[3])

if decisions is None and alerts is None:
    print("(Could not query CrowdSec. Check docker compose ps crowdsec.)")
    raise SystemExit(0)

# New over the last 24 hours, counted per alert: the same IP under two scenarios counts twice
new_by = {}
for alert in alerts or []:
    if not isinstance(alert, dict):
        continue
    scenario = alert.get("scenario") or "unknown"
    new_by[scenario] = new_by.get(scenario, 0) + 1
new_total = sum(new_by.values())

# Currently blocked, counted per decision
active = {}
for alert, decision in iter_decisions(decisions):
    scenario = decision.get("scenario") or alert.get("scenario") or "manual"
    active.setdefault(scenario, []).append(decision.get("value") or "?")

print(f"New blocks in the last 24 hours: {new_total}")
for scenario, count in sorted(new_by.items(), key=lambda kv: -kv[1]):
    print(f"- {label_of(scenario)}: {count}")
print()

if active:
    print("Currently blocked (released automatically on expiry):")
    for scenario, ips in sorted(active.items(), key=lambda kv: -len(kv[1])):
        print(f"- {label_of(scenario)}: {len(ips)}")
        for ip in sorted(set(ips))[:20]:
            print(f"  - {ip}")
        if len(ips) > 20:
            print(f"  - and {len(ips) - 20} more (make bans)")
else:
    print("Currently blocked: none")
PY
    ;;
  disk-usage)
    # The ops console runs in a container, so du there cannot see the host's
    # /var/lib/docker and similar. Measure on the host and send only the record; there is
    # no notification, this is material for tracing growth on screen later.
    # It walks the whole filesystem and takes tens of seconds, hence a daily timer.
    # The measurement is passed through a temporary file: the python program itself is fed
    # on stdin as a heredoc, so a pipe into the same stdin could not be read.
    # Depth 3 is enough. Seeing as far as /var/lib/docker identifies what grew; anything
    # finer is a job for the tool itself (docker system df and friends).
    DU_FILE="$(mktemp)"
    trap 'rm -f "$DU_FILE"' EXIT
    sudo du -x --max-depth=3 -B1 / 2>/dev/null > "$DU_FILE"
    if [ ! -s "$DU_FILE" ]; then
      echo "du failed, skipping the record" >&2
      exit 1
    fi

    python3 - "${OPS_NOTIFY_URL:-http://127.0.0.1:9090}" "$DU_FILE" <<'PY'
import json, os, sys, urllib.request

url, du_file = sys.argv[1], sys.argv[2]
# Below the second level keep only the big entries (/var/lib/docker is worth seeing, the
# small branches are not). The first level (/var, /home, ...) is kept regardless of size,
# because it is the entry point on screen.
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
        # The console already records the root total from df, so do not send it
        if path == "/":
            continue
        if path.count("/") >= 2 and size < MIN_DEEP_BYTES:
            continue
        entries.append({"name": path[:200], "bytes": size})

# The screen is for drilling down, so always keep the parent even when deep branches go
entries.sort(key=lambda e: -e["bytes"])
entries = entries[:400]
if not entries:
    print("Nothing to record", file=sys.stderr)
    sys.exit(1)

data = json.dumps({"scope": "/", "entries": entries}).encode()
# Without Accept the hub returns errors as HTML and the cause becomes unreadable
headers = {"Content-Type": "application/json", "Accept": "application/json"}
token = os.environ.get("INTERNAL_TOKEN")
if token:
    headers["X-Internal-Token"] = token
req = urllib.request.Request(url.rstrip("/") + "/internal/capacity", data=data, headers=headers)
try:
    urllib.request.urlopen(req, timeout=30)
    print(f"Recorded disk usage per directory ({len(entries)} entries)")
except Exception as e:
    print(f"Failed to record usage: {e}", file=sys.stderr)
    sys.exit(1)
PY
    ;;
  bans-sync)
    # CrowdSec lives inside a container, so send its state to the console, take back the
    # queued operation requests and run them. One invocation covers send, execute and
    # report back.
    #
    # The console endpoint (POST /internal/fail2ban) and its JSON shape are a stable
    # contract from the fail2ban era. What used to be a "jail" is a CrowdSec scenario name
    # such as crowdsecurity/http-probing.
    DEC_FILE="$(mktemp)"; REQ_FILE="$(mktemp)"; RES_FILE="$(mktemp)"; ALLOW_FILE="$(mktemp)"
    trap 'rm -f "$DEC_FILE" "$REQ_FILE" "$RES_FILE" "$ALLOW_FILE"' EXIT
    : > "$RES_FILE"

    # Fetch the active decisions as JSON.
    # Leave an empty file when there is nothing, so python can tell it apart from a failed
    # query.
    collect_decisions() {
      cscli decisions list -o json > "$DEC_FILE" 2>/dev/null || : > "$DEC_FILE"
    }

    # Send the allowlist too, so it can be inspected and edited from the console.
    # The source of truth is crowdsec/generated/allowlist.tsv (one line = IP<TAB>note).
    collect_allowed() {
      cat "$ROOT_DIR/crowdsec/generated/allowlist.tsv" > "$ALLOW_FILE" 2>/dev/null || : > "$ALLOW_FILE"
    }

    # Writes the pending operations (id<TAB>action<TAB>ip<TAB>note) to REQ_FILE
    sync_once() {
      python3 - "${OPS_NOTIFY_URL:-http://127.0.0.1:9090}" "$DEC_FILE" "$RES_FILE" "$REQ_FILE" "$ALLOW_FILE" "$SCRIPT_DIR" <<'PY'
import json, os, sys, urllib.request

url, dec_file, res_file, req_file, allow_file, script_dir = sys.argv[1:7]
sys.path.insert(0, script_dir)
from crowdsec_json import banned_at, expires_at, iter_decisions, load

decisions = load(dec_file)
if decisions is None:
    print("Could not query CrowdSec, not syncing", file=sys.stderr)
    sys.exit(1)

# Group by scenario. One group corresponds to one fail2ban jail.
jails = {}
for alert, decision in iter_decisions(decisions):
    scenario = (decision.get("scenario") or alert.get("scenario") or "manual")[:50]
    jail = jails.setdefault(scenario, {
        "name": scenario,
        "currentlyBanned": 0,
        # CrowdSec has no counter equivalent to "total since install".
        # The console's ban_records holds the long-term total, so send the current count.
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
# Without Accept the hub returns errors as HTML and the cause becomes unreadable
headers = {"Content-Type": "application/json", "Accept": "application/json"}
token = os.environ.get("INTERNAL_TOKEN")
if token:
    headers["X-Internal-Token"] = token
# The endpoint path is unchanged from the fail2ban era (the console contract is stable)
req = urllib.request.Request(url.rstrip("/") + "/internal/fail2ban", data=data, headers=headers)
try:
    with urllib.request.urlopen(req, timeout=30) as res:
        raw = res.read().decode(errors="replace")
except urllib.error.HTTPError as e:
    detail = e.read().decode(errors="replace")[:300]
    print(f"Failed to sync blocking state: HTTP {e.code} {detail}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"Failed to sync blocking state: {e}", file=sys.stderr)
    sys.exit(1)

try:
    body = json.loads(raw)
except ValueError:
    # During a deployment the console is being replaced and may answer with non-JSON.
    # The next run recovers.
    print(f"Blocking state sync returned non-JSON: {raw[:300]!r}", file=sys.stderr)
    sys.exit(1)

pending = body.get("operations") or []
with open(req_file, "w", encoding="utf-8") as f:
    for r in pending:
        note = (r.get("note") or "").replace("\t", " ").replace("\n", " ")
        f.write(f"{r['id']}\t{r['action']}\t{r['ip']}\t{note}\n")

print(f"Synced blocking state ({len(jails)} scenarios, {len(allowed)} allowlisted, {len(pending)} operations)")
PY
    }

    collect_decisions
    collect_allowed
    retry_sync sync_once || exit 1

    # If there are operations, run them, re-read the state and send it back with the
    # results. ban.sh does the work, so make ban and the console go through the same path.
    if [ -s "$REQ_FILE" ]; then
      while IFS=$'\t' read -r id action ip note; do
        [ -n "$id" ] || continue
        if err="$("$SCRIPT_DIR/ban.sh" "$action" "$ip" "$note" 2>&1)"; then
          printf '%s\t\n' "$id" >> "$RES_FILE"
          echo "ok: $action $ip"
        else
          printf '%s\t%s\n' "$id" "$(printf '%s' "$err" | tail -1 | cut -c1-300)" >> "$RES_FILE"
          echo "failed: $action $ip: $err" >&2
        fi
      done < "$REQ_FILE"

      collect_decisions
      collect_allowed
      retry_sync sync_once || exit 1
    fi
    ;;
  timers)
    # Send the list of scheduled jobs to the console and run the operations queued there.
    # "Notify on failure" alone cannot tell you that a timer stopped running at all, so
    # send whether it is alive, when it runs next and how the last run went.
    TASK_FILE="$(mktemp)"; TREQ_FILE="$(mktemp)"; TRES_FILE="$(mktemp)"
    trap 'rm -f "$TASK_FILE" "$TREQ_FILE" "$TRES_FILE"' EXIT
    : > "$TRES_FILE"

    # Pull a single property out of systemctl show output
    prop() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

    # Convert a --timestamp=unix value (@1754179800) to seconds; empty when never run
    epoch_of() { case "$1" in @[0-9]*) printf '%s' "${1#@}" ;; *) printf '' ;; esac; }

    # What the last run printed. It contains newlines, so base64 it into one column.
    # Success, failure and duration alone say nothing about the content, and looking that
    # up meant logging into the server every time.
    last_log() {
      # Keep the timestamps but drop the host name (a single host repeats the same value
      # on every line)
      journalctl -u "$1" -n 20 --no-pager -o short-iso --no-hostname 2>/dev/null \
        | tail -c 4000 | base64 | tr -d '\n'
    }

    # Turn one unit into a single TSV line.
    # key/label/schedule/managed/enabled/state/last time/last result/duration ms/next time/recent log (base64)
    # The set of units to handle is decided here; both the listing side and the operating
    # side consult it.
    #
    # Deciding by "does the unit file point back into the repo" does not work: units that
    # are copied into systemd's standard location are ours as well.
    # Units that ship with the OS and that this repo does not configure (man page indexing
    # and the like) are not sent. logrotate is included even though the unit belongs to the
    # OS, because the configuration comes from here.
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

        # Prefer OnCalendar (absolute time) for the schedule and fall back to the relative
        # form. The relative form comes in several flavours (OnUnitActive, OnUnitInactive,
        # OnBoot, OnStartup), so take the first *USec= value; all of them read as
        # "every this often".
        schedule="$(prop "$t" TimersCalendar | sed -E 's/.*OnCalendar=([^;]*).*/\1/; s/[[:space:]]+$//')"
        if [ -z "$schedule" ]; then
          schedule="$(prop "$t" TimersMonotonic \
            | sed -E 's/^\{[[:space:]]*[A-Za-z]+USec=([^;[:space:]]*).*/\1/; s/[[:space:]]+$//')"
        fi

        # With --timestamp=unix this arrives as @seconds; older systemd gives raw
        # microseconds, so handle both. No scheduled run shows up as n/a, 0 or infinity
        # (overflow); blank all of those.
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
    # The recent log is base64. A broken value must not stop the sync itself.
    if not v:
        return None
    try:
        text = base64.b64decode(v).decode("utf-8", "replace").strip()
    except Exception:
        return None
    return text[-8000:] or None

def stamp(v):
    # epoch seconds -> ISO 8601 (UTC); the console parses it as a date
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
# Without Accept the hub returns errors as HTML and the cause becomes unreadable
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
    print(f"Failed to sync scheduled tasks: HTTP {e.code} {detail}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"Failed to sync scheduled tasks: {e}", file=sys.stderr)
    sys.exit(1)

try:
    body = json.loads(raw)
except ValueError:
    # During a deployment the console is being replaced and may answer with non-JSON.
    # The next run recovers.
    print(f"Scheduled task sync returned non-JSON: {raw[:300]!r}", file=sys.stderr)
    sys.exit(1)

pending = body.get("operations") or []
with open(req_file, "w", encoding="utf-8") as f:
    for r in pending:
        f.write(f"{r['id']}\t{r['action']}\t{r['key']}\n")

print(f"Synced scheduled tasks ({len(tasks)} tasks, {len(pending)} operations)")
PY
    }

    # Carrying out an operation. "run" does not wait for completion, because a job can take
    # minutes and the sync would time out.
    operate_unit() {
      local action="$1" unit="$2" svc

      # Operation requests arrive through the console database. The console restricts the
      # units it offers, but this effectively hands root systemctl to whoever can write
      # that table, so check here as well.
      # Units that are not on the list (sshd and so on) are never touched, even if named.
      if ! is_managed_unit "$unit"; then
        echo "unit not handled: $unit" >&2
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
        *) echo "unsupported operation: $action" >&2; return 1 ;;
      esac
    }

    collect_tasks
    retry_sync sync_tasks || exit 1

    if [ -s "$TREQ_FILE" ]; then
      while IFS=$'\t' read -r id action unit; do
        [ -n "$id" ] || continue
        if err="$(operate_unit "$action" "$unit" 2>&1)"; then
          printf '%s\t\n' "$id" >> "$TRES_FILE"
          echo "ok: $action $unit"
        else
          printf '%s\t%s\n' "$id" "$(printf '%s' "$err" | tail -1 | cut -c1-500)" >> "$TRES_FILE"
          echo "failed: $action $unit: $err" >&2
        fi
      done < "$TREQ_FILE"

      collect_tasks
      retry_sync sync_tasks || exit 1
    fi
    ;;
  reboot-sync)
    # Send the pending-reboot state to the console and carry out the reboots scheduled from
    # its screens. The console runs in a container and cannot reboot the host; this is the
    # only place that can.
    RES_FILE="$(mktemp)"; REQ_FILE="$(mktemp)"
    trap 'rm -f "$RES_FILE" "$REQ_FILE"' EXIT
    : > "$RES_FILE"

    # Is a reboot pending because of a kernel or similar update?
    reboot_required() {
      command -v needs-restarting >/dev/null 2>&1 || return 1
      ! needs-restarting -r >/dev/null 2>&1
    }

    # A reboot already scheduled in the OS; systemd keeps the time here
    scheduled_at() {
      local usec
      [ -f /run/systemd/shutdown/scheduled ] || return 0
      usec="$(sed -n 's/^USEC=//p' /run/systemd/shutdown/scheduled | head -1)"
      [ -n "$usec" ] || return 0
      date -u -d "@$(( usec / 1000000 ))" +%Y-%m-%dT%H:%M:%SZ
    }

    # Last boot time, used to tell a scheduled shutdown from an unexpected one
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
# Without Accept the hub returns errors as HTML and the cause becomes unreadable
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
    print(f"Failed to sync reboot state: HTTP {e.code} {detail}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"Failed to sync reboot state: {e}", file=sys.stderr)
    sys.exit(1)

try:
    body = json.loads(raw)
except ValueError:
    # During a deployment the console is being replaced and may answer with non-JSON.
    # The next run recovers.
    print(f"Reboot state sync returned non-JSON: {raw[:300]!r}", file=sys.stderr)
    sys.exit(1)

pending = body.get("operations") or []
with open(req_file, "w", encoding="utf-8") as f:
    for r in pending:
        f.write(f"{r['id']}\t{r['action']}\t{r.get('scheduledFor') or ''}\n")

print(f"Synced reboot state ({len(pending)} operations)")
PY
    }

    # Leave the scheduling to systemd's shutdown; do not keep a process waiting
    operate_reboot() {
      local action="$1" at="$2" local_time
      case "$action" in
        schedule)
          [ -n "$at" ] || { echo "no scheduled time given" >&2; return 1; }
          # shutdown takes local time as hh:mm; the console sends UTC ISO 8601
          local_time="$(date -d "$at" +%H:%M)" || return 1
          sudo shutdown -r "$local_time" "Reboot scheduled from the ops console"
          ;;
        cancel) sudo shutdown -c ;;
        *) echo "unsupported operation: $action" >&2; return 1 ;;
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
          echo "ok: $action ${at:-now}"
        else
          printf '%s\t%s\n' "$id" "$(printf '%s' "$err" | tail -1 | cut -c1-300)" >> "$RES_FILE"
          echo "failed: $action: $err" >&2
        fi
      done < "$REQ_FILE"

      retry_sync sync_reboot "$required" "$since" "$(scheduled_at)" "$(booted_at)" || exit 1
    fi
    ;;
  host-sync)
    # The five-minute periodic sync. If one part fails, the rest still run.
    rc=0
    "$0" bans-sync || rc=1
    "$0" timers || rc=1
    "$0" reboot-sync || rc=1
    exit "$rc"
    ;;
  reboot-check)
    # dnf-automatic applies security updates automatically but never reboots.
    # A kernel update does not take effect until a reboot, so keep warning every day while
    # one is outstanding. Without the reminder, nobody notices the machine is still running
    # a vulnerable kernel.
    if ! command -v needs-restarting >/dev/null 2>&1; then
      echo "needs-restarting is missing (dnf-utils is not installed)" >&2
      exit 1
    fi

    STATE_FILE="$ROOT_DIR/.state/reboot-required"
    detail="$(needs-restarting -r 2>&1)"; rc=$?

    if [ "$rc" -eq 0 ]; then
      # Once the reboot has happened, drop the record of when it started being due
      rm -f "$STATE_FILE"
      echo "No reboot pending (notification skipped)"
      exit 0
    fi

    mkdir -p "$(dirname "$STATE_FILE")"
    [ -f "$STATE_FILE" ] || date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE_FILE"
    since="$(cat "$STATE_FILE")"
    days=$(( ( $(date -u +%s) - $(date -u -d "$since" +%s) ) / 86400 ))

    printf '%s\n\nFirst detected: %s (%d days ago)\nAction: run sudo reboot during a quiet period\n' \
      "$detail" "$since" "$days" \
      | "$SCRIPT_DIR/notify.sh" --warn "Reboot pending: kernel or similar updates are not active yet (${days} days)"
    ;;
  *)
    echo "usage: report.sh {os|bans|disk-usage|bans-sync|timers|reboot-sync|host-sync|reboot-check}" >&2
    exit 2
    ;;
esac
