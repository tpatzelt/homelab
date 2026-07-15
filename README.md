# homelab

Personal homelab infrastructure-as-config: Docker Compose stacks fronted by a
Caddy reverse proxy on a single host. There is no application code or build
step — everything is `compose.yaml` files, a Caddyfile, and env files.

The real domain is kept out of the repo. Caddy reads it from the `DOMAIN` env
var (`{$DOMAIN}` placeholders in the Caddyfile); `example.com` stands in for it
below. Internal services live on `*.dev.example.com` (LAN-only wildcard DNS),
public ones on `*.example.com` via a Cloudflare Tunnel.

## Services

| Stack | Service | Subdomain | Description |
|-------|---------|-----------|-------------|
| **caddy** | Caddy | — | Reverse proxy, wildcard TLS via Cloudflare DNS-01, CrowdSec bouncer |
| | GoAccess | `goaccess.dev.example.com` | Access-log analytics (GeoIP) |
| | CrowdSec | — | Intrusion detection feeding the Caddy bouncer |
| **core** | Pi-hole | `pihole.dev.example.com` | Network-wide ad-blocking DNS |
| | Dozzle | `dozzle.dev.example.com` | Real-time Docker log viewer |
| | Heimdall | `heimdall.dev.example.com` | Application dashboard |
| | Beszel (+agent) | `beszel.dev.example.com` | Server monitoring |
| **arr** | Gluetun | — | VPN gateway (AirVPN, WireGuard) |
| | qBittorrent | `qbittorrent.dev.example.com` | Torrent client (via VPN) |
| | Sonarr / Radarr / Lidarr | `sonarr.` / `radarr.` / `lidarr.dev.example.com` | TV / movie / music management (via VPN) |
| | Bazarr / Prowlarr | `bazarr.` / `prowlarr.dev.example.com` | Subtitles / indexers (via VPN) |
| **seerr** | Seerr | `seerr.dev.example.com` | Media requests |
| **jellyfin** | Jellyfin | `jellyfin.dev.example.com` | Media server (LAN only — no tunnel, see below) |
| **immich** | Immich | `immich.dev.example.com` | Photo/video backup |
| **navidrome** | Navidrome | `navidrome.dev.example.com` | Music streaming (Subsonic API) |
| **filebrowser** | File Browser | `filebrowser.dev.example.com` | Web file manager for `/mnt/storage/data` |
| **vaultwarden** | Vaultwarden | `vaultwarden.dev.example.com` | Password manager (Bitwarden-compatible) |
| **utilities** | Karakeep | `karakeep.dev.example.com` | Bookmark manager (+ Meilisearch, Chrome) |
| | ip-tracker | `iptracker.dev.example.com` | Public-IP change tracker |
| **job-agent** | job-agent | — | Telegram job-application agent (bot only, no web UI) |
| **cloudflared** | cloudflared | — | Cloudflare Tunnel — the only public ingress |
| **annabel-rene** | Wedding site | `annabel-rene.example.com` | Public static site, served through the tunnel |

## Architecture

```
                        Internet
                            │
              Cloudflare Tunnel (cloudflared)          ← no forwarded router ports
                            │
             ┌──────────────▼──────────────┐
   LAN ─────►│      Caddy (80/443)         │
             │  wildcard TLS · CrowdSec    │
             │  security headers · logs    │
             └──────────────┬──────────────┘
                            │ caddy_network
      ┌─────────────────────┼──────────────────────┐
      │                     │                      │
  most services         gluetun ◄─ gluetun_network │  beszel-agent
  (pihole, immich,      (VPN)      qbittorrent,    │  (host network)
  jellyfin, vault-                 sonarr, radarr, │
  warden, …)                       lidarr, bazarr, │
                                   prowlarr        │
```

- **caddy_network** (external, create once): everything reachable behind Caddy.
- **gluetun_network**: *arr services run with `network_mode: service:gluetun`,
  so all their traffic exits through the VPN. Caddy proxies to `gluetun:<port>`
  for them, not to their container names.
- **Cloudflare Tunnel** is the only path in from the internet. It terminates at
  `https://caddy:443` (not the app container) so public traffic still passes
  CrowdSec, the security headers, and the access log. Jellyfin is deliberately
  not tunnelled — Cloudflare's ToS forbids video streaming over the free CDN.
- All persistent state lives under `/opt/dockerdata/<service>`; media/user data
  under `/mnt/storage`.

## Secrets

Real env files live in `secrets/*.env` (gitignored). Each stack's
`compose/<name>/.env` is a symlink into `secrets/`, and `secrets/*.env.example`
are the checked-in templates. The cloudflared tunnel config and credential both
live outside the repo under `/opt/dockerdata/cloudflared/` (`config.yml` carries
the tunnel UUID + hostnames, `creds.json` the credential); the directory is
bind-mounted into the container and `compose/cloudflared/config.yml.example` is
the tracked template to copy from.

## Quick Start

1. **Create env files from the templates:**
   ```bash
   for f in secrets/.*.env.example; do cp "$f" "${f%.example}"; done
   # edit each secrets/*.env with real values (incl. DOMAIN in .caddy.env)
   ```

2. **Symlink them into the stacks** (repeat per stack; cloudflared needs none):
   ```bash
   for d in annabel-rene arr caddy core filebrowser immich jellyfin job-agent seerr utilities vaultwarden; do
     ln -s "../../secrets/.$d.env" "compose/$d/.env"
   done
   ln -s ../../secrets/.navidrom.env compose/navidrome/.env   # filename typo is intentional
   sudo install -Dm644 compose/cloudflared/config.yml.example \
     /opt/dockerdata/cloudflared/config.yml  # then edit with the real tunnel UUID + hostname
   ```

3. **Create the shared network:**
   ```bash
   docker network create caddy_network
   ```

4. **Start stacks (order matters: caddy → core → the rest):**
   ```bash
   docker compose -f compose/caddy/compose.yaml up -d
   docker compose -f compose/core/compose.yaml up -d
   for s in arr cloudflared immich jellyfin job-agent navidrome filebrowser seerr vaultwarden utilities annabel-rene; do
     docker compose -f compose/$s/compose.yaml up -d
   done
   ```

> **Gotcha:** after editing `compose/caddy/Caddyfile` (or any other single-file
> bind mount), `caddy reload` is not enough — editors replace the file's inode
> and the container keeps the old one. Force-recreate instead:
> `docker compose -f compose/caddy/compose.yaml up -d --force-recreate caddy`

## Validation

`scripts/check.sh` runs an offline validation harness over the whole repo:
`docker compose config` on every stack, env-template completeness,
`caddy validate` plus Caddyfile-upstream/compose consistency (gluetun-aware),
autorestic `LOCATIONS` sync, README service-table coverage, shellcheck,
yamllint (config in `.yamllint`), and a warn-only image-pinning report.

```bash
./scripts/check.sh
```

It needs Docker and python3 and reads **no real secrets** — dummy env files
are generated from `secrets/*.env.example` into a temp dir and cleaned up.
shellcheck/yamllint are used from PATH when installed, otherwise via their
Docker images. CI (`.github/workflows/check.yml`) runs the same script on
every push and pull request.

## Updates

Image version bumps arrive as automated [Renovate](https://docs.renovatebot.com/)
pull requests (config: `.github/renovate.json5`), batched weekly. The same
`check.sh` CI runs on each PR and gates auto-merge, but it only validates
config (`docker compose config`, `caddy validate`, cross-file invariants) —
**not** that the new image actually runs on the host, so still compare a bump
against the running container before recreating. Every image is pinned;
`renovate.json5`'s ignore list is the source of truth for the intentionally
unpinned ones (the owner's personal `ghcr.io/tpatzelt/*` images, deployed by
their own pipelines).

## Backups

Automated via [autorestic](https://autorestic.vercel.app/):
- Config: `autorestic/.autorestic.yml`; restic password in
  `secrets/.autorestic.env` (template checked in).
- Locations: `/mnt/storage/data` (user data), `/opt/dockerdata` (service
  state), `secrets/` (env files).
- Runs weekly from root's crontab via `autorestic/autorestic.sh`, which mounts
  the backup HDD on demand and unmounts afterwards — `/mnt/backup` being empty
  between runs is expected.
- The `docker-data` location's hook stops all containers except `pihole`
  during the snapshot and restarts them after.

## Hardware

**Acer Veriton N4640G**
- CPU: Intel Celeron G3900T @ 2.60GHz (2 cores)
- RAM: 32 GB DDR4
- Storage:
  - 232 GB SSD (system, LVM — includes `/opt/dockerdata`)
  - 3.6 TB HDD (`/mnt/storage`) — media and user data
  - 1.8 TB HDD — autorestic backup target, mounted on demand at `/mnt/backup`

## Host Configuration Notes

### Pi-hole / systemd-resolved
- Set `DNSStubListener=no` in `/etc/systemd/resolved.conf`, then
  `sudo systemctl restart systemd-resolved`.
- Fritzbox DHCP DNS: [Pi-hole Fritzbox guide](https://docs.pi-hole.net/routers/fritzbox/#distribute-pi-hole-as-dns-server-via-dhcp)

### Cron
- The backup job lives in root's crontab (`sudo crontab -e`) and calls
  `autorestic/autorestic.sh`.

### Mounts
- `/mnt/storage` is mounted at boot via `/etc/fstab` (UUID entry with
  `defaults,nofail`). The backup HDD is *not* in fstab — the backup script
  mounts it only for the duration of a run.
