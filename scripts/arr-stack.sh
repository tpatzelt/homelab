#!/bin/bash
#
# Park or revive the *arr stack (gluetun + qbittorrent/sonarr/radarr/lidarr/
# bazarr/prowlarr + exportarr) together with everything that watches it.
#
#   scripts/arr-stack.sh down     stop it and silence its monitoring
#   scripts/arr-stack.sh up       start it and turn its monitoring back on
#   scripts/arr-stack.sh status   show what state each piece is in
#
# The stack needs a paid VPN (AirVPN, see secrets/.arr.env). Without one gluetun
# never turns healthy, nothing behind it starts, and four things keep paging:
#
#   1. tim's crontab runs scripts/vpn-egress-check.sh every 10 min, which pings
#      Healthchecks.io /fail. Commented out with a marker on `down`.
#   2. The Healthchecks.io check behind that ping is a dead-man switch, so it
#      goes red once the pings stop. Paused through the API when
#      HEALTHCHECKS_API_KEY is set in secrets/.vpn-egress.env, otherwise pause
#      it by hand in the Healthchecks.io UI. On `up` the first ping resumes it.
#   3. Grafana's "Service down" rule fires for the six blackbox probes
#      (label stack=arr) and
#   4. "Metrics target down" fires for the three exportarr targets (job=arr).
#      Both are muted by Grafana silences tagged with SILENCE_TAG, and expired
#      on `up`. Nothing in the tracked alerting config changes.
#
# The parked state is the gitignored marker compose/arr/.disabled, so parking
# leaves the tree clean and restart-services.sh still deploys. That script
# skips any stack with a .disabled marker; without the skip a full redeploy
# would wait on gluetun forever.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/compose/arr/compose.yaml"
MARKER="$REPO_ROOT/compose/arr/.disabled"
EGRESS_SCRIPT="$REPO_ROOT/scripts/vpn-egress-check.sh"
EGRESS_ENV="$REPO_ROOT/secrets/.vpn-egress.env"
MONITORING_ENV="$REPO_ROOT/secrets/.monitoring.env"
CRON_LINE="*/10 * * * * $EGRESS_SCRIPT >> $HOME/logs/vpn-egress-check.log 2>&1"
CRON_MARKER="#arr-stack-disabled# "
SILENCE_TAG="arr-stack.sh: stack parked"

log() { echo "==> $*"; }
warn() { echo "    WARN: $*" >&2; }

# Read one KEY=value from an env file without sourcing the whole thing.
env_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -n1 | sed -e "s/^['\"]//" -e "s/['\"]$//"
}

# --- Grafana silences ----------------------------------------------------------
# Grafana is not published on the host, so talk to its container address on the
# bridge network directly (Linux routes host -> container IPs).

grafana_api() {
  local method="$1" path="$2" body="${3:-}" ip user pass
  ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' grafana 2>/dev/null | awk '{print $1}')"
  [[ -n "$ip" ]] || { warn "grafana is not running"; return 1; }
  user="$(env_value "$MONITORING_ENV" GF_SECURITY_ADMIN_USER)"
  pass="$(env_value "$MONITORING_ENV" GF_SECURITY_ADMIN_PASSWORD)"
  curl -fsS -m 15 -u "$user:$pass" -X "$method" \
    -H 'Content-Type: application/json' ${body:+--data "$body"} \
    "http://${ip}:3000/api/alertmanager/grafana/api/v2${path}"
}

# IDs of our active silences, one per line.
our_silences() {
  grafana_api GET /silences | python3 -c '
import json, sys
tag = sys.argv[1]
for s in json.load(sys.stdin):
    if s["status"]["state"] == "active" and s.get("comment") == tag:
        print(s["id"])
' "$SILENCE_TAG"
}

silence_alerts() {
  if [[ -n "$(our_silences)" ]]; then
    log "grafana silences already in place"
    return 0
  fi
  local start end label
  start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  end="$(date -u -d '+1 year' +%Y-%m-%dT%H:%M:%SZ)"
  # Two silences, because matchers inside one silence are ANDed.
  for label in stack job; do
    grafana_api POST /silences "$(printf '{"matchers":[{"name":"%s","value":"arr","isRegex":false,"isEqual":true}],"startsAt":"%s","endsAt":"%s","createdBy":"arr-stack.sh","comment":"%s"}' "$label" "$start" "$end" "$SILENCE_TAG")" >/dev/null
  done
  log "grafana: silenced stack=arr and job=arr alerts until ${end%%T*}"
}

unsilence_alerts() {
  local id n=0
  while read -r id; do
    [[ -n "$id" ]] || continue
    grafana_api DELETE "/silence/${id}" >/dev/null
    n=$((n + 1))
  done < <(our_silences)
  log "grafana: expired ${n} silence(s)"
}

# --- crontab -------------------------------------------------------------------

cron_disable() {
  local current
  current="$(crontab -l 2>/dev/null || true)"
  if ! grep -qE "^[^#].*${EGRESS_SCRIPT}" <<<"$current"; then
    log "cron: vpn-egress-check already off"
    return 0
  fi
  awk -v script="$EGRESS_SCRIPT" -v marker="$CRON_MARKER" \
    'index($0, script) && $0 !~ /^#/ { print marker $0; next } { print }' <<<"$current" | crontab -
  log "cron: vpn-egress-check commented out"
}

cron_enable() {
  local current
  current="$(crontab -l 2>/dev/null || true)"
  # Drop every commented-out copy of the job (ours or a hand-edited one), then
  # add the canonical line unless an active one survives.
  current="$(awk -v script="$EGRESS_SCRIPT" 'index($0, script) && $0 ~ /^#/ { next } { print }' <<<"$current")"
  if ! grep -qE "^[^#].*${EGRESS_SCRIPT}" <<<"$current"; then
    current+=$'\n'"$CRON_LINE"
  fi
  crontab - <<<"$current"
  log "cron: vpn-egress-check every 10 min"
}

cron_state() {
  if crontab -l 2>/dev/null | grep -qE "^[^#].*${EGRESS_SCRIPT}"; then echo on; else echo off; fi
}

# --- Healthchecks.io -----------------------------------------------------------

hc_pause() {
  local url key uuid
  url="$(env_value "$EGRESS_ENV" HEALTHCHECKS_URL)"
  key="$(env_value "$EGRESS_ENV" HEALTHCHECKS_API_KEY)"
  uuid="${url##*/}"
  if [[ -z "$url" ]]; then
    return 0
  fi
  if [[ -z "$key" ]]; then
    warn "no HEALTHCHECKS_API_KEY in secrets/.vpn-egress.env: pause the VPN leak check by hand at healthchecks.io (it resumes on its own after 'up')"
    return 0
  fi
  if curl -fsS -m 15 -X POST -H "X-Api-Key: $key" "https://healthchecks.io/api/v3/checks/${uuid}/pause" >/dev/null; then
    log "healthchecks.io: VPN leak check paused"
  else
    warn "healthchecks.io pause failed (the key must be a read-write key for the project holding the check)"
  fi
}

# --- commands ------------------------------------------------------------------

cmd_down() {
  log "stopping the arr stack"
  docker compose -f "$COMPOSE_FILE" down
  touch "$MARKER"
  cron_disable
  hc_pause
  silence_alerts
  log "parked. Revive with: scripts/arr-stack.sh up"
}

cmd_up() {
  log "starting the arr stack (waits up to 5 min for gluetun to connect)"
  if ! docker compose -f "$COMPOSE_FILE" up -d --wait --wait-timeout 300; then
    echo "arr stack did not come up healthy; check: docker logs gluetun" >&2
    echo "monitoring left silenced. Fix the VPN, then re-run: scripts/arr-stack.sh up" >&2
    exit 1
  fi
  rm -f "$MARKER"
  log "running the VPN leak check once (its ping also resumes the Healthchecks.io check)"
  if ! "$EGRESS_SCRIPT"; then
    echo "leak check FAILED: stack left running, monitoring left silenced. Investigate before trusting it." >&2
    exit 1
  fi
  cron_enable
  unsilence_alerts
  log "arr stack is up and monitored"
}

cmd_status() {
  echo "marker:       $([[ -f "$MARKER" ]] && echo "parked (compose/arr/.disabled)" || echo "absent (active)")"
  echo "leak check:   cron $(cron_state)"
  echo "silences:     $(our_silences 2>/dev/null | wc -l) active"
  echo "containers:"
  docker compose -f "$COMPOSE_FILE" ps -a --format '  {{.Name}}\t{{.State}}\t{{.Status}}'
}

case "${1:-}" in
  up) cmd_up ;;
  down) cmd_down ;;
  status) cmd_status ;;
  *)
    echo "usage: $0 up|down|status" >&2
    exit 2
    ;;
esac
