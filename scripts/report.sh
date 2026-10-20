#!/bin/bash
# Event-driven operational reports. Nothing is sent anywhere: state snapshots, events and
# operation results are written into the host's file channel under sync/, and the ops
# console reads them from there. See scripts/sync-lib.sh for the layout. A host with no
# console writes exactly the same files and nobody reads them.
# JSON is built with python3, so newlines and special characters in a body cannot break it.
# Usage:
#   report.sh certs       # days left per certificate; warn when any is under 14 days
#   report.sh os          # read the dnf-automatic body on stdin, notify if anything was applied
#   report.sh bans        # record a summary of blocking status as a notification
#   report.sh disk-usage  # write directory sizes and large files in / to sync/state (no notification)
#   report.sh bans-sync   # write blocking state and run the queued IP operations (no notification)
#   report.sh timers      # write systemd timer state and run the queued operations (no notification)
#   report.sh reboot-sync # write reboot state and apply the scheduled reboots (no notification)
#   report.sh host-info   # write the facts about this host the console cannot derive itself
#   report.sh host-sync   # run bans-sync, timers, reboot-sync and host-info together (host-sync.timer)
#   report.sh reboot-check # detect a pending reboot after a kernel update and warn daily while it lasts

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
. "$SCRIPT_DIR/sync-lib.sh"
# EDGE_TLS_MODE decides where the certificates are read from, and together with
# EDGE_CROWDSEC whether there is any blocking on this host at all
. "$SCRIPT_DIR/mode-lib.sh"
edge_load_modes "$ROOT_DIR" || exit 1

# The CrowdSec CLI only exists inside the container, so go through compose.
# Empty or non-JSON output must not crash the caller; callers check the result themselves.
cscli() {
  ( cd "$ROOT_DIR" && sudo docker compose exec -T crowdsec cscli "$@" )
}

# $1=title, stdin=body (may be multi-line). Keeps it in journald and appends it to the
# event file the console reads. $2="routine" marks it as a routine heartbeat, which the
# console excludes from lists and unread badges by default.
send() {
  local title="$1" routine="${2:-}" body
  body="$(cat)"
  echo "=== $title ==="
  echo "$body"
  # Display-only mode (make bans and friends): print to stdout, record nothing.
  [ "${NOTIFY_DISABLE:-}" = 1 ] && return 0
  sync_append_event info "$title" "$body" "$routine"
}

case "${1:-}" in
  certs)
    # Daily certificate expiry report. Traefik renews automatically about 30 days
    # before expiry and nothing else watches the outcome, so a renewal that keeps
    # failing would only surface as an expired site. Read the ACME store, print the
    # days left per domain (visible as the timer's last output in the console), and
    # send a warning when any certificate has under 14 days left — by then the
    # automatic renewal has been failing for over two weeks.
    #
    # With EDGE_TLS_MODE=origin-ca there is no ACME store: the certificates are the files
    # in certs/, placed by hand and valid for 15 years. Nothing can fail to renew, but an
    # expiry date nobody ever looks at is exactly how those 15 years end in an outage, so
    # the same report is produced from the files. The same line also catches a mode switch
    # that left the wrong file behind.
    if [ "$EDGE_TLS_MODE" = "origin-ca" ]; then
      BODY_FILE="$(mktemp)"
      trap 'rm -f "$BODY_FILE"' EXIT
      warn=0
      for cert in "$ROOT_DIR"/certs/*.pem; do
        [ -f "$cert" ] || continue   # no match: the glob stays literal
        name="$(basename "$cert" .pem)"
        end="$(openssl x509 -noout -enddate -in "$cert" 2>/dev/null | sed -n 's/^notAfter=//p')"
        end_epoch=""
        [ -n "$end" ] && end_epoch="$(date -u -d "$end" +%s 2>/dev/null || true)"
        if [ -z "$end_epoch" ]; then
          echo "$name: unreadable certificate" >> "$BODY_FILE"
          warn=1
          continue
        fi
        days=$(( (end_epoch - $(date -u +%s)) / 86400 ))
        printf '%s: %d days left (expires %s)\n' \
          "$name" "$days" "$(date -u -d "@$end_epoch" +%Y-%m-%d)" >> "$BODY_FILE"
        [ "$days" -lt 14 ] && warn=1
      done
      if [ ! -s "$BODY_FILE" ]; then
        echo "No certificate in certs/ (with origin-ca that means nothing is served over HTTPS)" >> "$BODY_FILE"
        warn=1
      fi
      cat "$BODY_FILE"
      status=0
      if [ "$warn" -eq 1 ]; then
        "$SCRIPT_DIR/notify.sh" --warn "Certificate problem in certs/" < "$BODY_FILE" || status=1
      fi
      exit "$status"
    fi

    ACME_FILE="$ROOT_DIR/traefik/acme/acme.json"
    if ! sudo test -s "$ACME_FILE"; then
      echo "No ACME store yet ($ACME_FILE); nothing to report"
      exit 0
    fi
    # Pass the store through a temporary file: the python program itself arrives on
    # stdin as a heredoc, so piping the JSON into the same stdin cannot work.
    BODY_FILE="$(mktemp)"; STORE_FILE="$(mktemp)"
    trap 'rm -f "$BODY_FILE" "$STORE_FILE"' EXIT
    sudo cat "$ACME_FILE" > "$STORE_FILE"
    python3 - "$STORE_FILE" > "$BODY_FILE" <<'PY'
import base64, datetime, json, subprocess, sys

WARN_DAYS = 14
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
now = datetime.datetime.now(datetime.timezone.utc)
rows, warn = [], False
for resolver in (data or {}).values():
    for cert in (resolver or {}).get("Certificates") or []:
        domain = (cert.get("domain") or {}).get("main") or "?"
        pem = base64.b64decode(cert.get("certificate") or "")
        # The blob is the full chain; openssl reads the first block, which is the leaf
        out = subprocess.run(["openssl", "x509", "-noout", "-enddate"],
                             input=pem, capture_output=True)
        text = out.stdout.decode().strip()  # notAfter=Aug 24 12:00:00 2026 GMT
        try:
            end = datetime.datetime.strptime(text.split("=", 1)[1], "%b %d %H:%M:%S %Y %Z")
            end = end.replace(tzinfo=datetime.timezone.utc)
        except (IndexError, ValueError):
            rows.append(f"{domain}: unreadable certificate")
            warn = True
            continue
        days = (end - now).days
        rows.append(f"{domain}: {days} days left (expires {end.date()})")
        if days < WARN_DAYS:
            warn = True
if not rows:
    rows.append("No certificates in the store")
print("\n".join(rows))
sys.exit(2 if warn else 0)
PY
    status=$?
    cat "$BODY_FILE"
    if [ "$status" -eq 2 ]; then
      "$SCRIPT_DIR/notify.sh" --warn "Certificate renewal overdue" < "$BODY_FILE"
    elif [ "$status" -ne 0 ]; then
      echo "Could not read the ACME store" >&2
      exit 1
    fi
    ;;
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
    # --no-notify records nothing for the console (display only, used by make bans)
    [ "${2:-}" = "--no-notify" ] && NOTIFY_DISABLE=1

    # Nothing blocks on this host, so there is nothing to report. Say that instead of
    # sending a daily "0 blocks" that reads like a quiet day behind a working guard.
    if ! crowdsec_enabled; then
      echo "CrowdSec does not run on this host ($(crowdsec_off_reason)): nothing blocks, nothing to report"
      exit 0
    fi

    # "New" counts alerts (detected events) over the last 24 hours.
    # Alerts carry a timestamp, so an exact count needs no state of its own.
    DEC_FILE="$(mktemp)"; ALERT_FILE="$(mktemp)"; ALL_FILE="$(mktemp)"
    trap 'rm -f "$DEC_FILE" "$ALERT_FILE" "$ALL_FILE"' EXIT

    cscli decisions list -o json > "$DEC_FILE" 2>/dev/null || : > "$DEC_FILE"
    cscli alerts list --since 24h -o json > "$ALERT_FILE" 2>/dev/null || : > "$ALERT_FILE"
    cscli decisions list -a -o json > "$ALL_FILE" 2>/dev/null || : > "$ALL_FILE"

    python3 - "$SCRIPT_DIR" "$DEC_FILE" "$ALERT_FILE" "$ALL_FILE" <<'PY' | send "Abuse blocking daily report" routine
import sys
sys.path.insert(0, sys.argv[1])
from crowdsec_json import community_count, iter_decisions, label_of, load

decisions = load(sys.argv[2])
alerts = load(sys.argv[3])
all_decisions = load(sys.argv[4])

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

# The community blocklist blocks known bad IPs before they can trip a local scenario.
# Without this line the local figures alone read as "barely defended".
if all_decisions is not None:
    print()
    print(f"Community blocklist: pre-emptively blocking {community_count(all_decisions)} known bad IPs")
PY
    ;;
  disk-usage)
    # The ops console runs in a container, so du there cannot see the host's
    # /var/lib/docker and similar. Measure on the host and write the record; there is
    # no notification, this is material for tracing growth on screen later.
    # It walks the whole filesystem and takes tens of seconds, hence a daily timer.
    # The measurement is passed through a temporary file: the python program itself is fed
    # on stdin as a heredoc, so a pipe into the same stdin could not be read.
    # Depth 3 is enough. Seeing as far as /var/lib/docker identifies what grew; anything
    # finer is a job for the tool itself (docker system df and friends).
    DU_FILE="$(mktemp)"
    trap 'rm -f "$DU_FILE"' EXIT
    # The smallest entry worth recording: the floor for the deeper directories in the
    # python below, and for the files directly under / that are added to the list
    MIN_ENTRY_MIB=100
    sudo du -x --max-depth=3 -B1 / 2>/dev/null > "$DU_FILE"
    if [ ! -s "$DU_FILE" ]; then
      echo "du failed, skipping the record" >&2
      exit 1
    fi
    # du lists directories only, so a file directly under / would count in the root total
    # and in no entry. That is where scripts/setup-swap.sh puts the swapfile (and the
    # half-written /swapfile.tmp, when a run was killed outright), and where a stray dump
    # or disk image tends to land. Add every file there over MIN_ENTRY_MIB in du's own
    # format, after the check above so it cannot make a failed du look like a result.
    # The smallest swapfile is 1 GiB, far over the floor, and a leftover temporary file
    # shows up once it is big enough to matter; the small files that live at the root
    # (/.autorelabel and the like) say nothing about growth and stay out.
    sudo find / -xdev -maxdepth 1 -type f -size +"${MIN_ENTRY_MIB}M" \
      -exec du -B1 {} + 2>/dev/null >> "$DU_FILE"

    sync_prepare
    python3 - "$SYNC_STATE_DIR/disk-usage.json.tmp" "$DU_FILE" "$MIN_ENTRY_MIB" <<'PY' || exit 1
import datetime, json, sys

dest, du_file = sys.argv[1], sys.argv[2]
# Below the second level keep only the big entries (/var/lib/docker is worth seeing, the
# small branches are not). The first level (/var, /home, ...) is kept regardless of size,
# because it is the entry point on screen.
MIN_DEEP_BYTES = int(sys.argv[3]) * 1024 * 1024

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
        # The console already records the root total from df, so leave it out.
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

with open(dest, "w", encoding="utf-8") as f:
    json.dump({
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "scope": "/",
        "entries": entries,
    }, f)
print(f"Recorded disk usage per directory and of large files directly under / ({len(entries)} entries)")
PY
    sync_commit_state disk-usage.json
    ;;
  bans-sync)
    # CrowdSec lives inside a container, so write its state out as a snapshot the console
    # can read, then carry out the IP operations the console has queued in sync/ops. One
    # invocation covers writing the state, executing and reporting the result back.
    #
    # The JSON shape is a stable contract with the console. It dates from a fail2ban-era
    # implementation: what used to be a "jail" is a CrowdSec scenario name
    # such as crowdsecurity/http-probing.
    #
    # Without CrowdSec (origin-ca, or EDGE_CROWDSEC=off) nothing blocks here, so no
    # snapshot is published and the previous one is removed: a host with no blocking
    # state looks exactly like a host that has never run CrowdSec, rather than showing a
    # stale list or an empty one that reads as "protected, nothing caught". Requests the
    # console has already queued are answered with an error, so they do not sit in
    # sync/ops for ever.
    if ! crowdsec_enabled; then
      OFF_REQ_FILE="$(mktemp)"
      trap 'rm -f "$OFF_REQ_FILE"' EXIT
      sync_prepare
      rm -f "$SYNC_STATE_DIR/bans.json"
      sync_pending_ops ban ip note > "$OFF_REQ_FILE"
      while IFS=$'\t' read -r id action ip note; do
        [ -n "$id" ] || continue
        sync_write_op_result "$id" "CrowdSec does not run on this host ($(crowdsec_off_reason))"
        echo "rejected: $action $ip (CrowdSec is off on this host)" >&2
      done < "$OFF_REQ_FILE"
      echo "CrowdSec does not run on this host ($(crowdsec_off_reason)): no blocking state published"
      exit 0
    fi

    DEC_FILE="$(mktemp)"; REQ_FILE="$(mktemp)"; ALLOW_FILE="$(mktemp)"; ALL_FILE="$(mktemp)"
    trap 'rm -f "$DEC_FILE" "$REQ_FILE" "$ALLOW_FILE" "$ALL_FILE"' EXIT

    # Fetch the active decisions as JSON.
    # Leave an empty file when there is nothing, so python can tell it apart from a failed
    # query.
    # The second call includes community-blocklist decisions (-a). They go into the
    # snapshot as a single count: thousands of externally sourced IPs would drown the
    # console's own records, and their churn carries no per-IP story worth keeping.
    collect_decisions() {
      cscli decisions list -o json > "$DEC_FILE" 2>/dev/null || : > "$DEC_FILE"
      cscli decisions list -a -o json > "$ALL_FILE" 2>/dev/null || : > "$ALL_FILE"
    }

    # Publish the allowlist too, so it can be inspected and edited from the console.
    # The source of truth is crowdsec/generated/allowlist.tsv (one line = IP<TAB>note).
    collect_allowed() {
      cat "$ROOT_DIR/crowdsec/generated/allowlist.tsv" > "$ALLOW_FILE" 2>/dev/null || : > "$ALLOW_FILE"
    }

    # Snapshot of the current blocking state. Operation results are not part of it; they
    # are written next to the request in sync/ops.
    write_bans() {
      python3 - "$SYNC_STATE_DIR/bans.json.tmp" "$DEC_FILE" "$ALLOW_FILE" "$SCRIPT_DIR" "$ALL_FILE" <<'PY'
import datetime, json, sys

dest, dec_file, allow_file, script_dir, all_file = sys.argv[1:6]
sys.path.insert(0, script_dir)
from crowdsec_json import banned_at, community_count, expires_at, iter_decisions, load

decisions = load(dec_file)
if decisions is None:
    print("Could not query CrowdSec, keeping the previous snapshot", file=sys.stderr)
    sys.exit(1)

# None (query failed) is different from zero: only write the field when it is countable,
# so the console keeps its last known figure instead of dropping to 0.
all_decisions = load(all_file)

# Group by scenario. One group corresponds to one fail2ban jail.
jails = {}
for alert, decision in iter_decisions(decisions):
    scenario = (decision.get("scenario") or alert.get("scenario") or "manual")[:50]
    jail = jails.setdefault(scenario, {
        "name": scenario,
        "currentlyBanned": 0,
        # CrowdSec has no counter equivalent to "total since install".
        # The console's ban_records holds the long-term total, so write the current count.
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

payload = {
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "jails": jails,
    "allowed": allowed,
}
if all_decisions is not None:
    payload["community"] = {"count": community_count(all_decisions)}
with open(dest, "w", encoding="utf-8") as f:
    json.dump(payload, f)

print(f"Wrote blocking state ({len(jails)} scenarios, {len(allowed)} allowlisted)")
PY
    }

    sync_prepare
    collect_decisions
    collect_allowed
    write_bans || exit 1
    sync_commit_state bans.json

    # Operations queued by the console. ban.sh does the work, so make ban and the console
    # go through the same path. Afterwards the state has changed, so write it again.
    sync_pending_ops ban ip note > "$REQ_FILE"
    if [ -s "$REQ_FILE" ]; then
      while IFS=$'\t' read -r id action ip note; do
        [ -n "$id" ] || continue
        if err="$("$SCRIPT_DIR/ban.sh" "$action" "$ip" "$note" 2>&1)"; then
          sync_write_op_result "$id" ""
          echo "ok: $action $ip"
        else
          sync_write_op_result "$id" "$(printf '%s' "$err" | tail -1 | cut -c1-300)"
          echo "failed: $action $ip: $err" >&2
        fi
      done < "$REQ_FILE"

      collect_decisions
      collect_allowed
      write_bans || exit 1
      sync_commit_state bans.json
    fi
    ;;
  timers)
    # Write the list of scheduled jobs for the console and run the operations it queued.
    # "Notify on failure" alone cannot tell you that a timer stopped running at all, so
    # publish whether it is alive, when it runs next and how the last run went.
    TASK_FILE="$(mktemp)"; TREQ_FILE="$(mktemp)"
    trap 'rm -f "$TASK_FILE" "$TREQ_FILE"' EXIT

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
    # and the like) are left out. logrotate is included even though the unit belongs to the
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

    write_tasks() {
      python3 - "$SYNC_STATE_DIR/timers.json.tmp" "$TASK_FILE" <<'PY'
import base64, datetime, json, sys

dest, task_file = sys.argv[1:3]

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

with open(dest, "w", encoding="utf-8") as f:
    json.dump({
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "tasks": tasks,
    }, f)

print(f"Wrote scheduled task state ({len(tasks)} tasks)")
PY
    }

    # Carrying out an operation. "run" does not wait for completion, because a job can take
    # minutes and this pass must not sit waiting for it.
    operate_unit() {
      local action="$1" unit="$2" svc

      # Operation requests arrive as files the console writes. The console restricts the
      # units it offers, but this effectively hands root systemctl to whoever can write
      # into sync/ops, so check here as well.
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

    sync_prepare
    collect_tasks
    write_tasks || exit 1
    sync_commit_state timers.json

    sync_pending_ops timer key > "$TREQ_FILE"
    if [ -s "$TREQ_FILE" ]; then
      while IFS=$'\t' read -r id action unit; do
        [ -n "$id" ] || continue
        if err="$(operate_unit "$action" "$unit" 2>&1)"; then
          sync_write_op_result "$id" ""
          echo "ok: $action $unit"
        else
          sync_write_op_result "$id" "$(printf '%s' "$err" | tail -1 | cut -c1-500)"
          echo "failed: $action $unit: $err" >&2
        fi
      done < "$TREQ_FILE"

      collect_tasks
      write_tasks || exit 1
      sync_commit_state timers.json
    fi
    ;;
  reboot-sync)
    # Write the pending-reboot state for the console and carry out the reboots scheduled
    # from its screens. The console runs in a container and cannot reboot the host; this is
    # the only place that can.
    REQ_FILE="$(mktemp)"
    trap 'rm -f "$REQ_FILE"' EXIT

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

    write_reboot() {
      python3 - "$SYNC_STATE_DIR/reboot.json.tmp" "$1" "$2" "$3" "$4" <<'PY'
import datetime, json, sys

dest, required, since, scheduled, booted = sys.argv[1:6]

with open(dest, "w", encoding="utf-8") as f:
    json.dump({
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "required": required == "1",
        "requiredSince": since or None,
        "scheduledFor": scheduled or None,
        "bootedAt": booted or None,
    }, f)

print("Wrote reboot state")
PY
    }

    # Leave the scheduling to systemd's shutdown; do not keep a process waiting
    operate_reboot() {
      local action="$1" at="$2" local_time
      case "$action" in
        schedule)
          [ -n "$at" ] || { echo "no scheduled time given" >&2; return 1; }
          # shutdown takes local time as hh:mm; the request carries UTC ISO 8601
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

    sync_prepare
    write_reboot "$required" "$since" "$(scheduled_at)" "$(booted_at)" || exit 1
    sync_commit_state reboot.json

    sync_pending_ops reboot scheduledFor > "$REQ_FILE"
    if [ -s "$REQ_FILE" ]; then
      while IFS=$'\t' read -r id action at; do
        [ -n "$id" ] || continue
        if err="$(operate_reboot "$action" "$at" 2>&1)"; then
          sync_write_op_result "$id" ""
          echo "ok: $action ${at:-now}"
        else
          sync_write_op_result "$id" "$(printf '%s' "$err" | tail -1 | cut -c1-300)"
          echo "failed: $action: $err" >&2
        fi
      done < "$REQ_FILE"

      write_reboot "$required" "$since" "$(scheduled_at)" "$(booted_at)" || exit 1
      sync_commit_state reboot.json
    fi
    ;;
  host-info)
    # Facts about the host itself that the console cannot work out from its own side.
    # Currently one: the FQDN the Traefik dashboard is published on, which lives in
    # DASHBOARD_HOST in .env and is empty on a host with no dashboard route.
    #
    # Written like every other snapshot: the whole file through a .tmp and a rename, so a
    # reader never sees half of one. Unchanged content is left alone instead of rewritten
    # with a new timestamp — the console skips a file whose generatedAt it has already
    # taken in, and rewriting it every five minutes would defeat that.
    #
    # Only the one key is read out of .env (same as scripts/mode-lib.sh): this runs as root
    # from a timer and has no business holding the LAPI key or the dashboard password.
    sync_prepare
    dashboard_host="$(sed -n 's/^DASHBOARD_HOST=//p' "$ROOT_DIR/.env" 2>/dev/null \
      | head -1 | tr -d "\"' ")"

    python3 - "$SYNC_STATE_DIR/host.json.tmp" "$SYNC_STATE_DIR/host.json" "$dashboard_host" <<'PY'
import datetime, json, sys

dest, current, raw = sys.argv[1:4]

# The contract is a bare host name: no scheme, no port, no path. .env is meant to hold
# exactly that, so this only trims what a hand-edited value may have picked up.
host = raw.strip()
if "//" in host:
    host = host.split("//", 1)[1]
host = host.split("/", 1)[0]
host = host.split(":", 1)[0]
dashboard = {"host": host} if host else None

# Same shape as before means nothing to publish: keep the file, and with it its
# generatedAt, exactly as it is.
try:
    with open(current, encoding="utf-8") as f:
        existing = json.load(f)
except (OSError, ValueError):
    existing = None
if isinstance(existing, dict) and existing.get("dashboard") == dashboard:
    print("Host facts unchanged")
    raise SystemExit(3)

with open(dest, "w", encoding="utf-8") as f:
    json.dump({
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "dashboard": dashboard,
    }, f)

print(f"Wrote host facts (dashboard: {host or 'none'})")
PY
    rc=$?
    if [ "$rc" -eq 0 ]; then
      sync_commit_state host.json
    elif [ "$rc" -ne 3 ]; then
      echo "Could not write the host facts" >&2
      exit 1
    fi
    ;;
  host-sync)
    # The periodic pass over the file channel: refresh every state snapshot and run
    # whatever the console has queued. If one part fails, the rest still run.
    rc=0
    "$0" bans-sync || rc=1
    "$0" timers || rc=1
    "$0" reboot-sync || rc=1
    "$0" host-info || rc=1
    # Events are the only thing that accumulates. Nothing else prunes them on a host with
    # no console, so drop them here after two weeks.
    sync_prune_events 14
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
    echo "usage: report.sh {os|bans|disk-usage|bans-sync|timers|reboot-sync|host-info|host-sync|reboot-check}" >&2
    exit 2
    ;;
esac
