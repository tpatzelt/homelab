#!/usr/bin/env bash
#
# Restarts every compose stack in the repo. Uses `down` then `up -d` (never a
# bare `up -d`) so a stack whose running container names have drifted from
# the current compose.yaml (e.g. after a container_name rename) can't end up
# with a duplicate process bind-mounting the same data dir — see the immich
# postgres incident in project memory.
#
# Order matters: caddy_network must exist before anything attaches to it,
# caddy must be up before core/other stacks that reverse-proxy through it.
# Within the "other stacks" group, order is not significant.

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
  echo "==> restarting ${stack}"
  docker compose -f "$compose_file" down --remove-orphans
  docker compose -f "$compose_file" up -d
done

echo "==> done"
