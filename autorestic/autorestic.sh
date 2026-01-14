#!/bin/bash

MOUNT_POINT="/mnt/backup"
DEVICE="/dev/sdc1"

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

# 1. Mount the drive if not already mounted
if ! mountpoint -q "$MOUNT_POINT"; then
    echo "Mounting backup drive..."
    mount "$DEVICE" "$MOUNT_POINT"
fi

# 2. Run Autorestic
source /home/tim/coding/secrets/.autorestic.env
/usr/local/bin/autorestic -c /home/tim/coding/homelab/autorestic/.autorestic.yml backup -a --verbose

# 3. Script finishes -> 'trap' triggers cleanup() automatically