#!/bin/bash

SOURCE="/mnt/storage/data"
DEST="/mnt/backup/backup/data"
DOCKER_SOURCE="/mnt/storage/docker"
DOCKER_DEST="/mnt/backup/backup/docker"
LOG="/var/log/backup-data.log"
DATE=$(date '+%Y-%m-%d %H:%M:%S')

echo "[$DATE] Starting backup" >> "$LOG"

# Mount RW for backup
if ! mount -t cifs //192.168.178.1/FRITZ.NAS /mnt/backup \
    -o credentials=/root/.smbcredentials,iocharset=utf8,uid=1000,gid=1000,vers=3.0,noperm,noserverino,_netdev,rw; then
    echo "[$DATE] ERROR: cannot mount backup share read-write" >> "$LOG"
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
    echo "[$DATE] Data backup completed successfully" >> "$LOG"
else
    echo "[$DATE] Data backup failed with status $STATUS_DATA" >> "$LOG"
fi

if [ $STATUS_DOCKER -eq 0 ]; then
    echo "[$DATE] Docker backup completed successfully" >> "$LOG"
else
    echo "[$DATE] Docker backup failed with status $STATUS_DOCKER" >> "$LOG"
fi

echo "" >> "$LOG"
