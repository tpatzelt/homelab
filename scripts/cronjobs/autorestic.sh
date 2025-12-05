#!/bin/bash

# This should be called from root's crontab
PATH="/usr/local/bin:/usr/bin:/bin"

(date && autorestic -c /home/tim/coding/homelab/.autorestic.yml backup -a) >> /var/log/autorestic.log 2>&1
