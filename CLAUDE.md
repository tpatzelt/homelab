# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Personal homelab infrastructure-as-config: a set of Docker Compose stacks fronted by Caddy, running on a single Acer Veriton host. There is no application source code or build step — changes are almost entirely to `compose.yaml` files, the Caddyfile, and env files.

**This repo is public.** The real domain is deliberately kept out of tracked files: the Caddyfile uses `{$DOMAIN}` env placeholders (substituted by Caddy at parse time from `DOMAIN` in `secrets/.caddy.env`), compose files interpolate `${DOMAIN}`/`${…_URL}` vars from their env files, and the cloudflared tunnel config lives outside the repo at `/opt/dockerdata/cloudflared/config.yml` (carries the tunnel UUID + real hostnames; `compose/cloudflared/config.yml.example` is the tracked template). When editing, never write the real domain, LAN IPs, or any secret value into a tracked file — docs use `example.com` as the stand-in. Internal services are `<name>.dev.<domain>`, public ones `<name>.<domain>`.

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

Startup order matters because of shared external networks and reverse-proxy dependencies: `caddy` → `core` → other stacks. `caddy_network` and `public_network` (both external, bridge) must exist before any stack is started (`docker network create caddy_network; docker network create public_network`). `scripts/restart-services.sh` creates them if missing and walks every stack in that order, and does **`pull` → `down` → `up -d` per stack** — pulling *before* the teardown is deliberate: pihole (in `core`) is the LAN's own DNS, so a `down` that removes pihole while its replacement image still needs pulling deadlocks the pull on the DNS it just killed (this happened during the 2026-07 redeploy). With images already local, the only window pihole is down carries no network dependency; `set -e` also aborts before a `down` if that stack's pull fails. Defense-in-depth against the same deadlock lives at the host DNS layer (see below).

`restart-services.sh` refuses to run unless this tree is on `main` with no uncommitted changes to tracked files, because the deploy tree is also the work tree and a redeploy from a stale branch rolls back image bumps and drops routes. Override on purpose with `--force` or `ALLOW_DIRTY_DEPLOY=1`. It skips any stack carrying a gitignored `compose/<stack>/.disabled` marker (see the arr stack below). For anything short of a full redeploy, change one stack or one service at a time; never `down` the whole `core` stack to change one service, because Pi-hole is in it.

After editing `compose/caddy/Caddyfile`, **force-recreate** the `caddy` container (it's mounted, not baked into the image):
```bash
docker compose -f compose/caddy/compose.yaml up -d --force-recreate caddy
```

`caddy reload` and `docker restart` are **not** enough if the editor wrote the file atomically (write-temp-then-rename — most editors, `sed -i`, and Claude Code's Edit/Write tools all do this). Docker resolves a single-file bind mount to an *inode* at container-create time, so the rename leaves the container serving the old file. `caddy reload` then exits 0 and logs `adapted config to JSON` while re-reading the stale config — the failure is completely silent, and only shows up as the catch-all `abort` closing connections on the route you thought you just added.

Check for it with:
```bash
diff <(docker exec caddy cat /etc/caddy/Caddyfile) compose/caddy/Caddyfile
```
Only reach for `caddy reload` when the file was edited in place (e.g. a shell append). The same trap applies to every other single-file bind mount — the remaining one is `compose/caddy/Caddyfile`. cloudflared's `config.yml` used to be a single-file bind and hit the worse *missing*-source variant of this trap (Docker silently creates an empty **directory** when the bind source doesn't exist, and a running container keeps the deleted inode open so the rot only surfaces on the next recreate). It now lives under `/opt/dockerdata` and is mounted as a **directory** (`/opt/dockerdata/cloudflared` → `/etc/cloudflared`), which sidesteps the missing-file-becomes-directory failure and puts it inside autorestic's backup. `check.sh`'s "required host files present" check asserts `config.yml` and `creds.json` exist as regular files so a missing one fails validation instead of a redeploy.

Validation is automated: run `./scripts/check.sh` after any compose/Caddyfile/env-template change. It works offline against dummy env files generated from `secrets/*.env.example` and checks: `docker compose config` on every stack, env-template completeness, `caddy validate`, Caddyfile-upstream/compose consistency (gluetun-aware, and network-aware: an upstream must share a network with Caddy, and only Caddy and blackbox-exporter may sit on both `caddy_network` and `public_network`), a blackbox probe line for every Caddy upstream, autorestic `LOCATIONS` sync, per-stack env-example presence, README service-table coverage, shellcheck, yamllint (config in `.yamllint`), a warn-only image-pinning report, and a warn-only **image-drift** gate. The drift gate compares each *running* container's image against the tag its `compose.yaml` declares — it exists because nine merged Renovate bumps once sat undeployed with nothing to surface the gap. It is host-only and self-skipping: CI stages the stacks offline with no docker daemon, so it prints `skipped` there rather than failing the build. CI (`.github/workflows/check.yml`) runs the same script on push/PR.

## Architecture

### Stacks (`compose/<name>/compose.yaml`)
- **caddy** — reverse proxy (custom-built image with Cloudflare DNS + CrowdSec bouncer plugins, see `compose/caddy/Dockerfile`), plus `crowdsec` (intrusion detection feeding the Caddy bouncer). This is the only stack that binds host ports 80/443. Caddy is on both `caddy_network` and `public_network`.
  - The client address comes from `Cf-Connecting-Ip` (`client_ip_headers` plus `trusted_proxies_strict` in the `servers` block). Cloudflare overwrites that header, whereas it only appends to `X-Forwarded-For`, so before 2026-11-16 a visitor could pick their own `client_ip` with one header and walk past a CrowdSec ban.
- **core** — dozzle (log viewer) with its socket proxy, pihole (DNS), pihole-exporter, homepage (dashboard at `home.dev`).
  - dozzle has no docker socket. It talks to `dozzle-socket-proxy` (wollomatic/socket-proxy) over `dozzle_socket`, an internal network only the two share. The proxy allows GET on ping, version, info, events, the container list and per-container inspect, logs and stats, and answers everything else with 403/405, so no start, stop, exec or file read. A `:ro` socket mount alone would not do this: read-only applies to the socket file, not to the API calls sent through it. `DOZZLE_ENABLE_SHELL` and `DOZZLE_ENABLE_ACTIONS` are off. The proxy runs as `65534:${DOCKER_GID}`; `DOCKER_GID` in `secrets/.core.env` must match `getent group docker`. Dozzle's disk-usage figure (`/system/df`) is blocked on purpose.
  - The `basic_auth` block on dozzle's Caddy route stays. Dozzle ships no auth of its own, `*.dev` resolves LAN-wide, and container logs carry tokens and personal data. The credential lives in `secrets/.caddy.env` as `DOZZLE_AUTH_USER`/`DOZZLE_AUTH_HASH`; regenerate with `docker exec caddy caddy hash-password --plaintext '<pw>'`.
  - homepage's whole configuration is the YAML in `compose/core/homepage/`, mounted read-only as a directory. Tiles are static entries: `href` uses `{{HOMEPAGE_VAR_DOMAIN}}` so the real domain stays out of the repo, and `siteMonitor` polls the same container address Caddy proxies to. The public sites are monitored through their public URL, because homepage is not on `public_network`. It has no docker socket and no `env_file`. It runs as `${PUID}:${PGID}` with `LOG_TARGETS=stdout`, so it writes nothing into the repo directory, and every file Homepage expects is present (some only as a comment) so it never tries to create one. `HOMEPAGE_ALLOWED_HOSTS` lists its Caddy host name and `homepage:3000` (the blackbox probe); any other Host header gets a 400. A new Caddy route needs a tile in `services.yaml` by hand; nothing checks that. App widgets (Pi-hole, Immich, the *arr apps, Jellyfin) are left out because each needs an API key; add them one at a time with the key in `secrets/.core.env` as `HOMEPAGE_VAR_<NAME>_KEY`.
- **monitoring** — Prometheus + Grafana (`grafana.dev`), fed by cAdvisor (containers), node-exporter (host), blackbox-exporter (one HTTP probe per service; it joins both `caddy_network` and `public_network` to reach them), and the `/metrics` of caddy (`:2020`, a dedicated unpublished listener — *not* the admin API on `:2019`), crowdsec (`:6060`) and cloudflared (`:2000`, relayed by Caddy at `caddy:2020/cloudflared/metrics` because cloudflared and Prometheus share no network).
  - **The probe list in `prometheus/prometheus.yml` is hand-kept in step with the Caddyfile.** A new route without a probe line never appears on the Overview dashboard, so `check.sh` fails when a Caddy upstream has no probe with the same `host:port`. Probe the same upstream Caddy proxies to (`gluetun:<port>` for the *arr apps).
  - node-exporter runs with `network_mode: host` (so NIC counters are the host's, not a netns's) but listens on **`172.17.0.1:9100` only** — docker0's address — so the LAN cannot scrape it; Prometheus reaches it as `host.docker.internal` via `extra_hosts: host-gateway`. If Docker's default bridge is ever renumbered, both must move together.
  - Prometheus and Grafana run as `${PUID}:${PGID}` because `/opt/dockerdata` is tim-/dockerdata-group writable; their image-default users cannot write there. Prometheus's TSDB (`/opt/dockerdata/prometheus`, 30d / 5 GB cap) is excluded from autorestic — it is history, not state. Grafana's DB is backed up; its dashboards are provisioned read-only from `grafana/dashboards/*.json`.
  - The weekly backup stops every container, so Thursdays ~03:00 UTC show as a short all-services-down band on the availability timeline. That is expected, not an outage.
  - App-level exporters for the **Media & Apps** dashboard live in the stack whose config/secrets they need, not in monitoring: `sonarr-/radarr-/prowlarr-exporter` (exportarr) in **arr**, reading each app's API key from its `config.xml` mounted read-only, and `pihole-exporter` in **core**, interpolating core's Pi-hole password. ekofr/pihole-exporter v1.2.0 (the latest release) wedges until restart after any collection overruns 10s. The image is `FROM scratch`, so it can't carry a compose healthcheck. Its defenses are `TIMEOUT: 2s` in compose and the `scripts/pihole-exporter-watchdog.sh` cron job (tim's crontab, every 2m), which restarts it when Prometheus's `up` for the job stays at 0. Navidrome serves its own `/metrics` (`ND_PROMETHEUS_ENABLED`). Lidarr has no exporter yet: it was left out while it ran a 2021 build whose API 500'd on `/artist` and `/history`, and that reason went away with the 2026-10-10 upgrade to 3.x. Immich telemetry was tried and dropped — ~2.3k series of DB-call timings and no asset counts. The `arr` scrape job runs every 2m, so rate/increase panels over it need a fixed window, not `$__rate_interval`.
  - Alerting is Grafana-managed and provisioned from `grafana/provisioning/alerting/` (rules, e-mail contact point, policy). Recipient and SMTP credentials come from `GF_SMTP_*` / `ALERT_EMAIL` in `secrets/.monitoring.env`. A catch-all child route mutes the Thursday backup window (Grafana refuses mute timings on the root route). Rule templates use `index .Labels "x"` because provisioning expands `$`-variables as env vars.
  - **Claude Code usage is pushed, not scraped.** Prometheus runs its OTLP receiver (`--web.enable-otlp-receiver`), published on `127.0.0.1:9090` only, and the host's Claude Code CLI pushes to `/api/v1/otlp/v1/metrics` via the `env` block in `~/.claude/settings.json` (outside this repo: `CLAUDE_CODE_ENABLE_TELEMETRY=1`, `OTEL_METRICS_EXPORTER=otlp`, `OTEL_EXPORTER_OTLP_METRICS_PROTOCOL=http/protobuf`, `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`, and **`OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative`**, because the receiver rejects Claude Code's default delta). Each session is its own series (`session_id`), so the dashboard must use `increase(...[r] anchored)`. Plain `increase()` drops one-push sessions and inflates short ones by up to 50%. Sessions inside containers do not report unless given the same env and a reachable endpoint. The series carry `user_email` as a label.
  - **Directory binds can go stale too.** If a mounted directory is deleted and recreated (e.g. by a checkout or a tool that rewrites the tree), the container keeps the old, now-empty inode: `docker exec prometheus ls /etc/prometheus` comes back empty while the process runs on its startup config, and the next reload or restart fails. After touching `compose/monitoring/` wholesale, check that listing and `--force-recreate` prometheus/blackbox-exporter/grafana if it is empty. The same applies to `compose/core/homepage/` (check `docker exec homepage ls /app/config`).
- **arr** — **parked since 2026-11-21: the AirVPN subscription ended.** `scripts/arr-stack.sh down|up|status` is the only switch. `down` stops the stack, writes the gitignored `compose/arr/.disabled` marker (so `restart-services.sh` skips it instead of hanging on gluetun's healthcheck), comments out the `vpn-egress-check.sh` cron line, pauses its Healthchecks.io check when `HEALTHCHECKS_API_KEY` is in `secrets/.vpn-egress.env` (otherwise that pause is manual, in the UI), and adds two year-long Grafana silences (`stack=arr`, `job=arr`) tagged `arr-stack.sh: stack parked`. `up` waits for the stack to turn healthy, runs the leak check once (its ping un-pauses the Healthchecks.io check), then restores the cron line and expires the silences. If either step fails, monitoring stays silenced. Nothing tracked changes, so the Caddy routes, probes and homepage tiles stay and show the apps as down. Seerr loses its Sonarr/Radarr links meanwhile. Jellyfin does not depend on the stack.
  - `gluetun` (VPN, AirVPN/Netherlands) plus qbittorrent/sonarr/radarr/lidarr/bazarr/prowlarr, all attached via `network_mode: service:gluetun` so their traffic routes through the VPN tunnel. Only `gluetun` itself joins `caddy_network`, so Caddy reverse-proxies to `gluetun:<port>` for every *arr service, not to the service's own container name.
  - The `depends_on: gluetun: condition: service_healthy` on **every** dependent service is load-bearing anti-leak config, not startup cosmetics — do not drop it when adding a service. gluetun's firewall accepts `ESTABLISHED,RELATED`, so a connection opened in the ~10ms before the firewall loads keeps flowing over `eth0` (the host's real IP) for its lifetime. Gating every container on *healthy* means none of them can race that window. Upstream's conntrack-flush fix (commit `625a63e`, 2026-02-23) is not in any tagged release — it landed after v3.41.1 and exists only on `:latest`, which is gluetun's dev tag and not worth taking for a window this setup already closes.
  - gluetun's control server is bound to `127.0.0.1:8000` (`HTTP_CONTROL_SERVER_ADDRESS` in compose). Its legacy routes need no authentication and include one that stops the VPN, and nothing here uses it, so it is not reachable from `caddy_network`.
  - Changing gluetun's environment recreates gluetun, and every container sharing its network namespace must be recreated with it. Do it with one `up -d` of the whole arr stack, then confirm the six apps answer on `gluetun:<port>` and `scripts/vpn-egress-check.sh` passes.
  - gluetun publishes **no** host ports. It used to publish 8888/tcp (HTTP proxy) and 8388/tcp+udp (Shadowsocks) on `0.0.0.0` for services that are both disabled in its config (`HTTPPROXY` empty, `SHADOWSOCKS=off`) — LAN-facing surface that forwarded to nothing. If a proxy is ever wanted, re-add the port **and** enable it in `.arr.env`; a published port alone does nothing. The *arr web UIs are unaffected either way: Caddy reaches them over `caddy_network`, not via published host ports.
  - qbittorrent additionally pins `Session\Interface=tun0` in its config — with no `tun0` it has no socket to bind, independent of iptables. The other five are *not* interface-bound and rely entirely on the `depends_on` above.
  - gluetun was on the floating `qmcgaw/gluetun:v3` major tag until 2026-07-24; it is now pinned like everything else. A floating major slips past both Renovate (the tag never goes stale, so no PR is ever opened) and `check.sh`'s pinning report (which only flags `latest`/untagged) — while `restart-services.sh`'s per-stack `pull` silently upgrades it on the next redeploy. That is the path by which a regressed release reaches the container guarding the real IP.
- **cloudflared** — a locally-managed Cloudflare Tunnel (ingress rules in `/opt/dockerdata/cloudflared/config.yml`, kept out of the repo because it carries the tunnel UUID and real hostnames — `compose/cloudflared/config.yml.example` is the tracked template; credential alongside it at `/opt/dockerdata/cloudflared/creds.json`, both mounted via the single directory bind `/opt/dockerdata/cloudflared` → `/etc/cloudflared`). This is the only way anything in this homelab is reachable from the internet; no router ports are forwarded. It deliberately proxies to `https://caddy:443` rather than straight to an app container, so tunnelled traffic still passes CrowdSec, the security headers, and the access log. It is on `public_network` only. It has no `.env` — a locally-managed tunnel carries no env-var secrets, so it intentionally skips the `secrets/` symlink convention below.
- **homeassistant** — Home Assistant at `homeassistant.dev`, with `network_mode: host`, because discovery (mDNS, SSDP, Cast) needs the host's interfaces. Caddy, blackbox-exporter and homepage reach it as `host.docker.internal:8123` through `extra_hosts: host-gateway`. `check.sh` accepts that upstream only if Caddy carries the extra_hosts entry and some service runs on the host network. It also answers on `<lan-ip>:8123` directly, outside Caddy's LAN guard. That is still LAN-only, and HA has its own login.
  - **The reverse-proxy trust lives in `/opt/dockerdata/homeassistant/.storage/http`, not in YAML.** Recent HA imports an `http:` block from `configuration.yaml` once, on first boot (`yaml_migration_done`), and ignores it afterwards. The live settings are `use_x_forwarded_for: true` and `trusted_proxies: ["172.16.0.0/12"]`. Without them every request through Caddy gets a 400 and the log says "not set-up for reverse proxies". To change the settings, stop the container and edit the JSON. The files are root-owned, so do it from a one-off container. A restored or wiped config dir needs them again.
  - Runs as root (s6 init). No Bluetooth: the host has no adapter.
- **immich**, **jellyfin**, **navidrome**, **filebrowser**, **seerr**, **vaultwarden**, **utilities** (karakeep + ip-tracker), **job-agent** — standalone internal stacks on `caddy_network`.
  - filebrowser mounts `/mnt/storage/data` read-write with a read-only mount of `/mnt/storage/data/Immich` laid over it, so Immich's library can be browsed but not renamed or deleted from the file manager.
  - job-agent still runs as root. Its image has no non-root user, and as uid 1000 it fails at import (uv's cache under `/`, botasaurus writing into `site-packages`). The fix belongs in the app's Dockerfile.
- **annabel-rene**, **birthday-bash**, **pendel**, **bikes**, **reel-recipes** — the five public sites, on `public_network` only. `bikes` rebuilds its whole site before it starts listening, so a restart of that container takes it offline for up to half an hour; do not recreate it casually.
- **isponsorblocktv** — [iSponsorBlockTV](https://github.com/dmunozv04/iSponsorBlockTV), which pairs with YouTube TV apps as a "Link with TV code" remote and skips SponsorBlock segments / mutes-and-skips ads. Outbound-only (YouTube lounge API + SponsorBlock API): no UI, no listener, so no Caddy route, no `caddy_network` and no blackbox probe — nothing on the Overview dashboard will show it; check `docker logs isponsorblocktv`. The pairing lives in `/opt/dockerdata/isponsorblocktv/config.json` (inside autorestic's backup), created by an interactive one-off run, not by the service: `docker compose -f compose/isponsorblocktv/compose.yaml run --rm isponsorblocktv --setup` (TUI; `--setup-cli` for plain prompts), then `up -d`. Pair by TV code (YouTube app → Settings → Link with TV code); auto-discovery would need `--network host` on that run and is not worth it. Re-run setup to add a device or after a TV app reset unpairs it.

### Networking
Three Docker networks tie everything together:
- `caddy_network` (external, created once) — internal services reachable behind Caddy attach here.
- `public_network` (external, created once) — cloudflared and the five public sites (`annabel-rene-frontend`, `birthday-bash`, `pendel-web`, `bikes`, `reel-recipes`). A compromised public site can reach Caddy, cloudflared, blackbox-exporter and the other public sites, and nothing internal: from inside one, `dozzle`, `vaultwarden` and `nightshift-web` neither resolve nor connect. A new public site goes here, never on `caddy_network`.
- `gluetun_network` (defined in `arr`, subnet `172.60.0.0/24`) — VPN-routed *arr services live behind this; `gluetun` bridges it to `caddy_network`.

Only Caddy and blackbox-exporter are on both `caddy_network` and `public_network`; `check.sh` fails if anything else is. Prometheus stays off `public_network`, which is why cloudflared's metrics are relayed through `caddy:2020`. blackbox-exporter is therefore reachable from the public sites on `:9115`. It returns probe results, not response bodies, but it will probe internal addresses for whoever asks.

Routing in `compose/caddy/Caddyfile` is host-matcher based against a wildcard cert: `*.dev.{$DOMAIN}` for internal services, `*.{$DOMAIN}` for the public domain. Every block ends in a catch-all `abort`. CrowdSec is wired in globally (`order crowdsec first`, `route { crowdsec }`) and access logs go to `/var/log/caddy/wildcard-access.log`, which `crowdsec`'s log-based scenarios read.

**The `*.dev` block is LAN-only by source address, not just by DNS.** Its first `handle` aborts every connection whose `remote_ip` is outside `192.168.0.0/16`. Caddy sees LAN clients with their real address (HTTP/2 and HTTP/3 alike) and every container, cloudflared included, with a Docker bridge address in `172.16.0.0/12`; that was checked against live traffic on 2026-11-16. Consequences to remember:
- A container cannot call a `*.dev` name. Configure app-to-app links with the container address (`http://jellyfin:8096`, `http://gluetun:8989`), never the `*.dev` URL.
- On the host itself, `curl https://x.dev.<domain>` works (it leaves from the LAN address), but `--resolve …:127.0.0.1` is refused, because loopback traffic reaches Caddy from the bridge gateway.
- The guard must stay a `handle` and stay first. A bare `abort @outside` is ordered after the `handle` blocks by Caddy's directive order and never runs.
- If the LAN is ever renumbered out of `192.168.0.0/16`, or a VPN hands out other addresses, every internal UI goes dark until the matcher is updated.

A Caddyfile route existing does **not** mean a host is reachable — DNS decides that, and the two wildcards resolve very differently:
- `*.dev.<domain>` is a wildcard A record to the host's LAN IP, so it only works from inside the LAN.
- `*.<domain>` has **no** wildcard record. Only the five public sites' hostnames exist publicly, as proxied CNAMEs to the tunnel — a `handle` in the public block does nothing until a DNS record exists.

To expose a new public host: add an ingress rule in `/opt/dockerdata/cloudflared/config.yml`, a `handle` block in the `*.{$DOMAIN}` Caddy block, a probe line in `prometheus.yml`, put the container on `public_network`, and run `cloudflared tunnel route dns homelab <host>`. Two constraints to respect — Cloudflare's ToS §2.8 forbids proxying video streaming over the free CDN (so Jellyfin must not go through the tunnel), and the free plan rejects request bodies over 100 MB at the edge, before they ever reach Caddy or any log.

Client IPs survive the tunnel: cloudflared appears only as `remote_ip` in the access log, while `client_ip` holds the real visitor (Caddy takes it from `Cf-Connecting-Ip`, trusted because cloudflared connects from a private range: `trusted_proxies static private_ranges`). CrowdSec's `caddy-logs` parser reads `client_ip`, so bans land on real clients rather than on the tunnel container.

### Host DNS (self-resolution safety)
pihole runs *on this host* and is the LAN's only resolver, so the host resolving through itself would hard-fail during a pihole outage — the deadlock behind the 2026-07 redeploy incident. A netplan drop-in at `/etc/netplan/99-dns-fallback.yaml` (kept out of the repo because it carries the host's LAN IP; a placeholder-IP copy of the same content is documented here) keeps DHCP for the address but pins DNS to a static list — pihole first (ad-blocking preserved for the host too), then `1.1.1.1` as automatic failover:

```yaml
network:
  version: 2
  ethernets:
    enp1s0f0:            # the host's NIC; confirm against 50-cloud-init.yaml
      dhcp4-overrides:
        use-dns: false   # ignore the pihole address DHCP hands out; use the list below
      nameservers:
        addresses: [<pihole-lan-ip>, 1.1.1.1]
```

Apply with `sudo netplan apply` (safe headless — only DNS changes, the IP/route still come from DHCP so connectivity can't drop); verify with `resolvectl status` showing both servers on the link. This is defense-in-depth *in addition to* `restart-services.sh` pulling before it tears anything down; either alone prevents the deadlock.

### Secrets and env files
Real env files live in `secrets/*.env` (gitignored) and each `compose/<name>/.env` is a **symlink** into `secrets/`, e.g. `compose/caddy/.env -> ../../secrets/.caddy.env`. `secrets/*.env.example` are the checked-in templates — when adding a new stack, add both the example and wire up the symlink. Note the `navidrome` stack's secret is named `.navidrom.env` (typo, kept for consistency with the existing symlink — don't silently "fix" it without repointing the symlink too). `secrets/.autorestic.env` (restic password) is sourced by `autorestic/autorestic.sh` rather than a compose stack, so it has an example but no symlink; `secrets/.vpn-egress.env` (Healthchecks URL for `scripts/vpn-egress-check.sh`) follows the same no-symlink pattern and is entirely optional — without it the check still fails on a leak, it just reports nowhere. The `annabel-rene` stack uses compose interpolation (`${VAR}` from the auto-loaded `./.env`) instead of `env_file:` so only the referenced vars reach the container.

### Persistent data & backups
All service state lives under `/opt/dockerdata/<service>/`; media/user data lives under `/mnt/storage`; backups land on `/mnt/backup`. Backups are automated via `autorestic` (`autorestic/.autorestic.yml`), which snapshots `/mnt/storage/data`, `/opt/dockerdata`, and `secrets/` to a local restic repo. Root's crontab runs `autorestic/autorestic.sh` weekly (Thu 03:00 UTC, output appended to `/var/log/autorestic.log`, rotated via `/etc/logrotate.d/autorestic`); the script mounts the backup HDD on demand (by label: `/dev/disk/by-label/backup`) and unmounts afterwards, so an empty `/mnt/backup` between runs is normal — don't "fix" it. The `docker-data` location's backup hook stops all running containers except `pihole` before snapshotting and restarts them after — keep this in mind if changing container names, since the hook does a `docker ps` name-grep exclude.

Backup monitoring is a Healthchecks.io dead-man switch: the script pings `$HEALTHCHECKS_URL` (from `secrets/.autorestic.env`) on start, success, and failure, and Healthchecks alerts if a weekly ping goes missing. After each backup the script independently verifies that every location produced a snapshot dated today and treats a missing snapshot as failure — the `LOCATIONS` list in `autorestic.sh` must be kept in sync with the location names in `.autorestic.yml`. Note that autorestic does **not** auto-initialize a fresh repo: on a brand-new/wiped backup disk, `restic init` must be run manually once (with `RESTIC_REPOSITORY=/mnt/backup/restic-backups` and the password from `secrets/.autorestic.env`) — a failed run due to a missing repo is the intended alert, not something the weekly script should self-heal. The repo was wiped and re-initialized 2026-07-12 after ~6 months of silent failures (unexported/mangled `RESTIC_PASSWORD`, no cron log); restore was last tested end-to-end the same day.

### Host monitoring

`smartd` watches `/dev/sda` (boot SSD) and `/dev/sdc` (backup HDD) with nightly short
self-tests and a weekly long test on sda; alerts run `/usr/local/sbin/smartd-notify`,
which logs to `/var/log/smartd-alerts.log` and pings the Healthchecks URL in
`/etc/smartd-notify.url`. A daily `disk-health-heartbeat.timer` pings the same check on
success, so it degrades into a dead-man switch — a silently dead smartd goes red rather
than looking identical to healthy disks.

**`/dev/sdb` is deliberately absent from `smartd.conf`.** It is the 4 TB Seagate
"Expansion Portable" (USB `0bc2:231a`, `uas` driver) holding `/mnt/storage` — i.e. all the
user data. The bridge **does not implement ATA passthrough**: every real variant
(`auto`, `sat`, `sat,12`, `sat,16`, `usbcypress`, `usbprolific`, `usbsunplus`,
`sntjmicron`, …) fails with `scsi error unsupported field in scsi command`, and
`-T permissive` confirms IDENTIFY words 82-87 come back empty. `-d sat,auto` and
`-d scsi` *appear* to work but only reach SCSI INQUIRY — they return identity while
reporting `SMART support is: Unavailable`, which is easy to misread as success. Do not
"fix" this by adding one of those to `smartd.conf`; it would produce a check that runs
happily and tells you nothing. Verified exhaustively 2026-08-25.

Because there is no SMART, `sdb` is monitored indirectly by
`/usr/local/sbin/disk-health-heartbeat`: ext4's `errors_count`
(`/sys/fs/ext4/sdb2/errors_count`), the superblock's `Filesystem state`, kernel I/O /
`uas_eh` / `task abort` traces from the last 24 h, and the age of the last fsck. This is a
genuinely weaker signal than SMART — there is no reallocated- or pending-sector early
warning, so it reports damage that has already happened rather than predicting it. It is
what the enclosure allows. Re-probe if the enclosure is ever swapped; a different bridge
may well support SAT.

Note `sdb2` is a plain partition, not LVM, so `e2scrub` cannot check it online — the
`e2scrub_all.timer` silently skips it. `Maximum mount count` is `-1` and the last fsck was
2025-11-15, so **nothing forces a filesystem check on the 4 TB data disk**. A check
requires unmounting `/mnt/storage`, which means stopping most containers.

Docker's default log driver is capped in `/etc/docker/daemon.json` (`max-size 10m`,
`max-file 3`) — this applies at container *create* time, so a bare `docker restart` will
not pick it up; a `restart-services.sh` pass will. `journald` is capped at 500M.
A `docker-prune.timer` runs monthly; it deliberately uses `docker system prune -f`
**without** `-a` (see the note on unpullable images below).

### Images that can no longer be pulled

`gcr.io/zenika-hub/alpine-chrome:124`, karakeep's old browser sidecar, **404/403s on pull**,
because the upstream GCR project has billing disabled. On 2026-10-31 it was replaced with
upstream's maintained `ghcr.io/karakeep-app/karakeep-chrome`. The old image had become a
security problem as well as an unpullable one: it ran a 2024 Chromium with `--no-sandbox`
against arbitrary bookmarked pages. Nothing in the repo uses the old image any more. The
monthly prune still omits `-a` so that any future unpullable image stays protected.

## Conventions (from prior project instructions)
- Service names: lowercase with hyphens (`immich-server`, not `immich_server`).
- Persistent volumes always mount to an absolute host path under `/opt/dockerdata/<service>`.
- Env vars via `env_file: ./.env`, backed by the `secrets/` symlink pattern above — never hardcode secrets into a `compose.yaml`.
  - **Compose v2 interpolates `env_file` values**, so any `$` in a secret must be written `$$`. A bcrypt hash is the common casualty: an unescaped `$2a$14$XXXX` silently becomes `$2a$14` with the rest eaten as an undefined variable, and Caddy then rejects every valid login with a 401 while logging nothing useful. Check what actually arrived with `docker exec <ctr> printenv <VAR>` rather than trusting the file.
- Pin image versions (e.g. `image:1.2.3`, or `image@sha256:…` for digest-pinned ones) — never `:latest`. Every image is pinned; the sole exception is the owner's personal `ghcr.io/tpatzelt/*` images, which are deployed by their own pipelines and intentionally track a rolling tag. Version bumps arrive as [Renovate](https://docs.renovatebot.com/) PRs (config in `.github/renovate.json5`), CI-validated at config level (not runtime), so hand-editing a tag is rarely needed — `renovate.json5`'s ignore list is the source of truth for what is intentionally unpinned.
  - A tag can *look* pinned and still go stale silently, in two opposite ways. A floating major (gluetun's old `v3`) never goes stale, so Renovate opens no PR while `restart-services.sh`'s per-stack `pull` upgrades it anyway. A tag Renovate cannot parse as a version is the mirror image: qbittorrent sat on `lscr.io/linuxserver/qbittorrent:20.04.1` — a 2021 LinuxServer base-OS-style tag — for ~5 years with no PR ever opened, because there is no newer tag in that format to compare against. lidarr's `8.1.2135` was the same trap from the other side: a 2021 build (app version 0.8.1.2135) whose tag Renovate read as v8.1, *above* every real 2.x/3.x release, so it too sat unbumped until 2026-10-10. Both pass `check.sh`'s pinning report, which only flags `latest`/untagged. When adding an image, prefer a tag whose format Renovate can order (`5.2.3`, or `5.2.3-libtorrentv1` — a suffix is kept as a compatibility constraint), and treat "Renovate has never opened a PR for this image" as a smell rather than as stability.
- Keep additions minimal — only add services/config that are essential to a given stack; commented-out service blocks (see `compose/utilities/compose.yaml`) are intentionally disabled, not dead code to delete.
