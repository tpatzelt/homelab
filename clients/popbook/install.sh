#!/bin/bash
# Installs the popbook -> lindus snapshot backup. Run as root on popbook.
#
# Only the tracked artifacts are installed here. The SSH identity, the
# lindus-backup host entry and the Healthchecks URL are deliberately not in
# this repo (it is public); see README.md for how to create them. This script
# checks they exist and tells you what is missing rather than half-working.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "run me as root" >&2; exit 1; }

echo "==> installing script, excludes, systemd units"
install -m 0755 "$SRC/popbook-snapshot.sh"       /usr/local/bin/popbook-snapshot
install -m 0644 "$SRC/popbook-snapshot.excludes" /etc/popbook-snapshot.excludes
install -m 0644 "$SRC/popbook-snapshot.service"  /etc/systemd/system/popbook-snapshot.service
install -m 0644 "$SRC/popbook-snapshot.timer"    /etc/systemd/system/popbook-snapshot.timer

echo "==> checking untracked prerequisites"
missing=0
note() { echo "    MISSING: $1"; missing=1; }

grep -q '^Host lindus-backup' /root/.ssh/config 2>/dev/null \
    || note "'Host lindus-backup' in /root/.ssh/config (see README)"
[ -r /root/.ssh/id_popbook_backup ] \
    || note "/root/.ssh/id_popbook_backup (ssh-keygen -t ed25519, install pubkey on lindus)"
[ -s /root/.ssh/known_hosts ] \
    || note "/root/.ssh/known_hosts — pin lindus' host key, verify the fingerprint first"
[ -r /etc/popbook-snapshot.env ] \
    || echo "    OPTIONAL: /etc/popbook-snapshot.env absent — runs fine, reports nowhere"

if [ "$missing" -ne 0 ]; then
    echo
    echo "Prerequisites missing; not enabling the timer. Fix the above and re-run." >&2
    exit 1
fi

echo "==> connectivity check"
ssh -o BatchMode=yes -o ConnectTimeout=10 lindus-backup \
    'echo "    connected as $(whoami)@$(hostname)"; ls -ld /mnt/storage/backups/popbook-system'

echo "==> enabling timer"
systemctl daemon-reload
systemctl enable --now popbook-snapshot.timer

echo
systemctl list-timers popbook-snapshot.timer --no-pager
echo
echo "First run (mains power; the initial snapshot moves ~25G):"
echo "    systemctl start popbook-snapshot.service"
echo "    journalctl -fu popbook-snapshot.service"
