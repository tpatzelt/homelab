#!/bin/bash
set -uo pipefail

MOUNT_POINT="/mnt/backup"
# Mount by filesystem label — /dev/sdX names can change across reboots
DEVICE="/dev/disk/by-label/backup"
ENV_FILE="/home/tim/coding/homelab/secrets/.autorestic.env"
CONFIG="/home/tim/coding/homelab/autorestic/.autorestic.yml"
REPO="$MOUNT_POINT/restic-backups"
# Must match the location names in .autorestic.yml — update both together
LOCATIONS="my-data docker-data secrets"

# set -a exports RESTIC_PASSWORD (and HEALTHCHECKS_URL) so child processes see them
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

# Ping healthchecks.io: $1 = "" | "/start" | "/fail", $2 = optional message body.
# No-op if HEALTHCHECKS_URL is not configured; never fails the script itself.
hc_ping() {
    [ -n "${HEALTHCHECKS_URL:-}" ] || return 0
    curl -fsS -m 10 --retry 3 --data-raw "${2:-}" "${HEALTHCHECKS_URL}${1}" >/dev/null || true
}

fail() {
    echo "BACKUP FAILED: $1"
    hc_ping /fail "$1"
    exit 1
}

# Function to unmount cleanup
cleanup() {
    echo "Cleaning up..."
    # Attempt to unmount, lazy unmount (-l) if busy
    if mountpoint -q "$MOUNT_POINT"; then
        umount "$MOUNT_POINT" || umount -l "$MOUNT_POINT"
        echo "Drive unmounted."
    fi
}

# Register the cleanup function to run on EXIT (success or failure)
trap cleanup EXIT

date
echo "Starting Backup Process..."
hc_ping /start

# 1. Mount the drive if not already mounted
if ! mountpoint -q "$MOUNT_POINT"; then
    echo "Mounting backup drive..."
    mount "$DEVICE" "$MOUNT_POINT" || fail "could not mount $DEVICE at $MOUNT_POINT"
fi

# 2. Run Autorestic
/usr/local/bin/autorestic -c "$CONFIG" backup -a --verbose \
    || fail "autorestic backup exited non-zero"

# 3. Verify every location produced a snapshot today — a run that exits 0
#    without snapshots (e.g. bad password, empty repo) must count as failure
export RESTIC_REPOSITORY="$REPO"
TODAY=$(date +%F)
for loc in $LOCATIONS; do
    /usr/local/bin/restic snapshots --tag "ar:location:$loc" --latest 1 --json 2>/dev/null \
        | grep -q "\"time\":\"$TODAY" \
        || fail "no snapshot from $TODAY for location '$loc'"
    echo "Verified: snapshot from $TODAY exists for '$loc'"
done

echo "Backup completed and verified."
hc_ping "" "OK: snapshots for [$LOCATIONS] created $TODAY"

# 4. Script finishes -> 'trap' triggers cleanup() automatically
