#!/bin/bash

SOURCE="/mnt/storage/data"
DEST="/mnt/backup/backup/data"
DOCKER_SOURCE="/mnt/storage/docker"
DOCKER_DEST="/mnt/backup/backup/docker"
LOG="/var/log/backup-data.log"
DATE=$(date '+%Y-%m-%d %H:%M:%S')

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting backup" >> "$LOG"

# Mount USB backup drive (ext4)
if ! mount /dev/sdc1 /mnt/backup; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: cannot mount /dev/sdc1 to /mnt/backup" >> "$LOG"
    exit 1
fi

# Ensure destinations exist
mkdir -p "$DEST"
mkdir -p "$DOCKER_DEST"

# Run rsync for data
rsync -a --delete "$SOURCE/" "$DEST/" >> "$LOG" 2>&1
STATUS_DATA=$?

# Run rsync for docker
rsync -a --delete "$DOCKER_SOURCE/" "$DOCKER_DEST/" >> "$LOG" 2>&1
STATUS_DOCKER=$?

umount /mnt/backup

if [ $STATUS_DATA -eq 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Data backup completed successfully" >> "$LOG"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Data backup failed with status $STATUS_DATA" >> "$LOG"
fi

if [ $STATUS_DOCKER -eq 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Docker backup completed successfully" >> "$LOG"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Docker backup failed with status $STATUS_DOCKER" >> "$LOG"
fi

echo "" >> "$LOG"
