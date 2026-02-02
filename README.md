# homelab
Minimal, personal homelab configuration managed via Docker Compose.

## Services

| Service | Subdomain | Description |
|---------|-----------|-------------|
| **Core** |||
| Pi-hole | `pihole.tim-boo.com` | Network-wide ad blocking DNS |
| Dozzle | `dozzle.tim-boo.com` | Real-time Docker log viewer |
| Heimdall | `heimdall.tim-boo.com` | Application dashboard |
| Beszel | `beszel.tim-boo.com` | Server monitoring |
| **Media** |||
| Plex | `plex.tim-boo.com` | Media server |
| Sonarr | `sonarr.tim-boo.com` | TV show management |
| Radarr | `radarr.tim-boo.com` | Movie management |
| Lidarr | `lidarr.tim-boo.com` | Music management |
| Bazarr | `bazarr.tim-boo.com` | Subtitle management |
| Prowlarr | `prowlarr.tim-boo.com` | Indexer management |
| Overseerr | `overseerr.tim-boo.com` | Media requests |
| qBittorrent | `qbittorrent.tim-boo.com` | Torrent client (via VPN) |
| **Photos** |||
| Immich | `immich.tim-boo.com` | Photo/video backup (Google Photos alternative) |
| **Utilities** |||
| Vaultwarden | `vaultwarden.tim-boo.com` | Password manager (Bitwarden-compatible) |
| Karakeep | `karakeep.tim-boo.com` | Bookmark manager |
| LibreSpeed | `librespeed.tim-boo.com` | Speed test (disabled) |
| yt-dlp | `ytdlp.tim-boo.com` | Video downloader (disabled) |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                          Internet                                │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                    ┌───────────▼───────────┐
                    │   Caddy (port 443)    │
                    │   Reverse Proxy       │
                    │   Wildcard TLS        │
                    └───────────┬───────────┘
                                │
           ┌────────────────────┼────────────────────┐
           │                    │                    │
   ┌───────▼───────┐    ┌───────▼───────┐    ┌───────▼───────┐
   │ caddy_network │    │gluetun_network│    │   host/other  │
   │               │    │    (VPN)      │    │               │
   │ • Pi-hole     │    │ • qBittorrent │    │ • Beszel-agent│
   │ • Dozzle      │    │ • Sonarr      │    │   (host net)  │
   │ • Heimdall    │    │ • Radarr      │    │               │
   │ • Beszel      │    │ • Lidarr      │    └───────────────┘
   │ • Plex        │    │ • Bazarr      │
   │ • Immich      │    │ • Prowlarr    │
   │ • Vaultwarden │    │ • Overseerr   │
   │ • Karakeep    │    │ • Snowflake   │
   └───────────────┘    └───────────────┘
```

- **caddy_network**: Services exposed via reverse proxy
- **gluetun_network**: Services routed through VPN (AirVPN)
- All persistent data stored under `/opt/dockerdata/`

## Quick Start

1. **Clone and enter directory:**
   ```bash
   cd /home/tim/coding/homelab
   ```

2. **Set up environment files:**
   ```bash
   # Copy example files and edit with your values
   for f in secrets/.*.env.example; do cp "$f" "${f%.example}"; done
   # Then edit each .env file with your credentials
   ```

3. **Create symlinks in compose directories:**
   ```bash
   ln -s ../../secrets/.arr.env compose/arr/.env
   ln -s ../../secrets/.caddy.env compose/caddy/.env
   ln -s ../../secrets/.core.env compose/core/.env
   ln -s ../../secrets/.immich.env compose/immich/.env
   ln -s ../../secrets/.plex.env compose/plex/.env
   ln -s ../../secrets/.utilities.env compose/utilities/.env
   ln -s ../../secrets/.vaultwarden.env compose/vaultwarden/.env
   ```

4. **Create Docker networks:**
   ```bash
   docker network create caddy_network
   ```

5. **Start services (in order):**
   ```bash
   docker compose -f compose/caddy/compose.yaml up -d
   docker compose -f compose/core/compose.yaml up -d
   docker compose -f compose/arr/compose.yaml up -d
   docker compose -f compose/plex/compose.yaml up -d
   docker compose -f compose/immich/compose.yaml up -d
   docker compose -f compose/utilities/compose.yaml up -d
   docker compose -f compose/vaultwarden/compose.yaml up -d
   ```

## Hardware

**Acer Veriton N4640G**
- CPU: Intel Celeron G3900T @ 2.60GHz (2 cores)
- RAM: 32 GB DDR4
- Storage:
  - 232GB SSD (system, LVM)
  - 3.6TB HDD (`/mnt/storage`) - media files
  - 1.8TB HDD (`/mnt/backup`) - autorestic backups

## Backups

Automated backups via [autorestic](https://autorestic.vercel.app/):
- Config: `autorestic/autorestic.yaml`
- Locations backed up:
  - `/mnt/storage/data` - user data
  - `/opt/dockerdata` - service configuration
  - `secrets/` - environment files
- Backup destination: `/mnt/backup`

## Additional Configuration

### Pi-hole Setup
- Edit `/usr/lib/systemd/resolved.conf` and set:
	```
	DNSStubListener=no
	```
- Restart systemd-resolved:
	```bash
	sudo systemctl restart systemd-resolved
	```
- For Fritzbox DHCP DNS: [Pi-hole Fritzbox DHCP Guide](https://docs.pi-hole.net/routers/fritzbox/#distribute-pi-hole-as-dns-server-via-dhcp)

### Cronjobs
- Autorestic backup runs daily via cron
- Edit crontab:
	```bash
	sudo crontab -e
	```

### Mount Volumes on Boot
1. List block devices:
	```bash
	lsblk
	```
2. Get UUIDs:
	```bash
	sudo blkid /dev/sdb2
	```
3. Edit `/etc/fstab`:
	```bash
	sudo nano /etc/fstab
	```
4. Add mount entries:
	```
	UUID=YOUR_STORAGE_UUID /mnt/storage ntfs-3g defaults,nofail,uid=1000,gid=1000,umask=0022 0 0
	UUID=YOUR_BACKUP_UUID  /mnt/backup  ext4   defaults,nofail 0 2
	```
