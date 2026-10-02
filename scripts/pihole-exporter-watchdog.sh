#!/bin/bash
#
# Restarts pihole-exporter when it has wedged.
#
# ekofr/pihole-exporter v1.2.0 (the latest release; the bug is still on
# upstream main) has a channel race in its /metrics handler: when one
# collection overruns its 10s context, the handler leaves behind a goroutine
# that discards the *next* collection's result. From then on every request is
# answered only when the following one arrives, so Prometheus (30s interval,
# 10s timeout) times out on every scrape until the process restarts. Pi-hole
# itself stays healthy throughout. First seen 2026-10-01, 20:54 -> 04:42 UTC.
#
# Detection reads `up` from Prometheus rather than probing /metrics directly:
# an extra request would itself unblock the stuck one and mask the wedge.
#
# Quiet on success (it runs every 2 minutes); prints only when it acts or
# cannot decide. Exit 0 = healthy or restarted, 1 = could not check.

set -uo pipefail

EXPORTER="pihole-exporter"
PIHOLE="pihole"
# Must stay below Grafana's 5m `for:` on "Metrics target down" for the restart
# to land before the alert fires (cron granularity eats the rest).
WINDOW="3m"
# Don't judge a freshly (re)started exporter — it has no history yet.
MIN_UPTIME_S=300

log() { echo "$(date -u '+%F %T') $*"; }

running() { [ "$(docker inspect "$1" --format '{{.State.Running}}' 2>/dev/null)" = "true" ]; }

# Stopped (e.g. by the weekly backup hook) is not wedged — leave it alone.
running "$EXPORTER" || exit 0

started=$(docker inspect "$EXPORTER" --format '{{.State.StartedAt}}')
uptime_s=$(( $(date +%s) - $(date -d "$started" +%s) ))
[ "$uptime_s" -ge "$MIN_UPTIME_S" ] || exit 0

# max_over_time(up[3m]) == 0 means not a single scrape succeeded in the window.
query="max_over_time(up%7Bjob%3D%22pihole%22%7D%5B${WINDOW}%5D)"
resp=$(docker exec prometheus wget -qO- -T 10 "http://localhost:9090/api/v1/query?query=${query}" 2>/dev/null)
if [ -z "$resp" ]; then
    log "could not query prometheus — skipped"
    exit 1
fi
value=$(grep -o '"value":\[[^]]*\]' <<<"$resp" | grep -o '"[01]"' | tr -d '"')
[ "$value" = "0" ] || exit 0

# If Pi-hole is the one that's down, a restart won't help.
health=$(docker inspect "$PIHOLE" --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null)
if ! running "$PIHOLE" || [ "$health" != "healthy" ]; then
    log "$EXPORTER scrapes failing but $PIHOLE is not healthy (${health:-not running}) — not restarting"
    exit 0
fi

log "$EXPORTER: no successful scrape in ${WINDOW} while $PIHOLE is healthy — restarting"
docker restart "$EXPORTER" >/dev/null && log "restarted $EXPORTER"
