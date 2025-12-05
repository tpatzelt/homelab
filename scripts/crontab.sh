# This is a copy of the crontab commands (as root)
PATH="/usr/local/bin:/usr/bin:/bin"

0 3 * * * (date && autorestic -c /home/tim/coding/homelab/.autorestic.yml backup -a) >> /var/log/autorestic.log 2>&1
