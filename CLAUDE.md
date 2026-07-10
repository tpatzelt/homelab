# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Personal homelab infrastructure-as-config: a set of Docker Compose stacks fronted by Caddy, running on a single Acer Veriton host. There is no application source code or build step — changes are almost entirely to `compose.yaml` files, the Caddyfile, and env files.

**This repo is public.** The real domain is deliberately kept out of tracked files: the Caddyfile uses `{$DOMAIN}` env placeholders (substituted by Caddy at parse time from `DOMAIN` in `secrets/.caddy.env`), compose files interpolate `${DOMAIN}`/`${…_URL}` vars from their env files, and `compose/cloudflared/config.yml` is gitignored (use `config.yml.example`). When editing, never write the real domain, LAN IPs, or any secret value into a tracked file — docs use `example.com` as the stand-in. Internal services are `<name>.dev.<domain>`, public ones `<name>.<domain>`.

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

After editing `compose/caddy/Caddyfile`, **force-recreate** the `caddy` container (it's mounted, not baked into the image):
```bash
docker compose -f compose/caddy/compose.yaml up -d --force-recreate caddy
```

`caddy reload` and `docker restart` are **not** enough if the editor wrote the file atomically (write-temp-then-rename — most editors, `sed -i`, and Claude Code's Edit/Write tools all do this). Docker resolves a single-file bind mount to an *inode* at container-create time, so the rename leaves the container serving the old file. `caddy reload` then exits 0 and logs `adapted config to JSON` while re-reading the stale config — the failure is completely silent, and only shows up as the catch-all `abort` closing connections on the route you thought you just added.

Check for it with:
```bash
diff <(docker exec caddy cat /etc/caddy/Caddyfile) compose/caddy/Caddyfile
```
Only reach for `caddy reload` when the file was edited in place (e.g. a shell append). The same trap applies to every other single-file bind mount in this repo — `compose/cloudflared/config.yml`, `compose/caddy/GeoLite2-City.mmdb`.

There is no lint/test suite. "Validation" means: `docker compose config` for YAML/interpolation errors, and checking the Caddyfile matcher/host names against the compose service names.

## Architecture

### Stacks (`compose/<name>/compose.yaml`)
- **caddy** — reverse proxy (custom-built image with Cloudflare DNS + CrowdSec bouncer plugins, see `compose/caddy/Dockerfile`), plus `goaccess` (log analytics UI) and `crowdsec` (intrusion detection feeding the Caddy bouncer). This is the only stack that binds host ports 80/443.
- **core** — dozzle (log viewer), pihole (DNS), heimdall (dashboard), beszel/beszel-agent (monitoring; the agent runs with `network_mode: host`).
- **arr** — `gluetun` (VPN, AirVPN/Netherlands) plus qbittorrent/sonarr/radarr/lidarr/bazarr/prowlarr, all attached via `network_mode: service:gluetun` so their traffic routes through the VPN tunnel. Only `gluetun` itself joins `caddy_network`, so Caddy reverse-proxies to `gluetun:<port>` for every *arr service, not to the service's own container name.
- **cloudflared** — a locally-managed Cloudflare Tunnel (ingress rules in `compose/cloudflared/config.yml`, which is **gitignored** because it carries the tunnel UUID and real hostnames — `config.yml.example` is the tracked template; credential at `/opt/dockerdata/cloudflared/creds.json`). This is the only way anything in this homelab is reachable from the internet; no router ports are forwarded. It deliberately proxies to `https://caddy:443` rather than straight to an app container, so tunnelled traffic still passes CrowdSec, the security headers, and the access log. It has no `.env` — a locally-managed tunnel carries no env-var secrets, so it intentionally skips the `secrets/` symlink convention below.
- **immich**, **jellyfin**, **navidrome**, **filebrowser**, **seerr**, **vaultwarden**, **utilities** (karakeep + ip-tracker), **annabel-rene** (wedding site) — standalone media/utility stacks.

### Networking
Two Docker networks tie everything together:
- `caddy_network` (external, created once, referenced by every stack that needs a public route) — services reachable behind Caddy attach here.
- `gluetun_network` (defined in `arr`, subnet `172.60.0.0/24`) — VPN-routed *arr services live behind this; `gluetun` bridges it to `caddy_network`.

Routing in `compose/caddy/Caddyfile` is host-matcher based against a wildcard cert: `*.dev.{$DOMAIN}` for internal services, `*.{$DOMAIN}` for the public domain. Every block ends in a catch-all `abort`. CrowdSec is wired in globally (`order crowdsec first`, `route { crowdsec }`) and access logs go to `/var/log/caddy/wildcard-access.log`, which both `goaccess` and `crowdsec`'s log-based scenarios read.

A Caddyfile route existing does **not** mean a host is reachable — DNS decides that, and the two wildcards resolve very differently:
- `*.dev.<domain>` is a wildcard A record to the host's LAN IP, so it only works from inside the LAN.
- `*.<domain>` has **no** wildcard record. Only the wedding site's hostname exists publicly, as a proxied CNAME to the tunnel — a `handle` in the public block does nothing until a DNS record exists.

To expose a new public host: add an ingress rule in `compose/cloudflared/config.yml`, a `handle` block in the `*.{$DOMAIN}` Caddy block, and run `cloudflared tunnel route dns homelab <host>`. Two constraints to respect — Cloudflare's ToS §2.8 forbids proxying video streaming over the free CDN (so Jellyfin must not go through the tunnel), and the free plan rejects request bodies over 100 MB at the edge, before they ever reach Caddy or any log.

Client IPs survive the tunnel: cloudflared appears only as `remote_ip` in the access log, while `client_ip` holds the real visitor (Caddy trusts `X-Forwarded-For` via the global `trusted_proxies static private_ranges`). CrowdSec's `caddy-logs` parser reads `client_ip`, so bans land on real clients rather than on the tunnel container.

### Secrets and env files
Real env files live in `secrets/*.env` (gitignored) and each `compose/<name>/.env` is a **symlink** into `secrets/`, e.g. `compose/caddy/.env -> ../../secrets/.caddy.env`. `secrets/*.env.example` are the checked-in templates — when adding a new stack, add both the example and wire up the symlink. Note the `navidrome` stack's secret is named `.navidrom.env` (typo, kept for consistency with the existing symlink — don't silently "fix" it without repointing the symlink too). `secrets/.autorestic.env` (restic password) is sourced by `autorestic/autorestic.sh` rather than a compose stack, so it has an example but no symlink. The `annabel-rene` stack uses compose interpolation (`${VAR}` from the auto-loaded `./.env`) instead of `env_file:` so only the referenced vars reach the container.

### Persistent data & backups
All service state lives under `/opt/dockerdata/<service>/`; media/user data lives under `/mnt/storage`; backups land on `/mnt/backup`. Backups are automated via `autorestic` (`autorestic/.autorestic.yml`), which snapshots `/mnt/storage/data`, `/opt/dockerdata`, and `secrets/` to a local restic repo. Root's crontab runs `autorestic/autorestic.sh` weekly; the script mounts the backup HDD on demand and unmounts afterwards, so an empty `/mnt/backup` between runs is normal — don't "fix" it. The `docker-data` location's backup hook stops all running containers except `pihole` before snapshotting and restarts them after — keep this in mind if changing container names, since the hook does a `docker ps` name-grep exclude.

## Conventions (from prior project instructions)
- Service names: lowercase with hyphens (`immich-server`, not `immich_server`).
- Persistent volumes always mount to an absolute host path under `/opt/dockerdata/<service>`.
- Env vars via `env_file: ./.env`, backed by the `secrets/` symlink pattern above — never hardcode secrets into a `compose.yaml`.
- Pin image versions (e.g. `image:1.2.3`); avoid `latest` except where an existing service already uses it (a few, like `navidrome` and `filebrowser`, currently don't follow this — match the file you're editing rather than "fixing" unrelated services).
- Keep additions minimal — only add services/config that are essential to a given stack; commented-out service blocks (see `compose/utilities/compose.yaml`) are intentionally disabled, not dead code to delete.
