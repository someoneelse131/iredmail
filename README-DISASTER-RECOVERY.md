# Disaster Recovery

Worst case: the VPS is gone, you have a fresh server and a copy of the Borg repo + the passphrase. This file is the recipe for getting mail back online. Read this once when you're calm so it's familiar when you're not.

## You need

- A new VPS (Docker-capable, reasonable specs: 4 GB RAM, 20+ GB disk).
- A copy of the Borg repo directory (`data/borg-repo/`). Source: offsite mirror, second backup disk, etc.
  - Primary offsite as of 2026-05-01: Ionos HiDrive WebDAV. Sub-user `hidrive-kirby-backup`, password in 1Password under "iRedMail HiDrive backup". Endpoint `https://webdav.hidrive.ionos.com/`.
- The Borg passphrase. Either on paper, in a password manager, or inside the recovered `.env` (if you also recovered that).
- DNS access for the domain so MX/A/SPF/DKIM/DMARC keep pointing at the new server's IP.

## Recipe (≈ 20 minutes once everything is in reach)

```bash
# 1) Bring up the new VPS, install Docker + git + borg
apt-get update
apt-get install -y docker.io docker-compose-v2 git borgbackup rsync

# 2) Clone this repo
git clone <your-repo-url> /opt/iredmail
cd /opt/iredmail

# 3) Get the Borg repo into place. Pick whichever applies:
#    Option A: from HiDrive (Ionos) — the active offsite as of 2026-05-01.
#       You need the WebDAV creds (sub-user "hidrive-kirby-backup", password
#       in 1Password). Recreate ~/.config/rclone/rclone.conf with the same
#       [hidrive] block, then:
apt-get install -y rclone
mkdir -p /opt/iredmail/data/borg-repo
rclone copy hidrive:/backup/iredmail/data /opt/iredmail/data/borg-repo --transfers 4 --progress
#    Option B: rsync from another offsite host
rsync -aP user@offsite:/path/to/borg-repo/ /opt/iredmail/data/borg-repo/
#    Option C: scp / restore from cold storage
#    Option D: if you only have a remote borg URL, point restore-borg.sh at it directly

# 4) Restore .env from the most recent archive (you need .env's MYSQL_ROOT_PASSWORD
#    BEFORE the full restore, because the DB import runs against the live container).
export BORG_PASSPHRASE=<your passphrase>
cd /tmp
borg list /opt/iredmail/data/borg-repo
borg extract /opt/iredmail/data/borg-repo::<latest-archive> opt/iredmail/.env
cp /tmp/opt/iredmail/.env /opt/iredmail/.env

# 5) Run setup.sh — creates data dirs, installs cron files, but won't re-init
#    the existing borg repo (idempotent)
sudo bash /opt/iredmail/setup.sh

# 6) Build and start everything (DB + iredmail-core)
cd /opt/iredmail
docker compose build
docker compose up -d
# Wait until iredmail-db is healthy:
docker compose ps

# 7) Run the interactive Borg restore — pick the most recent archive,
#    choose mode 3 (full restore). It stops the iredmail container,
#    rsyncs data/{vmail,dkim,ssl,sogo,...}, re-imports the DB, and restarts.
sudo /opt/iredmail/scripts/restore-borg.sh

# 8) Verify
docker compose ps
docker compose logs -f iredmail
docker exec iredmail-core doveadm user '*'   # should list your accounts
sudo /opt/iredmail/scripts/borg-backup.sh    # take a fresh backup post-restore
```

## After restore

- **DNS**: update the A record for your mail hostname to the new VPS IP. Verify MX still points at the right hostname. Re-check `dig +short MX example.com`.
- **PTR (rDNS)**: set via your hosting provider's panel — required for many remote MTAs to accept your mail.
- **Let's Encrypt cert**: was restored from Borg, but if it's near expiry run `./scripts/obtain-cert.sh` to renew.
- **Test mail flow**: send to and from an external address (e.g. via a personal Gmail). Check `data/logs/maillog`.
- **Restart the Borg cron**: `setup.sh` already installs `/etc/cron.d/iredmail-borg-backup`. First scheduled run is at the next `*:15` per 4-h schedule.

## If you only have the passphrase but no repo

Sorry — repo is gone, backups are unrecoverable. The whole point of having an offsite copy is to make sure that scenario doesn't happen.

## If you only have the repo but no passphrase

Same — Borg cannot decrypt the repo without the passphrase. The keyfile is stored *inside* the repo (encrypted with the passphrase), so without the passphrase nothing can be read.

This is why the passphrase belongs in **at least two places** that aren't the VPS itself: a password manager AND a paper printout in a drawer is a reasonable belt-and-suspenders setup.

## A quick sanity check, every now and then

Once a month, run this — it asks nothing of the live system but proves your backups are actually recoverable:

```bash
export BORG_PASSPHRASE=$(grep '^BORG_PASSPHRASE=' /opt/iredmail/.env | cut -d= -f2-)
borg check --verify-data /opt/iredmail/data/borg-repo
borg list /opt/iredmail/data/borg-repo | tail
```

`borg check --verify-data` reads every chunk and validates its MAC. If something is corrupted on disk, you find out now — not when you actually need to restore.
