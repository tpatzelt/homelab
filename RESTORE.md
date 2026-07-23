# Disaster Recovery — Restoring from Backup

Runbook for rebuilding this homelab from the autorestic/restic backup after a
drive failure. Read [`README.md`](README.md#backups) for how backups are *made*;
this file is only about getting data *back*.

The backup is a [restic](https://restic.net/) repository at
`/mnt/backup/restic-backups` on the dedicated 1.8 TB backup HDD (filesystem
label `backup`), written weekly by `autorestic/autorestic.sh`. Restic snapshots
store **absolute paths**, so a restore puts every file back exactly where it
came from.

Three locations are backed up, each tagged `ar:location:<name>`:

| Location tag              | Original path                          | Lives on         |
| ------------------------- | -------------------------------------- | ---------------- |
| `ar:location:my-data`     | `/mnt/storage/data`                    | 3.6 TB media HDD |
| `ar:location:docker-data` | `/opt/dockerdata`                      | system SSD (LVM) |
| `ar:location:secrets`     | `/home/tim/coding/homelab/secrets`     | system SSD (LVM) |

## ⚠️ What you MUST have off-machine first

A restore is impossible without all three of these, and none of them can be
recovered *from* the backup:

1. **The restic repo password.** It lives in `secrets/.autorestic.env`
   (`RESTIC_PASSWORD` / `AUTORESTIC_BACKUP_HDD_RESTIC_PASSWORD`) — but that file
   is itself inside the encrypted repo, so you cannot read the repo to get the
   password you need to read the repo. **Keep a copy in a password manager or
   other off-host location.** Without it, the backup HDD is unreadable ciphertext.
2. **This git repo.** It's public on GitHub (`tpatzelt/homelab`); it carries all
   the compose files you redeploy from. Cloning it back is step one of a rebuild.
3. **The backup HDD itself, intact.** These procedures assume the *system SSD*
   died and the backup HDD survived. If the backup HDD is what failed, there is
   no second copy — this is a known single-copy limitation of the current setup.

## Which scenario are you in?

- **System SSD died, `/mnt/storage` HDD intact** — the common case. You only need
  to restore `docker-data` and `secrets`; `my-data` on `/mnt/storage` is still
  there. Skip the `my-data` restore below.
- **`/mnt/storage` HDD died** — restore `my-data`.
- **Everything gone but the backup HDD** — restore all three.

---

## Full restore (fresh system SSD)

### 0. Rebuild the base host

Install the OS, then Docker, restic, and autorestic (the backup script calls
`/usr/local/bin/restic` and `/usr/local/bin/autorestic`). Clone the repo:

```bash
git clone https://github.com/tpatzelt/homelab.git ~/coding/homelab
```

### 1. Mount the backup HDD

The backup drive is *not* in fstab — mount it by label, read-only is safest
while you inspect:

```bash
sudo mkdir -p /mnt/backup
sudo mount -o ro /dev/disk/by-label/backup /mnt/backup
ls /mnt/backup/restic-backups     # should show config, data/, index/, snapshots/, keys/
```

### 2. Point restic at the repo and unlock it

```bash
export RESTIC_REPOSITORY=/mnt/backup/restic-backups
export RESTIC_PASSWORD='<the password you stored off-machine>'

restic snapshots        # confirm you can read the repo and see recent snapshots
```

`restic snapshots` printing your latest weekly snapshots is proof the password
is correct and the repo is intact. If this fails, stop — nothing below will work.

### 3. Restore each location to its original path

Restic restores absolute paths, so target `/` puts files back exactly where
they belong. `latest` + the location tag picks the newest snapshot per location:

```bash
# docker-data (service state) — restore before redeploying stacks
sudo -E restic restore latest --tag ar:location:docker-data --target /

# secrets (env files)
sudo -E restic restore latest --tag ar:location:secrets --target /

# my-data (only if /mnt/storage was also lost)
sudo -E restic restore latest --tag ar:location:my-data --target /
```

`-E` preserves the exported `RESTIC_*` vars under sudo. Restic never deletes
extra files at the target; it only writes what's in the snapshot.

> **Prefer to verify before overwriting?** Restore to a staging dir instead of
> `/`, inspect it, then move it into place:
> ```bash
> sudo -E restic restore latest --tag ar:location:docker-data --target /tmp/restore-check
> # inspect /tmp/restore-check/opt/dockerdata, then rsync into place
> sudo rsync -aH --info=progress2 /tmp/restore-check/opt/dockerdata/ /opt/dockerdata/
> ```

### 4. Re-establish the secrets symlinks

The restored `secrets/*.env` files are the real ones, but each stack's
`compose/<name>/.env` is a **symlink** into `secrets/` that git does track — a
fresh clone should already have them. Sanity-check they resolve:

```bash
cd ~/coding/homelab
ls -l compose/*/.env        # each should point at ../../secrets/.<name>.env
```

If any symlink is missing (see the "Secrets and env files" section of
`CLAUDE.md` for the convention, including the deliberate `.navidrom.env` typo),
recreate it, e.g. `ln -s ../../secrets/.caddy.env compose/caddy/.env`.

### 5. Redeploy the stacks

```bash
docker network create caddy_network      # external net must exist first
./scripts/restart-services.sh            # walks caddy -> core -> rest in order
```

### 6. Verify

```bash
./scripts/check.sh                        # offline config validation
docker ps                                 # all expected containers up
```

Then load a couple of services in the browser and confirm their data is present
(e.g. Immich photos, Vaultwarden vault, *arr libraries).

---

## Restore a single file or an older version

You don't need a disaster to pull one file back. List snapshots, then restore a
subpath or browse via mount:

```bash
export RESTIC_REPOSITORY=/mnt/backup/restic-backups RESTIC_PASSWORD='…'

restic snapshots --tag ar:location:docker-data           # find the snapshot/date you want
restic restore <snapshot-id> --target /tmp/one-file \
      --include /opt/dockerdata/vaultwarden/db.sqlite3    # pull just one path

# …or browse the whole repo as a filesystem (Ctrl-C to unmount):
mkdir /tmp/restic-mnt && restic mount /tmp/restic-mnt
```

## Rehearse a restore (do this periodically)

Restore the smallest location to a scratch dir and diff it against live data —
no disaster required, no risk to production:

```bash
export RESTIC_REPOSITORY=/mnt/backup/restic-backups RESTIC_PASSWORD='…'
sudo -E restic restore latest --tag ar:location:secrets --target /tmp/restore-test
sudo diff -r /tmp/restore-test/home/tim/coding/homelab/secrets \
             /home/tim/coding/homelab/secrets && echo "restore matches live"
```

Also worth running occasionally, independent of a restore:

```bash
restic check --read-data       # full integrity read of the whole repo
```

(The weekly script already does a rotating `--read-data-subset` so the entire
repo is verified about every six weeks.)

## Gotchas

- **Unmount when done:** `sudo umount /mnt/backup`. The backup script expects the
  drive unmounted between runs, so an empty `/mnt/backup` is the normal state.
- **Locks:** if a restore or check reports the repo is locked (e.g. a crashed
  run), clear stale locks with `restic unlock` — only when you're sure no backup
  is currently running.
- **Wiped/replaced backup HDD:** autorestic does **not** auto-initialize a repo.
  On a brand-new backup disk you must `restic init` once (same
  `RESTIC_REPOSITORY`/password) before the weekly job will work — a failed run
  on a missing repo is an intended alert, not something the script self-heals.
- **The password is the whole game.** Everything else here is mechanical; losing
  the restic password loses the backup permanently. Verify off-machine copies
  exist *before* you ever need this document.
