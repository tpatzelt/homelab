#!/bin/bash
# popbook-snapshot — full-system rsync snapshot of popbook to lindus.
#
# Each run writes a dated, complete-looking tree under $DEST_ROOT. Files
# unchanged since the previous run become hardlinks into it (--link-dest),
# so only genuine deltas cost space. Old snapshots are deleted outright;
# hardlinked data is freed only when the last reference goes.
#
# Ownership/permissions/xattrs are preserved via rsync's --fake-super on the
# REMOTE side (the destination is owned by an unprivileged user). Any restore
# MUST also pass --fake-super or the metadata will not be reapplied.
#
# Env overrides:
#   FORCE=1   run even on battery / low charge

# shellcheck disable=SC2029  # $DEST_ROOT/$STAMP are deliberately expanded client-side: the
# destination paths are this script's to decide, and lindus has no matching variables.

set -uo pipefail

DEST_HOST="lindus-backup"           # defined in /root/.ssh/config (untracked)
DEST_ROOT="/mnt/storage/backups/popbook-system"
EXCLUDES="/etc/popbook-snapshot.excludes"
MANIFEST="/var/lib/popbook-snapshot"
DISK="/dev/nvme0n1"
KEEP=14
MIN_BATTERY=40

STAMP="$(date +%Y-%m-%dT%H%M)"

# Optional HEALTHCHECKS_URL
# shellcheck source=/dev/null
[ -r /etc/popbook-snapshot.env ] && . /etc/popbook-snapshot.env

hc() { # $1 = "" | /start | /fail ;  $2 = optional body
    [ -n "${HEALTHCHECKS_URL:-}" ] || return 0
    curl -fsS -m 10 --retry 3 --data-raw "${2:-}" "${HEALTHCHECKS_URL}${1}" >/dev/null || true
}

die() { echo "SNAPSHOT FAILED: $1" >&2; hc /fail "$1"; exit 1; }

# --- preflight ----------------------------------------------------------
# Resolve the target's address from the ssh config rather than hardcoding it,
# so this file carries no LAN address and stays in sync with /root/.ssh/config.
LAN_HOST="$(ssh -G "$DEST_HOST" 2>/dev/null | awk '/^hostname /{print $2; exit}')"
[ -n "$LAN_HOST" ] || die "could not resolve HostName for '$DEST_HOST' from ssh config"

# Not on the home LAN is a normal state for a laptop, not a failure: exit 0
# quietly so it produces no alert, and let the timer's Persistent=true catch
# up after the next boot.
if ! ping -c1 -W2 "$LAN_HOST" >/dev/null 2>&1; then
    echo "lindus unreachable — not on home LAN. Skipping."
    exit 0
fi

if [ -z "${FORCE:-}" ]; then
    on_ac="$(cat /sys/class/power_supply/AC0/online 2>/dev/null || echo 1)"
    cap="$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo 100)"
    if [ "$on_ac" != "1" ] && [ "$cap" -lt "$MIN_BATTERY" ]; then
        echo "On battery at ${cap}% (< ${MIN_BATTERY}%). Skipping; set FORCE=1 to override."
        exit 0
    fi
fi

ssh -o BatchMode=yes -o ConnectTimeout=10 "$DEST_HOST" true \
    || die "ssh to $DEST_HOST failed"

date
echo "Snapshot $STAMP -> $DEST_HOST:$DEST_ROOT"
hc /start

# --- manifest: the things a file copy alone cannot restore --------------
mkdir -p "$MANIFEST"
pacman -Qqe  > "$MANIFEST/pkglist-explicit.txt"  || die "pacman -Qqe failed"
pacman -Qqem > "$MANIFEST/pkglist-aur.txt"       || true
sfdisk -d "$DISK" > "$MANIFEST/partition-table.sfdisk" || die "sfdisk dump failed"
lsblk -f -o NAME,FSTYPE,LABEL,UUID,SIZE,MOUNTPOINTS > "$MANIFEST/lsblk.txt"
efibootmgr -v > "$MANIFEST/efibootmgr.txt" 2>/dev/null || true
systemctl list-unit-files --state=enabled > "$MANIFEST/systemd-enabled.txt"
cp -f /etc/fstab "$MANIFEST/fstab"
cp -f /boot/limine.conf "$MANIFEST/limine.conf" 2>/dev/null || true
git -C /home/tim/.local/share/omarchy rev-parse HEAD \
    > "$MANIFEST/omarchy-rev.txt" 2>/dev/null || true
git -C /home/tim/.local/share/omarchy status --porcelain \
    > "$MANIFEST/omarchy-dirty.txt" 2>/dev/null || true
echo "Manifest written to $MANIFEST"

# --- transfer -----------------------------------------------------------
# rsync exit 24 ("some files vanished before transfer") is expected on a live
# system and is not a failure.
RS=(-aAXHx --numeric-ids --stats --human-readable
    --rsync-path="rsync --fake-super"
    --exclude-from="$EXCLUDES")

echo "=== pass 1/2: root filesystem ==="
rsync "${RS[@]}" --link-dest="../latest" / "$DEST_HOST:$DEST_ROOT/$STAMP/"
rc=$?
[ $rc -eq 0 ] || [ $rc -eq 24 ] || die "rsync of / exited $rc"

# /boot is a separate vfat filesystem, so -x skipped it above. It is also the
# shared ESP: it carries Limine AND Windows' EFI/MICROSOFT. See RESTORE notes.
echo "=== pass 2/2: /boot (ESP) ==="
rsync "${RS[@]}" --link-dest="../../latest/boot" /boot/ "$DEST_HOST:$DEST_ROOT/$STAMP/boot/"
rc=$?
[ $rc -eq 0 ] || [ $rc -eq 24 ] || die "rsync of /boot exited $rc"

# --- verify, publish, prune --------------------------------------------
ssh "$DEST_HOST" "test -f '$DEST_ROOT/$STAMP/etc/fstab' && test -d '$DEST_ROOT/$STAMP/boot/EFI'" \
    || die "snapshot $STAMP looks incomplete on the destination"

ssh "$DEST_HOST" "cd '$DEST_ROOT' && ln -sfn '$STAMP' latest" \
    || die "could not update 'latest' symlink"

ssh "$DEST_HOST" "cd '$DEST_ROOT' && ls -1d 20*/ 2>/dev/null | sed 's#/\$##' \
    | head -n -$KEEP | xargs -r rm -rf" \
    || echo "WARNING: pruning old snapshots failed" >&2

USED=$(ssh "$DEST_HOST" "du -sh '$DEST_ROOT' 2>/dev/null | cut -f1")
COUNT=$(ssh "$DEST_HOST" "ls -1d '$DEST_ROOT'/20*/ 2>/dev/null | wc -l")

echo "Snapshot $STAMP complete. $COUNT snapshots retained, $USED total on lindus."
hc "" "OK: snapshot $STAMP ($COUNT retained, $USED total)"
