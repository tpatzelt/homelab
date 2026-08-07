# popbook — laptop system snapshots

Full-system rsync snapshots of **popbook** (Arch/Omarchy laptop) to
`lindus:/mnt/storage/backups/popbook-system`. This is the client side of the
homelab's backup story: the server backs *itself* up to the offline HDD via
`autorestic/`, and the laptop pushes here.

## Why rsync and not restic/autorestic

popbook's root is plain **ext4 on a partition** — no LVM, no Btrfs — so there
is no snapshot primitive to hook into. Omarchy ships `snapper`,
`limine-snapper-sync` and a `/etc/snapper/configs/root` that declares
`FSTYPE="btrfs"`, but on an ext4 root that config is inert and
`omarchy-snapshot create` produces nothing. `btrfs send | ssh` — the approach
that would make "snapshot the system and ship it" literal — needs a Btrfs root
and therefore a reinstall.

`rsync --link-dest` gets most of the way there without one: each run writes a
dated, complete-looking tree, and files unchanged since the last run are
hardlinks into it.

Measured on the first two runs:

| | run 1 | run 2 |
|---|---|---|
| Sent over network | 25.23 G | 107.6 M |
| Disk cost on lindus | 25 G | 322 M |

## Layout

Run `sudo ./install.sh` on popbook.

| File | Installed to |
|---|---|
| `popbook-snapshot.sh` | `/usr/local/bin/popbook-snapshot` (extension dropped; kept here so `scripts/check.sh` shellchecks it) |
| `popbook-snapshot.excludes` | `/etc/popbook-snapshot.excludes` |
| `popbook-snapshot.service` | `/etc/systemd/system/` |
| `popbook-snapshot.timer` | `/etc/systemd/system/` |
| `popbook-snapshot.env.example` | → `/etc/popbook-snapshot.env` (0600, untracked) |

Daily at 21:00 ±30 min. `Persistent=true` matters on a laptop: a run missed
while off, asleep, or away fires shortly after the next boot instead of being
skipped. 14 snapshots retained.

## Untracked prerequisites

Nothing here carries the LAN address — the script resolves it with
`ssh -G lindus-backup`, so the only place it lives is `/root/.ssh/config`:

```
Host lindus-backup
    HostName <lindus-lan-ip>
    Port <ssh-port>
    User tim
    IdentityFile /root/.ssh/id_popbook_backup
    IdentitiesOnly yes
```

Also needed on popbook, none of it tracked:

- `/root/.ssh/id_popbook_backup` — dedicated key, public half in
  `tim@lindus:~/.ssh/authorized_keys` prefixed `restrict`
- `/root/.ssh/known_hosts` — pin lindus' host key. Verify the fingerprint over
  an already-authenticated session (`ssh lindus ssh-keygen -lf
  /etc/ssh/ssh_host_ed25519_key.pub`) rather than trusting first use
- `/etc/popbook-snapshot.env` — see the example file

## What is and isn't captured

Two rsync passes, both with `-x` so they stop dead at every mount boundary —
a USB stick or the NTFS partitions under `/run/media` can never be pulled in
by accident:

1. `/` — the root filesystem
2. `/boot` — a separate vfat filesystem, so pass 1 skips it

Included deliberately: `/usr` (293k entries). On Arch, old package versions
leave the mirrors, so a pkglist-only restore cannot reproduce the exact
system. With `--link-dest` it costs full size once and near-nothing after.

All Omarchy state is covered: `~/.config/omarchy`, `~/.local/share/omarchy`
(the install itself, including local modifications), `~/.local/state/omarchy`
(migrations and toggles), `~/.config/{hypr,waybar,walker,mako,alacritty,btop}`,
`~/.config/systemd/user`, and all of `/etc`.

Excluded: caches, `~/Downloads`, and browser cache subpaths chosen to keep the
profile while dropping the churn. Brave's `Greaselion/` alone is 745 MB across
181k files of regenerable component data — excluding it is most of the reason
the job finishes quickly.

`/var/lib/popbook-snapshot/` is regenerated each run and holds what a file
copy alone cannot restore: `pacman -Qqe`/`-Qqem` lists, the partition table,
`lsblk` UUIDs, EFI boot entries, enabled units, `fstab`, `limine.conf`, and
the Omarchy git rev plus dirty state.

## Ownership: --fake-super

The destination is owned by unprivileged `tim`, so ownership, modes and xattrs
are stored by the *remote* rsync in a `user.rsync.%stat` xattr rather than
applied directly. `ls` on lindus therefore shows everything as `tim tim` with
setuid bits missing — **this is expected and not a fault**. Verify with:

```bash
python3 -c 'import os,sys; print(os.getxattr(sys.argv[1], "user.rsync.%stat"))' \
    /mnt/storage/backups/popbook-system/latest/usr/bin/sudo
# -> b'104755 0,0 0:0'   (setuid, root:root)
```

`getfattr` is not installed on lindus; its absence is easily misread as
missing metadata.

**Any restore must also pass `--fake-super`**, or none of it is reapplied and
the result is unbootable.

## Restore

1. Boot the Omarchy/Arch ISO. `mkfs.ext4 -U <uuid-from-lsblk.txt>` — reusing
   the original UUID avoids having to fix `fstab` and `limine.conf`.
2. `rsync -aAXH --numeric-ids --rsync-path="rsync --fake-super" \
   lindus:/mnt/storage/backups/popbook-system/latest/ /mnt/`
3. **Do not restore `/boot` wholesale.** It is the shared ESP and carries
   `EFI/Microsoft` alongside `EFI/limine`; overwriting it breaks the Windows
   boot entry. Restore `EFI/limine`, `limine.conf`, the kernels and
   `intel-ucode.img` selectively.
4. `arch-chroot /mnt`, `mkinitcpio -P`, re-add the Limine EFI entry with
   `efibootmgr` using `efibootmgr.txt` as reference.

Not yet tested end to end.

## Known gaps

- **Unencrypted at rest.** Unlike the restic repos, these trees are plaintext
  on `/mnt/storage` and contain `~/.ssh`, `~/.gnupg` and browser password
  stores.
- **Single disk.** `/mnt/storage` (`sdb2`) only — no offline copy, no
  protection against that drive failing. The server's own data reaches the
  backup HDD weekly; this does not.
- **LAN only.** No backups while travelling, which is why the Healthchecks
  grace period is 7 days rather than the usual short window.
- **Live filesystem.** Not atomic; a database or browser profile written
  mid-run can land torn.
