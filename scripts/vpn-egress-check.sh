#!/bin/bash
#
# Verifies that nothing behind gluetun can reach the internet as this host.
#
# The *arr stack routes every service through gluetun's network namespace
# (network_mode: service:gluetun), so a leak means either the netns binding
# came undone or gluetun's kill switch is not in place. This checks both
# structurally *and* empirically:
#
#   1. gluetun is running
#   2. its iptables/ip6tables default policies are DROP (the kill switch)
#   3. every dependent container really shares gluetun's netns
#   4. the public IP seen from inside that netns != this host's public IP
#
# What it does NOT catch: the few-second conntrack window at container start
# (gluetun accepts ESTABLISHED,RELATED, so a connection opened before the
# firewall loads survives it — qdm12/gluetun, fixed only on :latest). Every
# dependent container gates on `depends_on: gluetun: condition:
# service_healthy`, which is what actually closes that window. This script is
# drift detection: it catches a compose edit, a manual `docker run`, or a
# firewall that failed to apply.
#
# Exit 0 = no leak. Exit 1 = leaking, or could not prove otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/secrets/.vpn-egress.env"

VPN_CONTAINER="gluetun"
# Every service in compose/arr/compose.yaml with network_mode: service:gluetun.
# Keep in sync when adding or removing one.
NETNS_CONTAINERS=(qbittorrent sonarr radarr lidarr bazarr prowlarr)
# The container the egress probe runs in — the highest-stakes consumer of the
# tunnel, and one whose image ships curl.
PROBE_CONTAINER="qbittorrent"
# Tried in order; first one to answer wins. Plain-text IP endpoints only.
IP_ENDPOINTS=(https://ipinfo.io/ip https://ifconfig.me/ip https://api.ipify.org)

# HEALTHCHECKS_URL is optional — pings are skipped when it is unset.
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

FAILURES=()
NOTES=()

add_fail() { FAILURES+=("$1"); echo "  FAIL: $1"; }
add_note() { NOTES+=("$1"); echo "  note: $1"; }
add_ok()   { echo "  ok: $1"; }

# Ping healthchecks.io: $1 = "" | "/start" | "/fail", $2 = optional message.
# Never fails the script itself.
hc_ping() {
    [ -n "${HEALTHCHECKS_URL:-}" ] || return 0
    curl -fsS -m 10 --retry 3 --data-raw "${2:-}" "${HEALTHCHECKS_URL}${1}" >/dev/null || true
}

# Fetch this host's public IP directly (no container involved).
host_public_ip() {
    local url ip
    for url in "${IP_ENDPOINTS[@]}"; do
        ip=$(curl -fsS -4 -m 10 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9.]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# Fetch the public IP as seen from inside a container. An empty result is not
# an error here — with the kill switch up and the tunnel down that is the
# expected, safe outcome, so the caller decides what it means.
container_public_ip() {
    local container="$1" url ip
    for url in "${IP_ENDPOINTS[@]}"; do
        ip=$(docker exec "$container" sh -c \
            "curl -fsS -4 -m 10 '$url' 2>/dev/null || wget -qO- -T 10 '$url' 2>/dev/null" \
            2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9.]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

date
echo "Checking VPN egress..."

# --- 1. gluetun is running --------------------------------------------------
GLUETUN_ID=$(docker inspect "$VPN_CONTAINER" --format '{{.Id}}' 2>/dev/null)
if [ -z "$GLUETUN_ID" ]; then
    add_fail "$VPN_CONTAINER container does not exist"
elif [ "$(docker inspect "$VPN_CONTAINER" --format '{{.State.Running}}')" != "true" ]; then
    add_fail "$VPN_CONTAINER is not running"
else
    add_ok "$VPN_CONTAINER running (health: $(docker inspect "$VPN_CONTAINER" \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}'))"
fi

# --- 2. kill switch: default DROP policies ----------------------------------
# Without these, a container that loses tun0 falls back to eth0 and leaks.
KILLSWITCH_OK=0
if [ -n "$GLUETUN_ID" ]; then
    for bin in iptables ip6tables; do
        rules=$(docker exec "$VPN_CONTAINER" "$bin" -S 2>/dev/null)
        if [ -z "$rules" ]; then
            add_fail "could not read $bin rules from $VPN_CONTAINER"
            continue
        fi
        missing=""
        for chain in INPUT OUTPUT FORWARD; do
            grep -qx -- "-P $chain DROP" <<<"$rules" || missing+=" $chain"
        done
        if [ -n "$missing" ]; then
            add_fail "$bin default policy is not DROP for:$missing (kill switch is off)"
        else
            add_ok "$bin default policy DROP on INPUT/OUTPUT/FORWARD"
            [ "$bin" = "iptables" ] && KILLSWITCH_OK=1
        fi
    done
fi

# --- 3. dependent containers share gluetun's netns --------------------------
# `network_mode: service:gluetun` shows up here as container:<gluetun id>.
# Anything else means the container has its own eth0 — i.e. its own egress.
if [ -n "$GLUETUN_ID" ]; then
    for c in "${NETNS_CONTAINERS[@]}"; do
        state=$(docker inspect "$c" --format '{{.State.Running}}' 2>/dev/null)
        if [ -z "$state" ]; then
            add_note "$c does not exist — skipped"
            continue
        fi
        if [ "$state" != "true" ]; then
            add_note "$c is not running — skipped (a stopped container cannot leak)"
            continue
        fi
        netmode=$(docker inspect "$c" --format '{{.HostConfig.NetworkMode}}')
        if [ "$netmode" = "container:$GLUETUN_ID" ]; then
            add_ok "$c shares $VPN_CONTAINER's netns"
        else
            add_fail "$c has NetworkMode '$netmode', not container:$VPN_CONTAINER — it has its own egress"
        fi
    done
fi

# --- 4. the actual egress comparison ----------------------------------------
HOST_IP=$(host_public_ip)
if [ -z "$HOST_IP" ]; then
    add_fail "could not determine this host's public IP — leak state unverifiable"
else
    add_ok "host public IP: $HOST_IP"
fi

VPN_IP=""
if docker inspect "$PROBE_CONTAINER" --format '{{.State.Running}}' 2>/dev/null | grep -qx true; then
    VPN_IP=$(container_public_ip "$PROBE_CONTAINER")
    if [ -z "$VPN_IP" ]; then
        if [ "$KILLSWITCH_OK" = "1" ]; then
            add_note "$PROBE_CONTAINER has no egress at all — tunnel looks down, but the kill switch is holding (not a leak)"
        else
            add_fail "$PROBE_CONTAINER has no egress and the kill switch is not verified"
        fi
    elif [ -n "$HOST_IP" ] && [ "$VPN_IP" = "$HOST_IP" ]; then
        add_fail "LEAK: $PROBE_CONTAINER egresses as $VPN_IP — the host's own public IP"
    elif [ -n "$HOST_IP" ]; then
        add_ok "$PROBE_CONTAINER egresses as $VPN_IP (differs from host)"
    fi
else
    add_note "$PROBE_CONTAINER is not running — no egress probe"
fi

# --- report -----------------------------------------------------------------
if [ ${#FAILURES[@]} -gt 0 ]; then
    echo "VPN EGRESS CHECK FAILED (${#FAILURES[@]}):"
    printf '  - %s\n' "${FAILURES[@]}"
    hc_ping /fail "$(printf '%s; ' "${FAILURES[@]}")"
    exit 1
fi

SUMMARY="OK: no leak"
[ -n "$VPN_IP" ] && SUMMARY="$SUMMARY (vpn=$VPN_IP host=${HOST_IP:-unknown})"
[ ${#NOTES[@]} -gt 0 ] && SUMMARY="$SUMMARY [$(printf '%s; ' "${NOTES[@]}")]"
echo "$SUMMARY"
hc_ping "" "$SUMMARY"
