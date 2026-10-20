#!/bin/bash
# Apply the host-side configuration (safe to run any number of times)
#
# Installs this repo's config files under /etc, enables the systemd timers and creates the
# swapfile. `make update` only follows git and applies compose, so changes under /etc
# and to systemd units, and steps added to this list, need this run by hand.
#
# One run at a time: a second run waits for the first, up to LOCK_WAIT_SECONDS, and then
# fails without changing anything (see the lock below).
#
# setup-swap comes first, so the swapfile is in place before setup-auto-patch installs
# dnf-automatic. It is the one step whose failure does not stop the run: the failure goes
# to the ops console as a warning, the other steps are applied, and host-apply still
# finishes successfully. An interruption still stops the run, as at any other step.
# Creating the swapfile keeps the disk busy. "Swap" in the README gives the reasons and
# says when to run this.
#
# The host-sync run at the end does not fail host-apply either (see there).
#
# setup-update (the auto-follow timer) is only installed, never enabled. Hosts that should
# follow automatically enable it as described in the README.
#
# Usage: ./host-apply.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

LOCK_FILE=/run/edge-host-apply.lock
# How long a second run waits for the first. A normal run takes a few minutes at most: its
# longest steps are the swapfile write (up to 4 GiB, tens of seconds) and the dnf install
# in setup-auto-patch, which downloads the repository metadata. Ten minutes is several
# times that. A run that holds the lock longer is stuck or waiting on something outside
# it, which someone should look at rather than have a second run queue behind it with no
# end.
LOCK_WAIT_SECONDS=600

# One run at a time, over every step. Two runs side by side would trip over each other:
# setup-swap's cleanup removes the /swapfile.tmp the other run is still writing, and the
# steps rewrite the same files under /etc and reload systemd in the middle of each other.
# The lock file is created as root (/run is root's) and opened read-only, which is all
# flock needs, so the script itself still runs as the deploy user. /run is emptied at
# boot. The steps inherit descriptor 9 and with it the lock, which is released once this
# script and every step it started have exited, however they exit.
# sudo closes every descriptor above 2 before it runs a command, so what a step runs
# through sudo (dd, dnf, systemctl) does not hold the lock itself; it is covered only
# because the step waits for it. When this script and its steps are killed outright
# (kill -9), the lock goes with them while a command they started through sudo can still
# be running, and a run started then is not kept apart from that command.
sudo touch "$LOCK_FILE"
sudo chmod 644 "$LOCK_FILE"
exec 9<"$LOCK_FILE"
# flock exits with 1 when someone else holds the lock: -n at once, -w once the wait is
# over. Any other status is flock itself failing (127: it is not installed; others: a
# usage or system error, with flock's own message above it), which no amount of waiting
# cures, so it stops the run with its status and is not reported as another run.
lock_status=0
flock -n 9 || lock_status=$?
if [ "$lock_status" -eq 1 ]; then
  echo "Another host-apply run is in progress; waiting up to $(( LOCK_WAIT_SECONDS / 60 )) minutes for it to finish..."
  lock_status=0
  flock -w "$LOCK_WAIT_SECONDS" 9 || lock_status=$?
  if [ "$lock_status" -eq 1 ]; then
    echo "The other host-apply run still holds the lock after $(( LOCK_WAIT_SECONDS / 60 )) minutes; nothing was changed." >&2
    echo "Check whether it is still running (pgrep -af host-apply), then run: make host-apply" >&2
    exit 1
  fi
fi
if [ "$lock_status" -ne 0 ]; then
  echo "flock failed with status $lock_status, so the lock on $LOCK_FILE could not be taken; nothing was changed." >&2
  echo "This is not another run holding the lock. Status 127 means flock is not installed (it comes with util-linux); for any other status see flock's message above. Fix it, then run: make host-apply" >&2
  exit "$lock_status"
fi

echo ""
echo "--------- setup-swap ---------"
swap_status=0
"$SCRIPT_DIR/setup-swap.sh" || swap_status=$?
case "$swap_status" in
  0) ;;
  129|130|143)
    # Interrupted (a dropped session, Ctrl-C, kill): stop here as at any other step
    # rather than report it as a failure. These are 128 + HUP, INT and TERM, the codes a
    # process killed by one of them exits with, and the ones setup-swap's traps use while
    # it writes the file.
    exit "$swap_status"
    ;;
  *)
    "$SCRIPT_DIR/notify.sh" --warn "Swap setup failed" <<EOF || true
scripts/setup-swap.sh exited with status $swap_status during make host-apply, which went on to the other steps without it.
The cause is in the output of that run (make host-apply, or make setup on a new host).
Fix it, then run: make host-apply
When that run creates the swapfile it keeps the disk busy; "Swap" in the edge README says when to run it.
EOF
    ;;
esac

for step in \
  setup-logs \
  setup-auto-patch \
  setup-bans \
  setup-docker-prune \
  setup-disk-usage \
  setup-certs \
  setup-host-sync \
  setup-update
do
  echo ""
  echo "--------- $step ---------"
  "$SCRIPT_DIR/$step.sh"
done

echo ""
echo "--------- Sync to the ops console ---------"
# A failure here does not fail host-apply: every step above is applied by now, and the
# sync is retried on its own. On a new host CrowdSec's LAPI may not answer yet, which fails
# the run, and host-sync.timer starts the service again about 5 minutes later, by which
# time it usually does. host-sync.service reports a failure itself through
# notify-failure@ (setup-host-sync above has installed it), so no second warning is sent
# from here.
sync_ok=1
if sudo systemctl start host-sync.service; then
  echo "Synced"
else
  sync_ok=0
  echo "Warning: host-sync.service failed; host-sync.timer runs it again in about 5 minutes. See: journalctl -u host-sync -n 30" >&2
fi

echo ""
if [ "$swap_status" -eq 0 ]; then
  echo "Host configuration applied"
else
  echo "Host configuration applied, except swap (see the setup-swap output and warning at the top)"
fi
if [ "$sync_ok" -eq 0 ]; then
  echo "The sync to the ops console failed; host-sync.timer retries it (see the warning above)"
fi
