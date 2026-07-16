#!/usr/bin/env bash
#
# Restarts (and pulls) every compose stack in the repo. For each stack:
# `pull` -> `down` -> `up -d`.
#
#   pull first, always, because pihole (in `core`) is the LAN's own DNS. A
#   bare `down` on core removes pihole, and if the new image still has to be
#   pulled afterwards that pull needs the DNS that was just torn down —
#   deadlock (this actually happened; see project memory). Pulling before the
#   down means every image is already local when its container is recreated,
#   so the only window pihole is down carries no network dependency. With
#   `set -e` a failed pull also aborts *before* the down, so a stack is never
#   torn down when its replacement image couldn't be fetched.
#
#   down then up (never a bare `up -d`) so a stack whose running container
#   names have drifted from the current compose.yaml (e.g. after a
#   container_name rename) can't end up with a duplicate process bind-mounting
#   the same data dir — see the immich postgres incident in project memory.
#
# Order matters: caddy_network must exist before anything attaches to it,
# caddy must be up before core/other stacks that reverse-proxy through it.
# Within the "other stacks" group, order is not significant.
#
# --ignore-buildable skips locally-built images (caddy) that have no registry
# to pull from — this script only restarts; rebuilding caddy is a separate,
# explicit `docker compose -f compose/caddy/compose.yaml build` step.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FIRST=(caddy core)

mapfile -t ALL_STACKS < <(find compose -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)
REMAINING=()
for stack in "${ALL_STACKS[@]}"; do
  skip=0
  for first in "${FIRST[@]}"; do
    [[ "$stack" == "$first" ]] && skip=1 && break
  done
  [[ "$skip" -eq 0 ]] && REMAINING+=("$stack")
done
STACKS=("${FIRST[@]}" "${REMAINING[@]}")

if ! docker network inspect caddy_network >/dev/null 2>&1; then
  echo "==> creating caddy_network"
  docker network create caddy_network
fi

for stack in "${STACKS[@]}"; do
  compose_file="compose/${stack}/compose.yaml"
  if [[ ! -f "$compose_file" ]]; then
    echo "==> skipping ${stack} (no compose.yaml)"
    continue
  fi
  echo "==> pulling ${stack}"
  docker compose -f "$compose_file" pull --ignore-buildable
  echo "==> restarting ${stack}"
  docker compose -f "$compose_file" down --remove-orphans
  docker compose -f "$compose_file" up -d
done

echo "==> done"
