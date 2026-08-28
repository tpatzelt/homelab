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

Startup order matters because of shared external networks and reverse-proxy dependencies: `caddy` → `core` → other stacks. `caddy_network` (external, bridge) must exist before any other stack is started (`docker network create caddy_network`). `scripts/restart-services.sh` walks every stack in that order, and does **`pull` → `down` → `up -d` per stack** — pulling *before* the teardown is deliberate: pihole (in `core`) is the LAN's own DNS, so a `down` that removes pihole while its replacement image still needs pulling deadlocks the pull on the DNS it just killed (this happened during the 2026-07 redeploy). With images already local, the only window pihole is down carries no network dependency; `set -e` also aborts before a `down` if that stack's pull fails. Defense-in-depth against the same deadlock lives at the host DNS layer (see below).

After editing `compose/caddy/Caddyfile`, **force-recreate** the `caddy` container (it's mounted, not baked into the image):
```bash
docker compose -f compose/caddy/compose.yaml up -d --force-recreate caddy
```

`caddy reload` and `docker restart` are **not** enough if the editor wrote the file atomically (write-temp-then-rename — most editors, `sed -i`, and Claude Code's Edit/Write tools all do this). Docker resolves a single-file bind mount to an *inode* at container-create time, so the rename leaves the container serving the old file. `caddy reload` then exits 0 and logs `adapted config to JSON` while re-reading the stale config — the failure is completely silent, and only shows up as the catch-all `abort` closing connections on the route you thought you just added.

Check for it with:
```bash
diff <(docker exec caddy cat /etc/caddy/Caddyfile) compose/caddy/Caddyfile
```
Only reach for `caddy reload` when the file was edited in place (e.g. a shell append). The same trap applies to every other single-file bind mount — the remaining one is `compose/caddy/Caddyfile`. The two files that used to be single-file binds, cloudflared's `config.yml` and the GeoLite2 DB, were the worse *missing*-source variant of this trap (Docker silently creates an empty **directory** when the bind source doesn't exist, and a running container keeps the deleted inode open so the rot only surfaces on the next recreate). Both have been moved under `/opt/dockerdata` and are now mounted as **directories** (`/opt/dockerdata/cloudflared` → `/etc/cloudflared`, `/opt/dockerdata/caddy/geoip` → `/opt/geoip`), which sidesteps the missing-file-becomes-directory failure and — being under `/opt/dockerdata` — puts both inside autorestic's backup. `check.sh`'s "required host files present" check asserts they exist as regular files so a missing one fails validation instead of a redeploy.

Validation is automated: run `./scripts/check.sh` after any compose/Caddyfile/env-template change. It works offline against dummy env files generated from `secrets/*.env.example` and checks: `docker compose config` on every stack, env-template completeness, `caddy validate`, Caddyfile-upstream/compose consistency (gluetun-aware), autorestic `LOCATIONS` sync, per-stack env-example presence, README service-table coverage, shellcheck, yamllint (config in `.yamllint`), a warn-only image-pinning report, and a warn-only **image-drift** gate. The drift gate compares each *running* container's image against the tag its `compose.yaml` declares — it exists because nine merged Renovate bumps once sat undeployed with nothing to surface the gap. It is host-only and self-skipping: CI stages the stacks offline with no docker daemon, so it prints `skipped` there rather than failing the build. CI (`.github/workflows/check.yml`) runs the same script on push/PR.

## Architecture

### Stacks (`compose/<name>/compose.yaml`)
- **caddy** — reverse proxy (custom-built image with Cloudflare DNS + CrowdSec bouncer plugins, see `compose/caddy/Dockerfile`), plus `goaccess` (log analytics UI) and `crowdsec` (intrusion detection feeding the Caddy bouncer). This is the only stack that binds host ports 80/443.
- **core** — dozzle (log viewer), pihole (DNS), heimdall (dashboard), beszel/beszel-agent (monitoring; the agent runs with `network_mode: host`).
  - dozzle runs with `DOZZLE_ENABLE_SHELL` and `DOZZLE_ENABLE_ACTIONS` against a **read-write** docker socket, so reaching its UI is equivalent to root on the host. It ships no auth of its own and `*.dev` resolves LAN-wide, so the `basic_auth` block on its Caddy route is the only thing gating that — it is load-bearing, not decoration. Do not remove it without turning those two features off first. The credential lives in `secrets/.caddy.env` as `DOZZLE_AUTH_USER`/`DOZZLE_AUTH_HASH`; regenerate with `docker exec caddy caddy hash-password --plaintext '<pw>'`.
- **arr** — `gluetun` (VPN, AirVPN/Netherlands) plus qbittorrent/sonarr/radarr/lidarr/bazarr/prowlarr, all attached via `network_mode: service:gluetun` so their traffic routes through the VPN tunnel. Only `gluetun` itself joins `caddy_network`, so Caddy reverse-proxies to `gluetun:<port>` for every *arr service, not to the service's own container name.
  - The `depends_on: gluetun: condition: service_healthy` on **every** dependent service is load-bearing anti-leak config, not startup cosmetics — do not drop it when adding a service. gluetun's firewall accepts `ESTABLISHED,RELATED`, so a connection opened in the ~10ms before the firewall loads keeps flowing over `eth0` (the host's real IP) for its lifetime. Gating every container on *healthy* means none of them can race that window. Upstream's conntrack-flush fix (commit `625a63e`, 2026-02-23) is not in any tagged release — it landed after v3.41.1 and exists only on `:latest`, which is gluetun's dev tag and not worth taking for a window this setup already closes.
  - gluetun publishes **no** host ports. It used to publish 8888/tcp (HTTP proxy) and 8388/tcp+udp (Shadowsocks) on `0.0.0.0` for services that are both disabled in its config (`HTTPPROXY` empty, `SHADOWSOCKS=off`) — LAN-facing surface that forwarded to nothing. If a proxy is ever wanted, re-add the port **and** enable it in `.arr.env`; a published port alone does nothing. The *arr web UIs are unaffected either way: Caddy reaches them over `caddy_network`, not via published host ports.
  - qbittorrent additionally pins `Session\Interface=tun0` in its config — with no `tun0` it has no socket to bind, independent of iptables. The other five are *not* interface-bound and rely entirely on the `depends_on` above.
  - gluetun was on the floating `qmcgaw/gluetun:v3` major tag until 2026-07-24; it is now pinned like everything else. A floating major slips past both Renovate (the tag never goes stale, so no PR is ever opened) and `check.sh`'s pinning report (which only flags `latest`/untagged) — while `restart-services.sh`'s per-stack `pull` silently upgrades it on the next redeploy. That is the path by which a regressed release reaches the container guarding the real IP.
- **cloudflared** — a locally-managed Cloudflare Tunnel (ingress rules in `/opt/dockerdata/cloudflared/config.yml`, kept out of the repo because it carries the tunnel UUID and real hostnames — `compose/cloudflared/config.yml.example` is the tracked template; credential alongside it at `/opt/dockerdata/cloudflared/creds.json`, both mounted via the single directory bind `/opt/dockerdata/cloudflared` → `/etc/cloudflared`). This is the only way anything in this homelab is reachable from the internet; no router ports are forwarded. It deliberately proxies to `https://caddy:443` rather than straight to an app container, so tunnelled traffic still passes CrowdSec, the security headers, and the access log. It has no `.env` — a locally-managed tunnel carries no env-var secrets, so it intentionally skips the `secrets/` symlink convention below.
- **immich**, **jellyfin**, **navidrome**, **filebrowser**, **seerr**, **vaultwarden**, **utilities** (karakeep + ip-tracker), **annabel-rene** (wedding site) — standalone media/utility stacks.
- **djcc** — a live DJ booth (the app lives at [tpatzelt/djcc](https://github.com/tpatzelt/djcc), checked out at `~/coding/djcc`). Four things about it are unlike the other media stacks:
  - **Pulled, not built — and the publisher is the app's own repo.** `ghcr.io/tpatzelt/djcc:latest` is built by `.github/workflows/publish-ghcr.yml` in the app repo on every push to `main` and gated on its test suite, so a change to djcc reaches this host with a `pull` rather than a hand-run `build`. The rolling `latest` is intentional and is exactly what `renovate.json5`'s `ghcr.io/tpatzelt/*` ignore rule exists for — that list is this repo's source of truth for what is deliberately unpinned. It replaced a local `build.context: ${DJCC_SRC}` on 2026-08-27, which carried the same blind spot as orca's build args (invisible to Renovate, and `check.sh`'s pinning report skips anything with a `build:` key), so the deployed booth silently depended on whatever happened to be in that checkout. Every build also publishes an immutable `sha-<short>`: to roll back, pin one of those in `compose.yaml` instead of `latest`.
  - **The crate is `/mnt/storage/data/Media/musik/dj`, mounted read-only**, and the host-side variable naming it is `DJCC_CRATE_DIR`, *not* `DJCC_MUSIC_DIR`. That is deliberate: `DJCC_MUSIC_DIR` is read by the application itself, and `env_file:` injects every variable in the file into the container — so a host path under that name arrives inside the container, where it does not exist, and the entrypoint aborts with "no crate at …". The compose `environment:` block re-pins `DJCC_MUSIC_DIR=/music` and `DJCC_DATA_DIR=/data` as a second line of defence.
  - **A cold `/data` costs ~25 minutes of startup, and that is why `start_period` is 1800s.** djcc analyses every record once (~14s each for the current 108) and only then binds its port; `docker logs djcc` shows the progress. The result — the analysis index — persists at `/opt/dockerdata/djcc/data`, so this is paid only after a wipe. Warm it without holding the service in `starting` using the profiled one-shot: `docker compose -f compose/djcc/compose.yaml run --rm djcc-scan` (run it with the booth stopped; both write the same index). Beside the index sits a decoded-PCM cache of ~150 MB per record (~16 GB today) — regenerable, so `.autorestic.yml` excludes `/opt/dockerdata/djcc/data/pcm` the same way it excludes orca's dind store.
  - **The DJ needs a credential, and the image needs the `claude` CLI to use it.**
`secrets/.djcc.env` carries `CLAUDE_CODE_OAUTH_TOKEN` (a subscription token from
`claude setup-token`), injected by `env_file`. It is deliberately not an `ANTHROPIC_API_KEY`:
that token is scoped to Claude Code and returns 429 against `/v1/messages`, so djcc drives a
headless `claude -p` with it instead — which is why the image installs Claude Code natively
and sets `HOME=/data/home` for the session that holds the whole set (~140 KB, and it lands
inside autorestic's backup of `/opt/dockerdata` like everything else there). Without the
token the booth still plays; it just stops thinking, and the only sign is the `djcc doctor`
line the entrypoint prints at the top of `docker logs djcc`. That line is the check to run
after any djcc redeploy.
  - There is **no sound card**, so the output backend is `null`: the set renders in realtime and is discarded, and the audio is heard by opening `/stream.mp3` (the "listen" button in the booth UI), which ffmpeg encodes per listener. The booth ships **no authentication** and every control on the page is live, so like dozzle-without-basic-auth it must stay on the LAN-only `*.dev` wildcard — no cloudflared ingress rule.
- **orca** — the [Orca](https://github.com/stablyai/orca) agent development environment, running headless as `orca serve` on port 6768, plus a `docker:dind` sidecar. Several things about this stack are unlike every other one here:
  - **It is built, not pulled.** Upstream ships desktop artifacts only (AppImage/deb/rpm/dmg/exe) — there is no container image. `compose/orca/Dockerfile` installs the official `.deb`, deliberately not the AppImage: the AppImage path in upstream's headless guide needs FUSE (absent in containers, hence their `--appimage-extract` workaround) *and* a hand-maintained list of Electron shared libraries, whereas `apt-get install ./orca.deb` resolves upstream's own dependency set. The version is a **build arg** (`ORCA_VERSION` in `secrets/.orca.env`), not an image tag, so Renovate cannot see it and `check.sh`'s pinning report cannot either — this is a third variant of the silently-stale tag problem described under Conventions. Bump it by hand and rebuild.
  - **One port, two protocols, and the entry point is not `/`.** Port 6768 carries both the runtime WebSocket *and* the browser client, which Orca serves as static HTTP at `/web-index.html` — a single `reverse_proxy orca:6768` covers both, since Caddy upgrades the WebSocket transparently. But a bare GET of `https://orca.dev.<domain>/` is not a usable page: the way in is the **"Web client URL"** line printed at startup, which carries the pairing offer in its URL *fragment*. Recover it any time with `docker logs orca | grep "Web client URL"`. That offer is a device credential plus E2EE key material — it is equivalent to a login, so do not paste it anywhere it gets logged.
  - **`--pairing-address` advertises; it does not bind.** It sets only the endpoint written into the pairing offer. The listener is always `0.0.0.0:6768`, so this must be what the *laptop* can dial (`https://orca.dev.<domain>`, which Orca normalizes to `wss://` and, with no port given, resolves to 443 through Caddy) — never the container name, and never a wildcard like `0.0.0.0`, which Orca refuses to advertise. An offer that looks perfectly valid still fails to connect when the advertised endpoint does not route back to the bound port, and that mismatch is the first thing to check on a pairing failure.
  - **Docker-in-docker, not the host socket.** Agents Orca launches need `docker`. Mounting `/var/run/docker.sock` would make every one of them root-equivalent on the host — the same property that makes dozzle's `basic_auth` load-bearing, but reached by arbitrary agent-authored code rather than by a human at a UI. Instead the stack runs its own privileged `docker:dind` daemon on the stack's private bridge, and `orca` talks to it over TLS on 2376. The consequence to remember: **`CODING_DIR` is bind-mounted at the same path into both containers on purpose.** A `docker run -v $PWD:/app` issued from an Orca terminal is resolved by the *dind* daemon against *dind's* filesystem, so identical paths are the only reason that bind lands on the real files. Changing the mount point in one service and not the other produces empty directories inside built containers, silently.

  - **Electron runs `--no-sandbox`, deliberately.** Chromium's zygote cannot create its sandbox user namespace in a container (`Failed to move to new namespace … Operation not permitted`, then a FATAL in `zygote_host_impl_linux.cc`); Ubuntu 24.04's AppArmor restriction on unprivileged user namespaces reaches into the container, so a setuid `chrome-sandbox` does not rescue it either — which is why the Dockerfile deliberately leaves that helper non-setuid. The only alternative is `seccomp=unconfined` + `apparmor=unconfined` on the container. That would be the worse trade: `--no-sandbox` gives up a renderer-to-container boundary that agent terminals already cross by design, while loosening seccomp gives up the container-to-*host* boundary, which is the one still doing real work. Full reasoning is in `compose/orca/entrypoint.sh`. The flag must precede the subcommand — `orca-ide serve --no-sandbox` is parsed as an argument to `serve` and never reaches Chromium.

  - **Claude Code is the agent, and it is baked into the image.** Orca resolves each agent by name on `PATH`, so an uninstalled one simply never appears in its list — `CLAUDE_CODE_VERSION` (build arg, like `ORCA_VERSION`) pins it, and `--allow-scripts=@anthropic-ai/claude-code` on the `npm install -g` is load-bearing: npm 12 blocks postinstall scripts by default and the platform-native binary is fetched *by* that postinstall, so without the flag the build succeeds and ships a `claude` that exits with "claude native binary not installed". `DISABLE_AUTOUPDATER=1` is set in the compose environment because the updater cannot write root-owned `/usr/local` and would instead migrate the CLI into `~/.local` — inside the persistent home mount, where the migrated copy wins on `PATH` and silently outranks the pin from then on.
    - **Auth is per-container and survives restarts, but not a wiped home.** Log in once with `docker exec -it -u orca orca claude` → `/login` (headless: it prints a URL to open on the laptop and takes the code back); the token lands in `/home/orca/.claude/.credentials.json`, which is on the `/opt/dockerdata/orca/home` bind mount and therefore inside autorestic's backup. Do not copy the host's `~/.claude/.credentials.json` in — the two installs would then share one refresh token and race each other's rotation.
  - **`gh` is how agents reach GitHub, and it is also the git credential helper.** Pinned by `GH_VERSION` (build arg, same blind spot as `ORCA_VERSION` — Renovate and `check.sh`'s pinning report both miss it) and installed from the official release tarball rather than an apt repo, for the same reason as Node. The container has **no SSH key**, so `git_protocol` is set to `https` and a push authenticates purely through `gh auth setup-git`'s credential helper — without that `setup-git` step `gh` itself works fine while every `git push` fails, which is the confusing half of this. Log in with `docker exec -it -u orca orca gh auth login` (device flow: it prints a one-time code to enter on the laptop), then run `docker exec -u orca orca gh auth setup-git`. Both the token and the helper entry land under `/home/orca/.config/gh` and `/home/orca/.gitconfig`, on the persistent home mount and inside autorestic's backup. Deliberately **not** a copy of the host's token: the host PAT carries `admin:org`/`delete_repo`/`workflow`, and this container runs agent-authored code — a container-local token can be revoked without taking the host's `gh` down with it. The device-flow token that results is scoped `gist`/`read:org`/`repo`, i.e. far narrower than the host PAT.
    - **The repos' `origin` remotes are SSH URLs, and the container has no SSH key** — so `gh` and `git ls-remote https://…` both work while `git push` dies with "Host key verification failed". The repos are bind-mounted *from the host*, so their `.git/config` must not be rewritten to HTTPS: that would change the host's own remotes too. The fix is container-local, in `/home/orca/.gitconfig`:
      ```bash
      git config --global --add url."https://github.com/".insteadOf "git@github.com:"
      git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"
      ```
      Note `--add`: `insteadOf` is multi-valued, and a plain `git config` for the second rule silently *overwrites* the first rather than appending. Verify with `git push --dry-run` — an authenticated setup fails on content (`non-fast-forward`), never on `Host key verification failed`.
    - Orca writes its own `SessionStart` hook and status line into `/home/orca/.claude/settings.json` when it detects the CLI; that file appearing is the confirmation that detection worked. Its default launch args for `claude` are `--dangerously-skip-permissions`, which Claude Code refuses to honour as root — another reason the entrypoint drops to the `orca` service account. Git identity for that account lives in `/home/orca/.gitconfig` (untracked, set by hand); without it every agent commit fails.

  Known upstream limitation, tracked as [#9047](https://github.com/stablyai/orca/issues/9047) (open, reconfirmed against `main` on 2026-08-11): the **browser** web client cannot launch agents or terminals in worktrees the serve process owns as its own `local` host — it reports "Local PTYs are unavailable in the web client" or "Couldn't determine which host owns this workspace". The daemon reports those worktrees with `hostId: "local"`, which the web client routes to the browser-local host, where there is no PTY. The **desktop app** paired to the same server is unaffected. Prefer the desktop client on the laptop; treat the browser client as usable for review and orchestration.

### Networking
Two Docker networks tie everything together:
- `caddy_network` (external, created once, referenced by every stack that needs a public route) — services reachable behind Caddy attach here.
- `gluetun_network` (defined in `arr`, subnet `172.60.0.0/24`) — VPN-routed *arr services live behind this; `gluetun` bridges it to `caddy_network`.

Routing in `compose/caddy/Caddyfile` is host-matcher based against a wildcard cert: `*.dev.{$DOMAIN}` for internal services, `*.{$DOMAIN}` for the public domain. Every block ends in a catch-all `abort`. CrowdSec is wired in globally (`order crowdsec first`, `route { crowdsec }`) and access logs go to `/var/log/caddy/wildcard-access.log`, which both `goaccess` and `crowdsec`'s log-based scenarios read.

A Caddyfile route existing does **not** mean a host is reachable — DNS decides that, and the two wildcards resolve very differently:
- `*.dev.<domain>` is a wildcard A record to the host's LAN IP, so it only works from inside the LAN.
- `*.<domain>` has **no** wildcard record. Only the wedding site's hostname exists publicly, as a proxied CNAME to the tunnel — a `handle` in the public block does nothing until a DNS record exists.

To expose a new public host: add an ingress rule in `/opt/dockerdata/cloudflared/config.yml`, a `handle` block in the `*.{$DOMAIN}` Caddy block, and run `cloudflared tunnel route dns homelab <host>`. Two constraints to respect — Cloudflare's ToS §2.8 forbids proxying video streaming over the free CDN (so Jellyfin must not go through the tunnel), and the free plan rejects request bodies over 100 MB at the edge, before they ever reach Caddy or any log.

Client IPs survive the tunnel: cloudflared appears only as `remote_ip` in the access log, while `client_ip` holds the real visitor (Caddy trusts `X-Forwarded-For` via the global `trusted_proxies static private_ranges`). CrowdSec's `caddy-logs` parser reads `client_ip`, so bans land on real clients rather than on the tunnel container.

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
**without** `-a` (see the alpine-chrome note below).

### Images that can no longer be pulled

`gcr.io/zenika-hub/alpine-chrome:124` (karakeep's browser sidecar) **404/403s on pull** —
the upstream GCR project has billing disabled, so the tag is gone for good. The container
runs from a locally cached image that cannot be replaced if it is ever collected. This is
why the monthly prune omits `-a` and why `restart-services.sh` aborts on the `utilities`
stack (its `set -e` correctly stops before the `down`, so nothing breaks — but that stack
must then be deployed per-service, skipping karakeep-chrome). The real fix is to move
karakeep onto a maintained Chrome/Chromium image.

## Conventions (from prior project instructions)
- Service names: lowercase with hyphens (`immich-server`, not `immich_server`).
- Persistent volumes always mount to an absolute host path under `/opt/dockerdata/<service>`.
- Env vars via `env_file: ./.env`, backed by the `secrets/` symlink pattern above — never hardcode secrets into a `compose.yaml`.
  - **Compose v2 interpolates `env_file` values**, so any `$` in a secret must be written `$$`. A bcrypt hash is the common casualty: an unescaped `$2a$14$XXXX` silently becomes `$2a$14` with the rest eaten as an undefined variable, and Caddy then rejects every valid login with a 401 while logging nothing useful. Check what actually arrived with `docker exec <ctr> printenv <VAR>` rather than trusting the file.
- Pin image versions (e.g. `image:1.2.3`, or `image@sha256:…` for digest-pinned ones) — never `:latest`. Every image is pinned; the sole exception is the owner's personal `ghcr.io/tpatzelt/*` images, which are deployed by their own pipelines and intentionally track a rolling tag. Version bumps arrive as [Renovate](https://docs.renovatebot.com/) PRs (config in `.github/renovate.json5`), CI-validated at config level (not runtime), so hand-editing a tag is rarely needed — `renovate.json5`'s ignore list is the source of truth for what is intentionally unpinned.
  - A tag can *look* pinned and still go stale silently, in two opposite ways. A floating major (gluetun's old `v3`) never goes stale, so Renovate opens no PR while `restart-services.sh`'s per-stack `pull` upgrades it anyway. A tag Renovate cannot parse as a version is the mirror image: qbittorrent sat on `lscr.io/linuxserver/qbittorrent:20.04.1` — a 2021 LinuxServer base-OS-style tag — for ~5 years with no PR ever opened, because there is no newer tag in that format to compare against. Both pass `check.sh`'s pinning report, which only flags `latest`/untagged. When adding an image, prefer a tag whose format Renovate can order (`5.2.3`, or `5.2.3-libtorrentv1` — a suffix is kept as a compatibility constraint), and treat "Renovate has never opened a PR for this image" as a smell rather than as stability.
- Keep additions minimal — only add services/config that are essential to a given stack; commented-out service blocks (see `compose/utilities/compose.yaml`) are intentionally disabled, not dead code to delete.
