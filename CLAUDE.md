# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Personal homelab infrastructure-as-config: a set of Docker Compose stacks fronted by Caddy, running on a single Acer Veriton host (`tim-boo.com` / `dev.tim-boo.com` domains). There is no application source code or build step — changes are almost entirely to `compose.yaml` files, the Caddyfile, and env files.

## Common Commands

There's no top-level `docker compose up` — each stack under `compose/<name>/` is started independently:

```bash
# Start a stack (run from repo root)
docker compose -f compose/<name>/compose.yaml up -d

# View/validate config
docker compose -f compose/<name>/compose.yaml config

# Recreate a single service after editing its compose.yaml
docker compose -f compose/<name>/compose.yaml up -d <service>

# Stop a stack
docker compose -f compose/<name>/compose.yaml down
```

Startup order matters because of shared external networks and reverse-proxy dependencies: `caddy` → `core` → other stacks. `caddy_network` (external, bridge) must exist before any other stack is started (`docker network create caddy_network`).

After editing `compose/caddy/Caddyfile`, reload/restart the `caddy` container to pick up changes (it's mounted, not baked into the image):
```bash
docker compose -f compose/caddy/compose.yaml exec caddy caddy reload --config /etc/caddy/Caddyfile
```

There is no lint/test suite. "Validation" means: `docker compose config` for YAML/interpolation errors, and checking the Caddyfile matcher/host names against the compose service names.

## Architecture

### Stacks (`compose/<name>/compose.yaml`)
- **caddy** — reverse proxy (custom-built image with Cloudflare DNS + CrowdSec bouncer plugins, see `compose/caddy/Dockerfile`), plus `goaccess` (log analytics UI) and `crowdsec` (intrusion detection feeding the Caddy bouncer). This is the only stack that binds host ports 80/443.
- **core** — dozzle (log viewer), pihole (DNS), heimdall (dashboard), beszel/beszel-agent (monitoring; the agent runs with `network_mode: host`).
- **arr** — `gluetun` (VPN, AirVPN/Netherlands) plus qbittorrent/sonarr/radarr/lidarr/bazarr/prowlarr, all attached via `network_mode: service:gluetun` so their traffic routes through the VPN tunnel. Only `gluetun` itself joins `caddy_network`, so Caddy reverse-proxies to `gluetun:<port>` for every *arr service, not to the service's own container name.
- **immich**, **jellyfin**, **navidrome**, **filebrowser**, **seerr**, **vaultwarden**, **utilities** (karakeep + ip-tracker) — standalone media/utility stacks.

### Networking
Two Docker networks tie everything together:
- `caddy_network` (external, created once, referenced by every stack that needs a public route) — services reachable behind Caddy attach here.
- `gluetun_network` (defined in `arr`, subnet `172.60.0.0/24`) — VPN-routed *arr services live behind this; `gluetun` bridges it to `caddy_network`.

Routing in `compose/caddy/Caddyfile` is host-matcher based against a wildcard cert: `*.dev.tim-boo.com` for internal/dev-exposed services, `*.tim-boo.com` for the small subset exposed on the public domain (currently jellyfin, seerr). Every block ends in a catch-all `abort`. CrowdSec is wired in globally (`order crowdsec first`, `route { crowdsec }`) and access logs go to `/var/log/caddy/wildcard-access.log`, which both `goaccess` and `crowdsec`'s log-based scenarios read.

### Secrets and env files
Real env files live in `secrets/*.env` (gitignored) and each `compose/<name>/.env` is a **symlink** into `secrets/`, e.g. `compose/caddy/.env -> ../../secrets/.caddy.env`. `secrets/*.env.example` are the checked-in templates — when adding a new stack, add both the example and wire up the symlink. Note the `navidrome` stack's secret is named `.navidrom.env` (typo, kept for consistency with the existing symlink — don't silently "fix" it without repointing the symlink too).

### Persistent data & backups
All service state lives under `/opt/dockerdata/<service>/`; media/user data lives under `/mnt/storage`; backups land on `/mnt/backup`. Backups are automated via `autorestic` (`autorestic/.autorestic.yml`), which snapshots `/mnt/storage/data`, `/opt/dockerdata`, and `secrets/` to a local restic repo. The `docker-data` location's backup hook stops all running containers except `pihole` before snapshotting and restarts them after — keep this in mind if changing container names, since the hook does a `docker ps` name-grep exclude.

## Conventions (from prior project instructions)
- Service names: lowercase with hyphens (`immich-server`, not `immich_server`).
- Persistent volumes always mount to an absolute host path under `/opt/dockerdata/<service>`.
- Env vars via `env_file: ./.env`, backed by the `secrets/` symlink pattern above — never hardcode secrets into a `compose.yaml`.
- Pin image versions (e.g. `image:1.2.3`); avoid `latest` except where an existing service already uses it (a few, like `navidrome` and `filebrowser`, currently don't follow this — match the file you're editing rather than "fixing" unrelated services).
- Keep additions minimal — only add services/config that are essential to a given stack; commented-out service blocks (see `compose/utilities/compose.yaml`) are intentionally disabled, not dead code to delete.
