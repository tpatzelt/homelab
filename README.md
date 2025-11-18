# homelab
Minimal, personal homelab configuration.

## Hardware specs


## Setup
- based on docker compose

### Additional Configuration
- for pihole setup: Set `DNSStubListener=no` in `/usr/lib/systemd/resolved.conf` and then run `systemctl restart systemd-resolved` 
- https://docs.pi-hole.net/routers/fritzbox/#distribute-pi-hole-as-dns-server-via-dhcp
- Setup cronjobs with crontab: `[sudo] crontab -e`
- Cronjob and other scripts are located at `/usr/local/bin` 


To enable mount volumes on boot:
```
# First, get the UUIDs:
sudo blkid /dev/sdb2

sudo nano /etc/fstab
```

Add these lines (replace `YOUR_UUID_HERE` with actual UUIDs from blkid):
```
UUID=YOUR_SDB2_UUID /mnt/storage ntfs-3g defaults,nofail,uid=1000,gid=1000,umask=0022 0 0
```

