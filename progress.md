# Mail Loss Recovery & Storage Path Fix

**Started:** 2026-04-29
**Trigger:** maisonsoave.ch mailbox empty after `iredmail-core` container recreate on 2026-04-28 17:02 CEST.

---

## Root Cause (verified by two independent agents)

Three compounding misconfigurations cause mail data to land in the container's writable overlay layer instead of the host bind-mount, so any `docker rm` / image rebuild wipes all mail.

1. **`docker-compose.yml`** bind-mounts host `./data/vmail` to container `/var/vmail/vmail1` — only that subpath is persisted.
2. **`rootfs/etc/s6-overlay/scripts/init.sh:349-364`** generates `dovecot-sql.conf.ext` with hardcoded `CONCAT('/var/vmail/', maildir)` — ignores the `storagenode` column. Dovecot reads/writes at `/var/vmail/<domain>/...`, which is **outside** the bind-mount.
3. **`init.sh:290`** sets Postfix `virtual_mailbox_base = /var/vmail` (same problem for delivery).
4. **`init.sh:680`** writes `storage_base_directory = '/var/vmail'` to iRedAdmin's `settings.py`. iRedAdmin's splitter (`user.py:524-528`) produces buggy DB rows: `storagebasedirectory='/var', storagenode='vmail'`. The sample configs ship `'/var/vmail/vmail1'`.

`init.sh` re-runs on every container start (lines 916-930), so even if configs are hot-edited inside the container, they revert on next restart.

---

## Damage Inventory

Container `iredmail-core` was recreated 2026-04-28 17:02 → writable layer wiped.

| Mailbox | Server state after wipe | Local Thunderbird cache | Notes |
|---|---|---|---|
| `flo@chiaruzzi.ch` | 13 msgs (resync from Thunderbird) | INBOX 839 / Sent 41 / Drafts 14 / Trash 629 | recoverable from cache |
| `contact@maisonsoave.ch` | 0 msgs | INBOX 26 / Sent-1 24 / Trash 8 | recoverable from cache |
| `acc@maisonsoave.ch` | 0 msgs / dir missing | none | **lost** |
| `flo@purfacted.com` | dir missing | unknown | possibly recoverable from client |
| `lsgreen@purfacted.com` | dir missing | unknown | possibly recoverable from client |
| `noreply@purfacted.com` | dir missing | unknown | possibly recoverable from client |
| `joplin@kirby.rocks` | dir missing | unknown | low priority |
| `kanban@kirby.rocks` | dir missing | unknown | low priority |
| `postmaster@kirby.rocks` | empty (auto-recreated) | unknown | low priority |
| `scanlsgreen@chiaruzzi.ch` | dir missing | unknown | possibly recoverable |

---

## Backups

| Backup | Path | Size | Notes |
|---|---|---|---|
| Local TB profile (full) | `/home/kirby/mail-rescue-20260429-012222/thunderbird-profile.tar` | 252 MB | safe local copy |
| Local TB mboxes (selective) | `/home/kirby/mail-rescue-20260429-011916/` | 252 MB | redundant w/ above |
| Server container vmail snapshot | `/opt/iredmail/data/rescue-20260429-012222/container-vmail.tar` | 270 KB | maildir state at investigation time |
| Server vmail DB dump | `/opt/iredmail/data/rescue-db-20260429-012223/vmail-db-pre-fix.sql` | 29 KB | pre-`UPDATE` DB state |

---

## Action Log

### 2026-04-29 ~01:22 — Investigation & first (incomplete) attempt
- Identified mismatch between Dovecot SQL (`/var/vmail/<maildir>`) and bind-mount target (`/var/vmail/vmail1/...`).
- Created backups (above).
- `docker stop iredmail-core` → `docker cp` chiaruzzi.ch + maisonsoave.ch from container to host bind-mount path `/opt/iredmail/data/vmail/` → `docker start iredmail-core`.
- Ran `UPDATE vmail.mailbox SET storagebasedirectory='/var/vmail', storagenode='vmail1' WHERE storagebasedirectory='/var' AND storagenode='vmail';` (9 rows updated).
- **Verified post-restart**: Dovecot still reads from overlay (`doveadm user` showed `/var/vmail/<domain>/...`). Confirmed by file mtimes — overlay newer than host bind-mount.
- **Conclusion**: DB UPDATE was cosmetic. Dovecot SQL ignores those columns. Need real fix in `init.sh`.

### Side effect during investigation
- Running `doveadm mailbox status` against `postmaster@kirby.rocks` auto-created an empty maildir at `/var/vmail/kirby.rocks/p/o/s/postmaster-kirby.rocks/` in the overlay. Will be cleaned up by recreate.

### 2026-04-29 ~01:30 — Real fix (DONE)
- [x] Edited `rootfs/etc/s6-overlay/scripts/init.sh`:
  - Postfix `virtual_mailbox_base = /var/vmail/vmail1` (line ~293, with comment)
  - Dovecot SQL `password_query` & `user_query` → `CONCAT('/var/vmail/vmail1/', maildir)` (with comment)
  - iRedAdmin `storage_base_directory = '/var/vmail/vmail1'` (with comment)
- [x] Synced `init.sh` to server (`/opt/iredmail/rootfs/etc/s6-overlay/scripts/init.sh`).
- [x] Inside running container: `cp -a /var/vmail/chiaruzzi.ch /var/vmail/vmail1/chiaruzzi.ch` (13 mail files preserved); maisonsoave was empty.
- [x] `docker compose build iredmail` (image: `iredmail-custom:latest`).
- [x] `docker compose up -d --force-recreate iredmail`. Container healthy after ~20s.
- [x] Verified: `doveadm user flo@chiaruzzi.ch` → `home=/var/vmail/vmail1/chiaruzzi.ch/...`. Postfix `virtual_mailbox_base = /var/vmail/vmail1`.
- [x] Test mail via `doveadm save` → went from 13 → 14 msgs, file landed on host bind-mount at `/opt/iredmail/data/vmail/chiaruzzi.ch/.../new/`. Persistence proven. Test mail expunged afterward.

### 2026-04-29 ~01:38 — Backup script verification (DONE)
- [x] Ran `/opt/iredmail/scripts/backup.sh` manually.
- [x] New backup `iredmail_backup_20260429_013813.tar.gz` (1.2 MB total). Inside it `vmail.tar.gz` is now **48 KB with 13 mail files** (was 111 bytes / 0 mail files before fix). Bug confirmed fixed end-to-end.
- [x] `data/backup/` retention 30d kept as-is.

### 2026-04-29 — Offsite backup disabled (DONE)
- [x] Renamed `/etc/cron.d/iredmail-offsite-backup` → `iredmail-offsite-backup.disabled`. Cron skips dotted filenames; verified via `run-parts --test`. Re-enable by renaming back once Synology VPN + SSH key are fixed.

### 2026-04-29 ~01:42 — Mail restore (DONE)
mbox files copied via scp to `mail:/tmp/restore/`, then `docker cp` into container, imported with `doveadm import` per-folder.

INBOX restoration trick: `doveadm import` won't merge into existing INBOX, so source file was renamed to `RestoredINBOX`, imported, then `doveadm move INBOX mailbox RestoredINBOX all` (the trailing `all` is required — without it the move is rejected).

After move: `doveadm deduplicate -u <user> -m mailbox INBOX all` to remove Message-ID duplicates (mainly the 13 server-side msgs that flo's TB had already pushed back, plus a handful of internal mbox dupes — likely self-forwards).

#### Result

| Mailbox | INBOX | Sent | Drafts | Trash |
|---|---|---|---|---|
| `flo@chiaruzzi.ch` | 827 | 41 | 14 | (skipped) |
| `contact@maisonsoave.ch` | 26 | 24 | 12 | (skipped) |

mbox raw `From` line counts (pre-import): flo INBOX 839 / Sent 41 / Drafts 14; maisonsoave INBOX 26 / Sent 24 / Drafts 12. Sent + Drafts match exactly. INBOX dedup removed 12 (839 + 13 - 825 if server-only-13 are all in mbox = 839; we got 827 = 25 dups removed = 13 server + 12 internal).

#### Caveat for next Thunderbird open
UIDVALIDITY changed (new maildir). Thunderbird will detect this and rebuild its local cache from server. Local mboxes are now superseded by server. Recommend renaming TB's `ImapMail/mail.kirby.rocks/` and `ImapMail/mail.kirby-1.rocks/` to `*.OLD` BEFORE re-opening TB so it starts with a clean download. Alternatively just open TB and let it resync — the rescue tarballs are still safe at `/home/kirby/mail-rescue-20260429-012222/`.

### Tmp cleanup
- Removed `/tmp/restore/`, `/tmp/imp-*/`, `/tmp/init.sh.new` on server. Container `/tmp/imp-*/` removed.

---

### 2026-04-29 ~10:00 — Borg-based 4h backup added (DONE)
- [x] Installed `borgbackup` 1.2.8 on the server (Ubuntu 24.04 noble).
- [x] Added `BORG_PASSPHRASE` to `/opt/iredmail/.env` (64 hex chars, generated with `openssl rand -hex 32`).
- [x] New script `scripts/borg-backup.sh` — synced to `/opt/iredmail/scripts/borg-backup.sh`, owned by `masteradmin`, mode 0755.
- [x] Initialized `/opt/iredmail/data/borg-repo` with `--encryption=repokey-blake2`.
- [x] First two manual backups verified end-to-end:
  - Archive 1: 139.91 MB original → 75.19 MB compressed → 75.19 MB deduplicated (initial).
  - Archive 2 (28s later): 139.97 MB original → 75.22 MB compressed → **565 kB deduplicated** — dedup ratio ~247x. Repo total stays at ~75 MB.
- [x] Cron `/etc/cron.d/iredmail-borg-backup` active. Runs `*/4 *:15`, i.e. 6×/day. Logs to `data/logs/borg-backup.log`.
- [x] Retention: `--keep-hourly 6 --keep-daily 14 --keep-weekly 8 --keep-monthly 12`. `borg compact` runs only Sundays at 00:xx.
- [x] Old `backup.sh` (daily 02:00) **kept running in parallel** as a safety net during break-in period.
- DB dump path: `/opt/iredmail/data/db-dumps/all_databases.sql` (overwritten each run, 700/600 perms, included in archive).

#### Restore quickref
```
export BORG_PASSPHRASE=$(grep '^BORG_PASSPHRASE=' /opt/iredmail/.env | cut -d= -f2-)
borg list /opt/iredmail/data/borg-repo
borg extract /opt/iredmail/data/borg-repo::<archive-name> path/to/file
```

---

### 2026-04-29 ~10:30 — Subfolder restore (DONE)
After user reopened Thunderbird with renamed `*.OLD` caches, only top-level INBOX/Sent/Drafts were visible — all sub-folders (TB stored them under `INBOX.sbd/...`) were missing on the server because the first restore round only imported top-level mboxes.

Re-imported from `mail-rescue-20260429-012222/` recursively, mapping TB's `INBOX.sbd/A.sbd/B` layout to Dovecot's dot-separated `INBOX.A.B` IMAP namespace. Helper script: `/tmp/restore-folders.sh` (per user, sorted by depth so parent imports happen before children try to use them as dest_parent; auto-`doveadm mailbox create` for parent-only folders that don't have their own mbox file).

#### flo@chiaruzzi.ch — 18 mailboxes total

| Mailbox | Msgs |
|---|---|
| INBOX | 831 |
| Sent / Drafts / Trash | 41 / 14 / 0 |
| INBOX.0_work | 7 |
| INBOX.0_work.01_application | 23 |
| INBOX.0_work.02_RAV | 11 |
| INBOX.0_work.03_hays | 14 |
| INBOX.1_school (parent only) | 0 |
| INBOX.1_school.19_newwords | 11 |
| INBOX.2_government (parent only) | 0 |
| INBOX.2_government.25_trustee | 5 |
| INBOX.3_orders | 36 |
| INBOX.3_orders.30_shipment | 5 |
| INBOX.5_health | 3 |
| INBOX.6_flat | 1 (deduped from 2) |
| INBOX.7_misc (parent only) | 0 |
| INBOX.7_misc.79_IT | 5 |

#### contact@maisonsoave.ch — 10 mailboxes total

| Mailbox | Msgs |
|---|---|
| INBOX | 26 |
| Sent / Drafts / Trash | 24 / 12 / 0 |
| INBOX.Suppliers (parent only) | 0 |
| INBOX.Suppliers.Poldau | 6 |
| INBOX.Suppliers.Declined (parent only) | 0 |
| INBOX.Suppliers.Declined.Dykon | 4 |
| INBOX.Suppliers.Declined.Mayas | 2 |
| INBOX.Suppliers.Declined.Novaya | 2 |

All counts match `grep -c '^From '` on the source mboxes within ±1 (mbox `^From` parsing is approximate).

### 2026-04-29 ~10:33 — Borg coverage verified
- New archive `mail-2026-04-29_103351` captures the new structure: 1007 maildir files in chiaruzzi.ch + 76 in maisonsoave.ch + 80 subfolder directory entries with correct cur/new/tmp layout.
- Confirmed via `borg list` that every `.INBOX.*` maildir is present.

## Status: storage path bug FIXED + INBOX/Sent/Drafts/Trash + ALL sub-folders RESTORED + Borg backups capture everything + Borg 4h backups ACTIVE

What's left for tomorrow / later:

- **Offsite backup** — primary plan now: Hetzner Storage Box + `borg sync` (or `borg create` to a remote SSH repo). Old Synology NAS path via WireGuard 10.0.0.2:44 is deferred. Re-enable with `mv /etc/cron.d/iredmail-offsite-backup.disabled /etc/cron.d/iredmail-offsite-backup` after Synology side fixed. Issues seen in `offsite-backup.log`: 26 Apr `Permission denied` on SSH (key likely removed/rotated on NAS), 27+28 Apr `Cannot reach 10.0.0.2 - VPN down`.
- **Borg key export** — in `repokey` mode the encryption key lives inside the repo (encrypted with the passphrase). For an extra layer of safety run `borg key export /opt/iredmail/data/borg-repo /root/borg-key.txt` and store that file off-server (1Password / printout). The passphrase alone isn't enough if the entire `data/` disk is gone.
- **Old `backup.sh` retire** — once Borg has run reliably for ~2 weeks, remove `/etc/cron.d/iredmail-backup` and the legacy `backup.sh`/`restore.sh` (or keep them as documented secondary path).
- **Kernel reboot pending** — `apt-get install borgbackup` flagged that 6.8.0-110 is available but 6.8.0-90 is running. Reboot at next maintenance window.
- **Other domain mailboxes** (`purfacted.com`, `kirby.rocks`) — `flo@purfacted.com`, `lsgreen@purfacted.com`, `noreply@purfacted.com`, `joplin@kirby.rocks`, `kanban@kirby.rocks`, `scanlsgreen@chiaruzzi.ch` are still empty on server. User should check other devices (phone, tablet, other laptops) for cached IMAP content. If content exists anywhere, same `doveadm import` recipe applies.
- **Trash recovery for flo@chiaruzzi.ch** — Thunderbird Trash had 629 msgs. Skipped during restore. If user wants, can be imported as a separate `Trash` mailbox from `/home/kirby/mail-rescue-20260429-012222/`.
- **Other Thunderbird folders** — only INBOX/Sent/Drafts were restored. If there are other IMAP folders (Spam, Archive, custom), those Thunderbird mbox files exist under `INBOX.sbd/` but were NOT touched. Same recipe applies.
- **Acc@maisonsoave.ch** — was empty in the local TB cache too, so unrecoverable.
- **Image-rebuild safety check** — consider adding a smoke test in `setup.sh` or a GitHub Action that creates a test mailbox, sends a mail, verifies the file lands at `data/vmail/.../new/` on the host (not in the container's overlay). Would have caught this bug pre-deploy.
- **iRedAdmin's split-pop logic in `libs/sqllib/user.py:524-528`** is a footgun — reports of similar misconfigurations are easy. Worth a comment in our `init.sh` linking to this incident, which is now in place.
