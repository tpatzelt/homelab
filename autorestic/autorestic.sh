#!/bin/bash
set -uo pipefail

MOUNT_POINT="/mnt/backup"
# Mount by filesystem label — /dev/sdX names can change across reboots
DEVICE="/dev/disk/by-label/backup"
ENV_FILE="/home/tim/coding/homelab/secrets/.autorestic.env"
CONFIG="/home/tim/coding/homelab/autorestic/.autorestic.yml"
REPO="$MOUNT_POINT/restic-backups"
GDRIVE_REPO="rclone:gdrive:restic-offsite"
# These two lists together must cover every location in .autorestic.yml
# (check.sh enforces the union). LOCAL is verified against the HDD repo,
# OFFSITE against the Google Drive repo — keep both in sync with the config.
LOCAL_LOCATIONS="my-data docker-data secrets"
OFFSITE_LOCATIONS="docker-data secrets offsite-immich offsite-docs offsite-handy"

# restic spawns `rclone` by name for the gdrive backend; cron's minimal PATH
# doesn't include the install dirs, so make them explicit.
export PATH="/usr/local/bin:/usr/bin:$PATH"

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

# Same as hc_ping but for the separate offsite check. The offsite leg is
# best-effort: problems ping here rather than failing the local-verified run.
hc_offsite() {
    [ -n "${HEALTHCHECKS_OFFSITE_URL:-}" ] || return 0
    curl -fsS -m 10 --retry 3 --data-raw "${2:-}" "${HEALTHCHECKS_OFFSITE_URL}${1}" >/dev/null || true
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
for loc in $LOCAL_LOCATIONS; do
    /usr/local/bin/restic snapshots --tag "ar:location:$loc" --latest 1 --json 2>/dev/null \
        | grep -q "\"time\":\"$TODAY" \
        || fail "no snapshot from $TODAY for location '$loc'"
    echo "Verified: snapshot from $TODAY exists for '$loc'"
done

# 4. Repo health check: verify structure every run, and read-verify a rotating
#    1/6 of the pack data so the whole repo gets read every ~6 weeks. Catches
#    HDD bit rot before a restore needs the data.
SUBSET="$(( $(date +%-V) % 6 + 1 ))/6"
/usr/local/bin/restic check --read-data-subset "$SUBSET" \
    || fail "restic check (read-data-subset $SUBSET) failed"
echo "Verified: repo healthy (read subset $SUBSET)"

# 4b. Offsite (Google Drive) verification — BEST-EFFORT. The data was already
#     written during the autorestic backup above (docker-data/secrets fan out
#     to the gdrive backend, plus the offsite-* locations). Verify it here, but
#     never fail the whole run on an offsite-only problem: the local backup is
#     verified, and a transient Google/network issue must not page as a lost
#     backup. It has its own Healthchecks check ($HEALTHCHECKS_OFFSITE_URL).
echo "Verifying offsite (Google Drive) snapshots..."
hc_offsite /start
offsite_ok=1
export RESTIC_REPOSITORY="$GDRIVE_REPO"
for loc in $OFFSITE_LOCATIONS; do
    if /usr/local/bin/restic snapshots --tag "ar:location:$loc" --latest 1 --json 2>/dev/null \
        | grep -q "\"time\":\"$TODAY"; then
        echo "Verified: offsite snapshot from $TODAY exists for '$loc'"
    else
        echo "OFFSITE WARNING: no snapshot from $TODAY for location '$loc'"
        offsite_ok=0
    fi
done

# Structure-only check — no --read-data-subset: that would pull the whole repo
# back over metered egress on every run.
if /usr/local/bin/restic check; then
    echo "Verified: offsite repo healthy (structure)"
else
    echo "OFFSITE WARNING: restic check failed on Google Drive repo"
    offsite_ok=0
fi

if [ "$offsite_ok" -eq 1 ]; then
    echo "Offsite backup completed and verified."
    hc_offsite "" "OK: offsite snapshots for [$OFFSITE_LOCATIONS] created $TODAY"
else
    echo "OFFSITE WARNING: offsite verification had failures (local backup is fine)."
    hc_offsite /fail "offsite verification had failures — see backup log"
fi

echo "Backup completed and verified."
hc_ping "" "OK: snapshots for [$LOCAL_LOCATIONS] created $TODAY"

# 5. Script finishes -> 'trap' triggers cleanup() automatically
