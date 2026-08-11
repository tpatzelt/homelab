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
| **romm** | RomM | `romm.dev.example.com` | ROM library manager, browser player (+ MariaDB) |
| **filebrowser** | File Browser | `filebrowser.dev.example.com` | Web file manager for `/mnt/storage/data` |
| **vaultwarden** | Vaultwarden | `vaultwarden.dev.example.com` | Password manager (Bitwarden-compatible) |
| **utilities** | Karakeep | `karakeep.dev.example.com` | Bookmark manager (+ Meilisearch, Chrome) |
| | ip-tracker | `iptracker.dev.example.com` | Public-IP change tracker |
| **job-agent** | job-agent | `jobagent.dev.example.com` | Telegram job-application agent (+ read-only monitoring dashboard) |
| **cloudflared** | cloudflared | — | Cloudflare Tunnel — the only public ingress |
| **annabel-rene** | Wedding site | `annabel-rene.example.com` | Public static site, served through the tunnel |
| **birthday-bash** | birthday-bash | `jonas.example.com` | Static browser game (nginx), stateless, served through the tunnel |

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
   for d in annabel-rene arr birthday-bash caddy core filebrowser immich jellyfin job-agent seerr utilities vaultwarden; do
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
   for s in arr cloudflared immich jellyfin job-agent navidrome filebrowser seerr vaultwarden utilities annabel-rene birthday-bash; do
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

**Restoring after a drive failure:** see [`RESTORE.md`](RESTORE.md) for the
disaster-recovery runbook — what you must keep off-machine (above all, the
restic repo password), and step-by-step restore commands.

## VPN Leak Monitoring

Every service in the `arr` stack routes through gluetun's network namespace,
so a leak means either that binding came undone or gluetun's kill switch is
not in place. `scripts/vpn-egress-check.sh` verifies both, structurally and
empirically:

```bash
./scripts/vpn-egress-check.sh
```

It checks that gluetun is running, that its `iptables`/`ip6tables` default
policies are `DROP`, that every dependent container really shares gluetun's
netns (`network_mode: service:gluetun` shows up as `container:<id>`), and that
the public IP seen from inside qBittorrent differs from the host's own. Exit 0
means no leak; exit 1 means leaking, or that it could not prove otherwise. A
tunnel that is down but firewalled reports as safe, not as a leak.

Monitoring is the same Healthchecks.io dead-man pattern as backups: the ping
URL goes in `secrets/.vpn-egress.env` (template checked in, no symlink — it is
not a compose stack), and pings are simply skipped if unset. Use a **separate**
check from the backup one so a leak alert is not mistaken for a backup alert.

What it does **not** catch is the few-second window at container start where
gluetun's `ESTABLISHED,RELATED` accept rule lets a connection opened before the
firewall loads survive it (fixed upstream only on `:latest`, after v3.41.1).
What closes that window is `depends_on: gluetun: condition: service_healthy` on
every dependent service — keep it there when adding one. qBittorrent has a
second layer: its `Session\Interface=tun0` binding means it has no socket at
all when the tunnel is absent.

## ROM Library (RomM)

The library lives at `/mnt/storage/data/Games/romm/library` in RomM's
"Structure A" layout — `roms/<platform-slug>/` alongside an optional
`bios/<platform-slug>/`. The folder name **is** the platform: it has to match a
slug from [Supported Platforms](https://docs.romm.app/latest/platforms/supported-platforms/)
(`n64`, `snes`, …) or RomM won't recognise it. Everything else — the scraped
covers, saves, states, `config.yml`, the embedded Valkey, and the MariaDB
data — sits under `/opt/dockerdata/romm/`, so both halves are already inside
autorestic's `my-data` and `docker-data` locations without a config change.

Metadata comes from Hasheous only, which needs no account. Adding
ScreenScraper, IGDB, SteamGridDB or RetroAchievements is a matter of
uncommenting the matching keys in `secrets/.romm.env` and recreating the
container — see the [metadata providers docs](https://docs.romm.app/latest/getting-started/metadata-providers/).

The instance stays on the `*.dev` wildcard (LAN only). Serving a ROM library
through the Cloudflare tunnel would put a copyright-liable, unauthenticated-by-
default surface on the public internet, and large ROM downloads would hit the
free plan's edge limits anyway.

### Syncing to a laptop

RomM ships no first-party Linux desktop client and no WebDAV, so the supported
route is the REST API with a **Client API Token** (Settings → API tokens in the
web UI; read-only scopes are enough, and the token is shown exactly once).
`scripts/romm-pull.sh` runs on the *client*, not on this host — copy it over:

```bash
scp scripts/romm-pull.sh laptop:~/bin/
ssh laptop 'mkdir -p ~/.config/romm && install -m600 /dev/null ~/.config/romm/token'
# paste the rmm_… token into that file, then:
ROMM_URL=https://romm.dev.example.com ~/bin/romm-pull.sh          # whole library
ROMM_URL=https://romm.dev.example.com ~/bin/romm-pull.sh n64      # one platform
```

It mirrors into `~/roms/<platform-slug>/` (override with `ROMM_DEST`) and is
incremental: a ROM is skipped when the local file already matches the size RomM
reports, so a re-run after a truncated download repairs it. `ROMM_DRY_RUN=1`
lists what would be pulled without touching the disk. Multi-file ROMs arrive as
a zip whose size can't be compared to the source, so those are skipped on mere
existence — delete the local zip to force a re-pull.

For other clients: **Playnite plugin** on Windows, **Argosy** on Android,
**Grout** on muOS/NextUI handhelds — all first-party, all authenticating with
the same kind of token. See [First-Party Apps](https://docs.romm.app/latest/ecosystem/first-party-apps/).

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
- The VPN leak check lives in **tim's** crontab (`crontab -e`, no sudo — it
  only needs docker-group access) and calls `scripts/vpn-egress-check.sh`
  every 10 minutes, appending to `~/logs/vpn-egress-check.log`:
  ```cron
  */10 * * * * /home/tim/coding/homelab/scripts/vpn-egress-check.sh >> /home/tim/logs/vpn-egress-check.log 2>&1
  ```
  At 144 runs/day that log grows ~35 MB/year, so it is rotated like the backup
  one via `/etc/logrotate.d/vpn-egress-check` (needs sudo once):
  ```
  /home/tim/logs/vpn-egress-check.log {
      monthly
      rotate 3
      compress
      missingok
      notifempty
      copytruncate
  }
  ```

### Mounts
- `/mnt/storage` is mounted at boot via `/etc/fstab` (UUID entry with
  `defaults,nofail`). The backup HDD is *not* in fstab — the backup script
  mounts it only for the duration of a run.
