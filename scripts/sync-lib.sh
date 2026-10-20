# The file channel between this host and the ops console. Sourced by notify.sh and
# report.sh (not executable on its own); the caller must set ROOT_DIR first.
#
# edge never calls the console. It writes everything under sync/ and the console — a
# container on the same host that mounts this directory — reads it when it wants to.
# A host with no console keeps writing exactly the same files; nobody reads them, and
# that is the whole difference.
#
#   sync/state/                     written here, mounted read-only by the console
#     events/YYYY-MM-DD.ndjson      one notification per line, appended (pruned after 14 days)
#     bans.json timers.json reboot.json disk-usage.json host.json metrics.json
#                                   full snapshots, rewritten on every run (host.json only
#                                   when its content changed, so its generatedAt stays put)
#   sync/ops/                       the console writes req-<id>.json, this side answers
#                                   with res-<id>.json; the console deletes both once it
#                                   has taken the result in
#
# Snapshots are written to <name>.tmp and moved into place, so a reader never sees half a
# file. Events are appended instead, because the console tails them with a cursor of its
# own.

SYNC_DIR="$ROOT_DIR/sync"
SYNC_STATE_DIR="$SYNC_DIR/state"
SYNC_EVENTS_DIR="$SYNC_STATE_DIR/events"
SYNC_OPS_DIR="$SYNC_DIR/ops"

# Create the channel. Called before every write, because sync/ is untracked host state and
# does not exist in a fresh clone.
# ops/ is world writable because the console container writes its requests there as a
# different user. The trust model is unchanged: anyone with an account on this host.
sync_prepare() {
  mkdir -p "$SYNC_EVENTS_DIR" "$SYNC_OPS_DIR" 2>/dev/null || true
  chmod 755 "$SYNC_DIR" "$SYNC_STATE_DIR" "$SYNC_EVENTS_DIR" 2>/dev/null || true
  chmod 777 "$SYNC_OPS_DIR" 2>/dev/null || true
}

# The systemd timers run as root while make bans and friends run as the deploy user, and
# both append to the same event file. A root run must therefore not leave root-owned files
# behind, or the next non-root run cannot open them. Same idea as fix_ownership in
# render-config.sh. ops/ needs nothing: it is 777 and its files are 666.
sync_fix_ownership() {
  [ "$(id -u)" = 0 ] || return 0
  chown --reference="$ROOT_DIR" "$SYNC_DIR" 2>/dev/null || true
  chown -R --reference="$ROOT_DIR" "$SYNC_STATE_DIR" 2>/dev/null || true
}

# Move a snapshot written as sync/state/<name>.tmp into place. $1 = file name.
sync_commit_state() {
  local dest="$SYNC_STATE_DIR/$1"
  chmod 644 "$dest.tmp" 2>/dev/null || true
  mv "$dest.tmp" "$dest" || return 1
  sync_fix_ownership
}

# Append one notification to today's event file.
#   $1=level (info|warning|error)  $2=title  $3=body  $4="routine" or empty
# The body is passed as an argument, not on stdin: stdin carries the python program.
sync_append_event() {
  sync_prepare
  python3 - "$SYNC_EVENTS_DIR" "$1" "$2" "$3" "${4:-}" <<'PY'
import datetime, json, os, sys

events_dir, level, title, body, routine = sys.argv[1:6]
now = datetime.datetime.now(datetime.timezone.utc)
path = os.path.join(events_dir, now.strftime("%Y-%m-%d") + ".ndjson")
line = json.dumps({
    "ts": now.isoformat(),
    "source": "host",
    "level": level,
    "title": title[:200],
    "body": body[:10000] or None,
    "routine": routine == "routine",
})
# Append in one write. The reader tolerates a trailing partial line, so a race with a
# concurrent writer costs nothing worse than reading that line one run later.
try:
    with open(path, "a", encoding="utf-8") as f:
        f.write(line + "\n")
except OSError as e:
    print(f"Could not record the event for the ops console: {e}", file=sys.stderr)
    raise SystemExit(1)
try:
    os.chmod(path, 0o644)
except OSError:
    pass
print(f"Recorded for the ops console ({os.path.basename(path)})")
PY
  sync_fix_ownership
}

# List the operation requests of one kind that have no result yet, as TSV.
#   $1=kind (ban|timer|reboot)  $2.. = request fields to put in the columns after the id
# Output columns: id<TAB>action<TAB><field>...  The id is the one in the file name, so the
# result always lands where the console looks for it.
sync_pending_ops() {
  sync_prepare
  python3 - "$SYNC_OPS_DIR" "$@" <<'PY'
import glob, json, os, sys

ops_dir, kind, fields = sys.argv[1], sys.argv[2], sys.argv[3:]
for path in sorted(glob.glob(os.path.join(ops_dir, "req-*.json"))):
    op_id = os.path.basename(path)[len("req-"):-len(".json")]
    if not op_id:
        continue
    # A request with a result is done. The console removes both files once it has taken
    # the result in, so this is what stops an operation from running twice.
    if os.path.exists(os.path.join(ops_dir, f"res-{op_id}.json")):
        continue
    try:
        with open(path, encoding="utf-8") as f:
            req = json.load(f)
    except (OSError, ValueError):
        # Half written, or not a request at all. The next run picks it up.
        continue
    if not isinstance(req, dict) or (req.get("kind") or "") != kind:
        continue

    def col(name):
        return str(req.get(name) or "").replace("\t", " ").replace("\n", " ")

    print("\t".join([op_id, col("action")] + [col(f) for f in fields]))
PY
}

# Record the outcome of one operation. $1=id (as it appears in the file name),
# $2=error text ("" means success).
sync_write_op_result() {
  python3 - "$SYNC_OPS_DIR" "$1" "$2" <<'PY'
import datetime, json, os, sys

ops_dir, op_id, error = sys.argv[1:4]
# Echo back the id exactly as the request carried it (the console may use a number),
# falling back to the one in the file name.
value = op_id
try:
    with open(os.path.join(ops_dir, f"req-{op_id}.json"), encoding="utf-8") as f:
        raw = json.load(f).get("id")
    if raw is not None:
        value = raw
except (OSError, ValueError):
    pass

dest = os.path.join(ops_dir, f"res-{op_id}.json")
with open(dest + ".tmp", "w", encoding="utf-8") as f:
    json.dump({
        "id": value,
        "error": error or None,
        "finishedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }, f)
# 666: the console deletes this file as its own user
try:
    os.chmod(dest + ".tmp", 0o666)
except OSError:
    pass
os.replace(dest + ".tmp", dest)
PY
}

# Drop event files older than the retention window, so a host nobody reads does not grow
# without limit. $1 = days (default 14).
sync_prune_events() {
  find "$SYNC_EVENTS_DIR" -maxdepth 1 -type f -name '*.ndjson' -mtime "+${1:-14}" -delete 2>/dev/null || true
}
