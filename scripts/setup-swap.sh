#!/bin/bash
# Create a swapfile and apply the kernel's swap tuning (safe to run any number of times)
#
# The rules this script carries out and the reasons for them (the size, the disk limit,
# when no swapfile is made, what happens to a /swapfile or an installed file changed by
# hand, why its failure does not stop host-apply) are under "Swap" in the README. The
# comments here only cover how the steps below carry them out.
#
# Run by host-apply.sh, whose lock keeps two runs apart (see there). Run on its own,
# nothing keeps a second run from starting beside it.
#
# Steps:
#   1. Turn /swapfile on, creating it first when there is none, the host has no other
#      active swap and the disk has room. A /swapfile that was removed while it was on is
#      left alone until the host reboots, with a warning to the ops console.
#   2. With /swapfile on: install systemd/swapfile.swap and sysctl/99-zz-swap.conf, enable
#      the unit and load the tuning. Done on every run that gets this far, so a change to
#      either file reaches the host through make host-apply. With no /swapfile: take both
#      out again, the unit only when it is the same as systemd/swapfile.swap. A symlink in
#      place of either file is left alone.
#   3. Warn about a line in /etc/fstab that makes swap.target require the swapfile. The
#      line is left as it is.
# A /swapfile that is there but is not a regular file holding a swap area stops the script
# before step 1, with nothing changed.
#
# Usage: ./setup-swap.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

SWAPFILE=/swapfile
SWAPFILE_TMP="$SWAPFILE.tmp"
# systemd/swapfile.swap. Its name is SWAPFILE escaped the way systemd names swap units, so
# the two change together.
SWAP_UNIT=swapfile.swap
SYSCTL_FILE=99-zz-swap.conf
UNIT_PATH="/etc/systemd/system/$SWAP_UNIT"
SYSCTL_PATH="/etc/sysctl.d/$SYSCTL_FILE"
# The bounds of the size, and how much of the root filesystem the swapfile may leave used
MIN_MIB=1024
MAX_MIB=4096
MAX_USED_PERCENT=75

# A /swapfile that is there must be a regular file holding a swap area, the way mkswap
# writes it. Anything else is nothing this script made, and the steps below would damage
# it: mv would put a new swapfile inside a directory, chown and chmod would follow a
# symlink to whatever it points at, and any other file would be taken from its owner
# before swapon refused it. Stop before anything is changed; host-apply turns the failure
# into a warning.
if [ -L "$SWAPFILE" ] || { [ -e "$SWAPFILE" ] && [ ! -f "$SWAPFILE" ]; }; then
  echo "$SWAPFILE exists but is not a regular file; nothing was changed." >&2
  echo "Move it out of the way, then run: make host-apply" >&2
  exit 1
fi
# blkid -p reads the type from the file's own content (the signature mkswap writes), not
# from the blkid cache, and prints nothing when it recognises none. It is part of
# util-linux, the package swapon and mkswap come from. A /swapfile that is on already
# passes as well: the signature stays in the file while the kernel uses it.
if [ -f "$SWAPFILE" ]; then
  swapfile_type="$(sudo blkid -p -s TYPE -o value "$SWAPFILE" || true)"
  if [ "$swapfile_type" != swap ]; then
    echo "$SWAPFILE exists but is not a swap area (blkid -p reports type: ${swapfile_type:-none}); nothing was changed." >&2
    echo "Check what it is and move it out of the way, then run: make host-apply" >&2
    exit 1
  fi
fi

# Active swap areas, one path per line. Read straight from /proc/swaps rather than through
# swapon --show: a read that fails stops the script (set -e, the result is always assigned
# to a variable first) instead of passing for "no swap" and creating a second swap area
# next to the one already running.
active_swaps() {
  awk 'NR > 1 { print $1 }' /proc/swaps
}

# Ownership and mode as the create branch below gives them, for a /swapfile that is on
# already as much as for one about to be turned on: swapon only warns about a swapfile
# other users can read and uses it anyway, and swapped-out memory can hold anything a
# process had in it (keys, passwords, session data). The checks at the top have made sure
# it is a regular file holding a swap area, not a symlink these would follow.
restrict_swapfile() {
  sudo chown root:root "$SWAPFILE"
  sudo chmod 600 "$SWAPFILE"
}

# Say what a symlink at $1 is, for a file of edge's that this script then leaves alone. A
# link to /dev/null is a mask: systemctl mask turns a unit off with one, and the same link
# masks a sysctl.d file. $2, when given, is the command that takes the mask away. Any other
# link stands in for edge's file, and at boot systemd reads the file it points to.
describe_link() {
  local dest="$1" unmask="${2:-}"
  if [ "$(readlink -f "$dest")" = /dev/null ]; then
    echo "  $dest is masked (a symlink to /dev/null): left as it is"
    if [ -n "$unmask" ]; then
      echo "  To hand it back to edge: $unmask, then make host-apply"
    fi
  else
    echo "  $dest has been replaced by a link to another file ($(readlink "$dest")): left as it is. At boot systemd reads the file it points to."
  fi
}

# Put one of this repo's files in place under /etc, owned by root with mode 644, and say
# what happened. Returns 0 when edge's file is in place, so the caller goes on to enable or
# load it; placed is then installed, or unchanged when the same content, owner and mode
# were there already and nothing was written. Returns 1 when a symlink stands in its
# place, which is left alone: cp would write through it, chmod would change the file it
# points to, and install would replace it and undo a mask without a word. $3 is the
# command that takes a mask away. A directory or anything else that is not a regular file
# stops the script, with nothing written to it.
# Called as an if condition, where set -e does not apply inside it, hence the explicit
# exits.
place_file() {
  local src="$1" dest="$2" unmask="$3"
  if [ -L "$dest" ]; then
    describe_link "$dest" "$unmask"
    return 1
  fi
  if [ -e "$dest" ] && [ ! -f "$dest" ]; then
    echo "$dest exists but is not a regular file; nothing was written to it." >&2
    echo "Move it out of the way, then run: make host-apply" >&2
    exit 1
  fi
  if [ -f "$dest" ] && cmp -s "$src" "$dest" \
    && [ "$(stat -c '%U:%G %a' "$dest")" = "root:root 644" ]; then
    placed=unchanged
    echo "  Unchanged"
  else
    # -T: dest is the file itself, never a directory to put src into
    sudo install -T -m 644 -o root -g root "$src" "$dest" || exit 1
    placed=installed
    echo "  Installed"
  fi
}

# ---- 1. The swapfile ---------------------------------------------------------
# Every branch ends in one of these states, which step 2 and the closing line go by, or
# stops the script:
#   active      /swapfile is on
#   missing     there is no /swapfile, because the host has other active swap
#   disk_short  there is no /swapfile, because not even the smallest one fits on the disk
#   deleted     /swapfile was removed while it was on, and the kernel still uses it

# Left behind by a run that was killed outright (kill -9, a power cut), which the trap in
# the create branch cannot catch. Removed first, whichever branch follows, so it neither
# stays on the disk nor counts against the free space measured there. host-apply's lock
# makes sure it is not a file another run is still writing (see there for the one case
# the lock does not cover).
if [ -e "$SWAPFILE_TMP" ] || [ -L "$SWAPFILE_TMP" ]; then
  sudo rm -f "$SWAPFILE_TMP"
  echo "Removed $SWAPFILE_TMP, left behind by a run that was killed outright"
fi

active="$(active_swaps)"
if grep -qxF "$SWAPFILE" <<<"$active"; then
  echo "$SWAPFILE is already active swap"
  restrict_swapfile
  swapfile_state=active
elif grep -qxF "$SWAPFILE\\040(deleted)" <<<"$active"; then
  # /proc/swaps writes a space in a path as \040, and the kernel adds " (deleted)" to a
  # swapfile removed while on. Taken for other active swap, it would have step 2 take the
  # unit and the tuning away from swap that is still running.
  if [ -f "$SWAPFILE" ]; then
    # Put in place after the old one was removed. The check at the top has found a swap
    # area in it; it is not turned on beside the deleted one.
    after_reboot="The $SWAPFILE there now is a new file and stays off. After the next reboot, run: make host-apply (it turns that file on, unless $SWAP_UNIT already has at boot)"
  else
    after_reboot="After the next reboot, run: make host-apply (it creates a new $SWAPFILE when the disk has room and the host has no other active swap)"
  fi
  # A warning rather than only output on the terminal: unless a new /swapfile is in place
  # by then, the host comes back from that reboot with no swapfile until someone runs
  # make host-apply, and nothing else would say so. Not an exit, and the script still
  # succeeds, as for disk_short below: nothing can be fixed before the reboot, and the
  # warning says what to do after it. notify.sh prints the title and the body here as
  # well.
  "$SCRIPT_DIR/notify.sh" --warn "Swap: $SWAPFILE was removed while it was still on" <<EOF || true
The kernel keeps using the deleted file, and the disk space it takes, until the host reboots: swapoff finds a swap area by its path, which is gone.
The unit and the swappiness setting are left as they are.
$after_reboot
EOF
  swapfile_state=deleted
elif [ -f "$SWAPFILE" ]; then
  # Holds a swap area (checked at the top), so one that is not active was turned off by
  # hand or did not come on at boot
  echo "Turning the existing $SWAPFILE on..."
  restrict_swapfile
  if ! sudo swapon "$SWAPFILE"; then
    echo "$SWAPFILE exists but cannot be used as swap; remove it and run this again" >&2
    exit 1
  fi
  swapfile_state=active
elif [ -n "$active" ]; then
  echo "Other swap is already active; $SWAPFILE is not created"
  swapfile_state=missing
else
  # The host's memory rounded up to a whole GiB, kept between MIN_MIB and MAX_MIB
  mem_kib="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
  mem_mib=$(( mem_kib / 1024 ))
  size_mib=$(( (mem_kib + 1048575) / 1048576 * 1024 ))
  if [ "$size_mib" -lt "$MIN_MIB" ]; then
    size_mib=$MIN_MIB
  fi
  if [ "$size_mib" -gt "$MAX_MIB" ]; then
    size_mib=$MAX_MIB
  fi
  full_mib=$size_mib

  fs_dir="$(dirname "$SWAPFILE")"
  # One df for both figures, assigned first so a failed read stops the script (set -e)
  df_out="$(df -BM --output=size,avail "$fs_dir" | tail -1 | tr -d 'M')"
  read -r total_mib avail_mib <<<"$df_out"
  # Everything not available counts as used. room_mib is what the swapfile may take and
  # still leave the filesystem at most MAX_USED_PERCENT used; below zero when the disk is
  # already past that.
  used_mib=$(( total_mib - avail_mib ))
  room_mib=$(( total_mib * MAX_USED_PERCENT / 100 - used_mib ))
  if [ "$room_mib" -lt "$size_mib" ]; then
    # The largest whole GiB that fits; zero or below when not even 1 GiB does
    size_mib=$(( room_mib / 1024 * 1024 ))
  fi

  if [ "$size_mib" -lt "$MIN_MIB" ]; then
    min_used_percent=$(( ((used_mib + MIN_MIB) * 100 + total_mib - 1) / total_mib ))
    "$SCRIPT_DIR/notify.sh" --warn "Swap not created: not enough free disk space" <<EOF || true
Even the smallest swapfile (${MIN_MIB} MiB) would leave $fs_dir ${min_used_percent}% used, above the ${MAX_USED_PERCENT}% limit (the ops console warns about the disk at 80%). This host's memory calls for ${full_mib} MiB.
Free: ${avail_mib} MiB of ${total_mib} MiB.
Free up space or grow the root volume (and its filesystem), then run: make host-apply
That run creates the swapfile and keeps the disk busy while it does; "Swap" in the edge README says when to run it.
EOF
    # Not an exit, and the script still succeeds: step 2 below has to take out what an
    # earlier swapfile left behind, and the warning already says what to do
    swapfile_state=disk_short
  else
    if [ "$size_mib" -lt "$full_mib" ]; then
      echo "Not enough free disk space for ${full_mib} MiB (this host's memory): $fs_dir has ${avail_mib} MiB free of ${total_mib} MiB"
      echo "Creating ${size_mib} MiB instead, the most that leaves it at most ${MAX_USED_PERCENT}% used. It keeps that size until it is recreated (see \"Swap\" in the README)."
    fi

    # Until the file is moved into place, a failed step (set -e) or an interruption
    # (Ctrl-C, a dropped SSM session) removes the half-made file instead of leaving it on
    # the disk. The signal traps turn an interruption into an ordinary exit, so the EXIT
    # trap runs for those as well.
    trap 'sudo rm -f "$SWAPFILE_TMP"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    echo "Creating $SWAPFILE (${size_mib} MiB, memory ${mem_mib} MiB)..."
    # dd rather than fallocate: swapon(8) names dd from /dev/zero as the most portable way
    # to make a swapfile, because depending on the filesystem and kernel a preallocated
    # file can be refused as having holes. The root filesystem on Amazon Linux 2023 is
    # XFS; writing every block takes the question off the table.
    # oflag=direct writes past the page cache: otherwise the gigabytes of zeros would go
    # through it and push out what the running services have cached. It does not spare
    # the disk (see "Swap" in the README).
    # Written under a temporary name and moved into place once it is a complete swap
    # area, so an interrupted run never leaves a half-written /swapfile for the next run
    # to trust.
    sudo dd if=/dev/zero of="$SWAPFILE_TMP" bs=1M count="$size_mib" oflag=direct status=none
    sudo chmod 600 "$SWAPFILE_TMP"
    sudo mkswap "$SWAPFILE_TMP" >/dev/null
    sudo mv "$SWAPFILE_TMP" "$SWAPFILE"
    trap - EXIT INT TERM HUP

    # SELinux label: with SELinux enabled, mkswap gives a regular file the swapfile_t
    # label, and mv within the same filesystem keeps it, so /swapfile arrives already
    # labelled. restorecon is deliberately not run: it would replace that label with
    # whatever the policy assigns to the path, which need not be swapfile_t. Amazon Linux
    # 2023 runs SELinux in permissive mode by default, where a label never refuses swapon
    # anyway.
    sudo swapon "$SWAPFILE"
    swapfile_state=active
  fi
fi

# ---- 2. Boot unit and tuning -------------------------------------------------
case "$swapfile_state" in
  active)
    echo ""
    echo "Installing the swap unit ($UNIT_PATH)..."
    if place_file "$ROOT_DIR/systemd/$SWAP_UNIT" "$UNIT_PATH" "sudo systemctl unmask $SWAP_UNIT"; then
      if [ "$placed" = installed ]; then
        sudo systemctl daemon-reload
      fi
      # Enable only: step 1 has already turned the swapfile on
      sudo systemctl enable "$SWAP_UNIT"
    fi

    echo ""
    echo "Installing the sysctl config ($SYSCTL_PATH)..."
    if place_file "$ROOT_DIR/sysctl/$SYSCTL_FILE" "$SYSCTL_PATH" "sudo rm $SYSCTL_PATH"; then
      # Loaded on every run, so a value changed by hand goes back to the file's. Only this
      # one file: sysctl --system would re-apply every file under /etc/sysctl.d and
      # /usr/lib/sysctl.d to the running kernel, network settings included, on a host that
      # is serving traffic. At boot systemd-sysctl reads it together with the rest.
      sudo sysctl -q -p "$SYSCTL_PATH"
      echo "  vm.swappiness = $(sysctl -n vm.swappiness)"
    fi
    ;;
  missing|disk_short)
    echo ""
    echo "$SWAPFILE does not exist"
    # The unit goes too, though with ConditionPathExists it would only be skipped at boot:
    # on a host with other active swap nothing creates /swapfile again, so it would stay
    # there with nothing to do. ConditionPathExists covers the time between the file going
    # and this run.
    # Only a unit with the same content as this repo's is taken for edge's and removed.
    # Anything else at the path (written or edited by hand, installed from an earlier
    # version of the file, or not a regular file) is left as it is, and so is a unit cmp
    # cannot compare (cmp missing: 127; a file it cannot read: 2): removing it would need
    # a certainty this run does not have.
    if [ -L "$UNIT_PATH" ]; then
      describe_link "$UNIT_PATH"
    elif [ -e "$UNIT_PATH" ]; then
      unit_cmp=0
      cmp -s "$ROOT_DIR/systemd/$SWAP_UNIT" "$UNIT_PATH" || unit_cmp=$?
      case "$unit_cmp" in
        0)
          sudo systemctl disable "$SWAP_UNIT"
          sudo rm -f "$UNIT_PATH"
          sudo systemctl daemon-reload
          echo "  Removed $UNIT_PATH"
          ;;
        1)
          echo "  $UNIT_PATH differs from systemd/$SWAP_UNIT in this repo: left as it is"
          ;;
        *)
          echo "  $UNIT_PATH could not be compared with systemd/$SWAP_UNIT (cmp exited with status $unit_cmp): left as it is"
          ;;
      esac
      if [ "$unit_cmp" -ne 0 ]; then
        echo "  If it is not needed, take it out by hand: sudo systemctl disable $SWAP_UNIT, sudo rm $UNIT_PATH, sudo systemctl daemon-reload"
      fi
    fi
    if [ -L "$SYSCTL_PATH" ]; then
      describe_link "$SYSCTL_PATH"
    elif [ -e "$SYSCTL_PATH" ]; then
      sudo rm -f "$SYSCTL_PATH"
      # The running value is left as it is: what it was before this script set it is not
      # recorded, writing the kernel default (60) could override what another sysctl file
      # sets, and reading every file again (sysctl --system) is ruled out for the reason
      # given above. What that means with and without other swap: "Swap" in the README.
      echo "  Removed $SYSCTL_PATH"
      echo "  vm.swappiness stays at $(sysctl -n vm.swappiness) until the next boot, then takes the value the remaining sysctl files set, or the kernel default when none of them sets it"
    fi
    ;;
  deleted)
    # Step 1 has said what to do. The unit and the tuning stay for the swap that is still
    # running; at the next boot the unit is skipped (ConditionPathExists) unless a new
    # /swapfile is in place by then.
    ;;
esac

# ---- 3. /etc/fstab -----------------------------------------------------------
# A line there for /swapfile is not edge's and is left as it is. edge's unit takes
# precedence over the one systemd-fstab-generator makes from the line, but the generator
# still links the unit into swap.target.requires, unless the line has nofail or noauto,
# and that makes it required however edge installed it.
if [ -f /etc/fstab ] && awk -v path="$SWAPFILE" '
    $1 == path && $3 == "swap" {
      required = 1
      n = split($4, opts, ",")
      for (i = 1; i <= n; i++) {
        if (opts[i] == "nofail" || opts[i] == "noauto") required = 0
      }
      if (required) found = 1
    }
    END { exit !found }' /etc/fstab; then
  echo ""
  echo "Warning: /etc/fstab has a line for $SWAPFILE; it is left as it is."
  echo "From that line systemd makes $SWAP_UNIT a requirement of swap.target, so whenever $SWAPFILE cannot be turned on at boot, swap.target fails along with it. Removing the line makes the swap optional again (see \"Swap\" in the README)."
fi

echo ""
echo "Current swap:"
swapon --show || true
free -m || true

echo ""
case "$swapfile_state" in
  disk_short) echo "Swap setup skipped (not enough free disk space)" ;;
  deleted) echo "Swap setup skipped ($SWAPFILE was removed while it was on; see above)" ;;
  *) echo "Swap setup complete" ;;
esac
