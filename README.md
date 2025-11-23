# homelab
Minimal, personal homelab configuration.

## Hardware specs
Acer Veriton N4640G

### CPU
Intel(R) Celeron(R) G3900T @ 2.60GHz (2 cores, 2 threads)

### Memory
32 GB DDR4 RAM

### Storage
- 1x 232GB SSD (system, LVM)
- 1x 3.6TB HDD (`/mnt/storage`)
- 1x 1.8TB HDD (`/mnt/backup`)

### PCI Devices
- Intel HD Graphics 510
- Realtek RTL8111/8168/8211/8411 PCIe Gigabit Ethernet
- Intel 100 Series/C230 Series Chipset (USB, SATA, Audio, etc.)

### USB Devices
- Western Digital My Passport (external drive)
- Seagate Expansion Portable (external drive)


## Setup
- based on docker compose

### Additional Configuration

#### Pi-hole Setup
- Edit `/usr/lib/systemd/resolved.conf` and set:
	```
	DNSStubListener=no
	```
- Restart systemd-resolved:
	```bash
	sudo systemctl restart systemd-resolved
	```
- For Fritzbox DHCP DNS: [Pi-hole Fritzbox DHCP Guide](https://docs.pi-hole.net/routers/fritzbox/#distribute-pi-hole-as-dns-server-via-dhcp)

#### Cronjobs
- Edit crontab:
	```bash
	sudo crontab -e
	```
- Custom scripts are typically located in:
	- `/usr/local/bin`
	- `~/.local/bin`

#### Mount Volumes on Boot
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
4. Add the following line (replace `YOUR_UUID_HERE` with the actual UUID):
	 ```
	 UUID=YOUR_SDB2_UUID /mnt/storage ntfs-3g defaults,nofail,uid=1000,gid=1000,umask=0022 0 0
	 ```

