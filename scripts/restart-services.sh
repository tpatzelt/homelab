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
#
# Deploy guard: this tree is also a work tree, so the script refuses to run
# unless it is on `main` with no uncommitted changes to tracked files. A
# redeploy from a stale branch silently rolls back image bumps and drops
# routes. Override deliberately with --force or ALLOW_DIRTY_DEPLOY=1.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FORCE="${ALLOW_DIRTY_DEPLOY:-0}"
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      echo "usage: $0 [--force]   (--force or ALLOW_DIRTY_DEPLOY=1 skips the clean-main check)"
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
dirty="$(git status --porcelain --untracked-files=no 2>/dev/null || echo unknown)"
if [[ "$branch" != "main" || -n "$dirty" ]]; then
  if [[ "$FORCE" == "1" ]]; then
    echo "==> WARNING: guard overridden; deploying from branch '${branch}'${dirty:+ with uncommitted changes}"
  else
    {
      echo "refusing to deploy: this tree must be on 'main' with no uncommitted changes."
      echo "  branch: ${branch}"
      if [[ -n "$dirty" ]]; then
        echo "  uncommitted changes to tracked files:"
        printf '%s\n' "$dirty" | sed 's/^/    /'
      fi
      echo "  override with --force or ALLOW_DIRTY_DEPLOY=1"
    } >&2
    exit 1
  fi
fi

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

for net in caddy_network public_network; do
  if ! docker network inspect "$net" >/dev/null 2>&1; then
    echo "==> creating ${net}"
    docker network create "$net"
  fi
done

for stack in "${STACKS[@]}"; do
  compose_file="compose/${stack}/compose.yaml"
  if [[ ! -f "$compose_file" ]]; then
    echo "==> skipping ${stack} (no compose.yaml)"
    continue
  fi
  # A gitignored compose/<stack>/.disabled marker parks a stack (see
  # scripts/arr-stack.sh); bringing it up would hang on gluetun's healthcheck.
  if [[ -f "compose/${stack}/.disabled" ]]; then
    echo "==> skipping ${stack} (parked: compose/${stack}/.disabled)"
    continue
  fi
  echo "==> pulling ${stack}"
  docker compose -f "$compose_file" pull --ignore-buildable
  echo "==> restarting ${stack}"
  docker compose -f "$compose_file" down --remove-orphans
  docker compose -f "$compose_file" up -d
done

echo "==> done"
