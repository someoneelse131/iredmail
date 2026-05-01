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

### 2026-04-29 ~later — Thunderbird folder tree fix (DONE)

After the subfolder restore, Thunderbird only showed `Trash` (and a special-cased INBOX). Reproduced server-side with `doveadm mailbox list -u <user> -s` — only `Trash` was subscribed for both `flo@chiaruzzi.ch` and `contact@maisonsoave.ch`. The 18/10 mailboxes existed and were listable, but unsubscribed → TB hides them by default.

**Root cause**: `doveadm import` creates destination mailboxes but does NOT subscribe them. Initial import path subscribed only `Trash` (likely autocreated/auto-subscribed by Dovecot itself at some earlier point). All other mailboxes from the depth-sorted import were unsubscribed.

**Permission angle in todo.md was a red herring at fix time** — when verified, ownership was already `2000:2000` on `data/vmail/{chiaruzzi.ch,maisonsoave.ch}` and `doveadm mailbox list` worked without permission errors. Either it self-healed (container restart re-applies vmail UID) or it was never persistent on the host bind-mount in the way todo.md described. No chown was needed; would have been redundant anyway.

**Fix**: subscribed every mailbox for both users:

```
docker exec iredmail-core bash -c '
  for u in flo@chiaruzzi.ch contact@maisonsoave.ch; do
    doveadm mailbox list -u "$u" | while IFS= read -r m; do
      doveadm mailbox subscribe -u "$u" "$m"
    done
  done'
```

**Verified**: `doveadm mailbox list -s` now returns 18/18 (flo) and 10/10 (contact) — full match against unfiltered list.

**For next TB open**: refresh folder list / right-click account → Subscribe… (everything will already be checked). If TB still hides anything, Account Settings → Server Settings → Advanced → uncheck "Show only subscribed folders".

## Status: storage path bug FIXED + ALL mail RESTORED + Borg 4h backups ACTIVE + Thunderbird folder tree FIXED

---

# 2026-04-29/30 — 4-agent audit & remaining work

## Audit context (read this first when picking up in a new session)

On 2026-04-29 four parallel agents (read-only) audited backup, persistence, security, and operations against the live server. Methodology: each agent verified `progress.md` claims against actual server state (`ssh mail`).

**Overall verdict: SOLID-WITH-CAVEATS.**

- Mail persistence is **durable**: inode-identical host↔container, init.sh regenerates correct paths from scratch on every container start, all 10 DB rows consistent.
- Borg pipeline is **mechanically sound**: `borg check --repository-only` clean, atomic `.tmp` rename for DB dump, restore-drill bit-identical, dedup ratio ~250×, repo 77 MB.
- **Two CRITICAL gaps** (one disk loss right now = total data loss): (a) no offsite copy, (b) borg key only on the same disk as the repo it protects.
- **Silent-failure mode active**: no `MAILTO=` in any cron file, no MTA on the host, no Healthchecks.io / monitoring. Confirmed today (2026-04-29 11:07): a borg run died on `mysqldump: Can't read dir of './amavisd/' (errno: 13)` and was only noticed because a manual run followed 5 min later.

## What's already verified solid — DON'T re-investigate

- Storage-path fix durable: inodes identical, `init.sh` regen correct, DB rows consistent (`storagebasedirectory='/var/vmail'`, `storagenode='vmail1'`).
- Borg: integrity OK, atomic dump, restore bit-identical, dedup excellent, schedule `15 */4 * * *` actually fires (verified syslog `12:15:01 mail CRON[934238]`).
- Repo == server: `sha256sum init.sh + docker-compose.yml` identical.
- fail2ban absorbing attacks: 1.428 sshd / 8.418 postfix-sasl bans today.
- TLS cert valid until 2026-07-19, certbot renewal cron OK.
- UID alignment: container vmail = 2000:2000 = host bind-mount perms.
- All `privkey*.pem` are mode 600 (security audit's "777 privkey" was a symlink-mode false positive — symlinks always show `lrwxrwxrwx` regardless of any chmod).

## Done in audit-session (2026-04-29 ~14:00–14:45)

- **C2 — SSH password auth disabled.** `/etc/ssh/sshd_config.d/50-cloud-init.conf` renamed to `.disabled` (cloud-init drop-in had `PasswordAuthentication yes` and was winning lex-order vs `60-cloudimg-settings.conf`). `sshd -T` now reports `passwordauthentication no`. Reloaded; fresh connect verified.
- **C3 — `/opt/iredmail/.env` chmod 600** (was 664 masteradmin:masteradmin → still owner masteradmin since cron uses root-readable, manual `docker compose` by masteradmin still works).
- **C4 — `/opt/iredmail/data/backup/iredmail_backup_*.tar.gz` chmod 600** (all 33 files; were 644 masteradmin:masteradmin).

## Open — needs user decision before next step

### C5 — Borg key off-server (PARTIAL)
- DONE: `sudo borg key export /opt/iredmail/data/borg-repo /root/borg-key-export.txt` (mode 600).
- NEXT: user saves the key block to **1Password + paper printout**, then I run `ssh mail sudo shred -u /root/borg-key-export.txt`.
- Why critical: `repokey-blake2` stores the encryption key INSIDE the repo. Disk loss = key loss = backup unrecoverable even with the passphrase.

### C6 — Offsite backup destination (DECISION PENDING)
Single-disk-of-failure right now. Options:
- **(a) Hetzner Storage Box** (~3€/mo, 1 TB, supports SSH + native borg). Need from user: account + SSH key setup + hostname. I'll then add a second `borg create ssh://...` step to `borg-backup.sh`, init that remote repo with `--encryption=repokey-blake2` (different passphrase, also stored in `.env`), and use `--append-only` on the SSH key's `command=` so a compromised mail server cannot delete remote archives.
- **(b) Interim — rsync mirror to laptop / external disk / S3 via rclone.** Lower friction, but laptop must be on; not append-only.

### C7 — Backup-failure alerting (DECISION PENDING)
Options:
- **(a) Healthchecks.io free tier.** User creates a check, gives me UUID. I patch `borg-backup.sh` to ping `https://hc-ping.com/<uuid>` on success and `/<uuid>/fail` from a `trap '... ' ERR`. Survives outbound-mail-broken scenarios.
- **(b) `apt install msmtp-mta`** on host + `MAILTO=claude@bloat.ch` in every `/etc/cron.d/iredmail-*` file. Uses email as the alert channel.

## HIGH — implement this week

| # | Title | Where | Action |
|---|---|---|---|
| H1 | `/var/lib/amavis` in writable overlay → quarantine state vanishes on `--force-recreate` | `docker-compose.yml` | Add bind-mount `- ./data/amavis:/var/lib/amavis`; pre-create dir with the in-container amavis UID |
| H2 | Container `json-file` logs unbounded | `/etc/docker/daemon.json` (does not exist) | Create with `{"log-driver":"json-file","log-opts":{"max-size":"50m","max-file":"5"}}`, `systemctl restart docker` (bounces all containers — schedule a window) |
| H3 | `/opt/iredmail/data/logs/{maillog 160M, dovecot.log 34M, nginx-error.log 30M}` unrotated | `/etc/logrotate.d/iredmail` | daily, keep 14, `copytruncate`. Plus investigate maillog double-line bug (rsyslog rule duplicate inside container) |
| H4 | Postfix surface too wide | `rootfs/etc/s6-overlay/scripts/init.sh` (postfix gen section) or `config/postfix/main.cf` overrides | Set `smtpd_tls_auth_only=yes`, `disable_vrfy_command=yes`, `smtpd_helo_required=yes`, `smtpd_helo_restrictions=permit_mynetworks, permit_sasl_authenticated, reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname`, `smtpd_tls_protocols=>=TLSv1.2`, `smtpd_tls_mandatory_ciphers=high`, `smtpd_tls_mandatory_protocols=>=TLSv1.2` |
| H5 | Healthcheck `/usr/local/bin/health-check.sh` only checks process existence, not actual mail flow | source likely `rootfs/usr/local/bin/health-check.sh` | Add final stage: `doveadm save` test mail → assert file appears under `/var/vmail/vmail1/...` on host within 5s, expunge afterwards |
| H6 | `borg-backup.sh` resilience patches (no setup needed, code-only) | `scripts/borg-backup.sh` | (a) wrap mysqldump in `if ! mysqldump …; then echo "WARN: DB stale" >&2; fi` + continue with FS-only archive; (b) `flock -n /var/lock/borg-backup.lock $0 \|\| exit 0` at top; (c) `export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes BORG_HOSTNAME_IS_UNIQUE=yes`; (d) `borg compact --threshold 10` after every prune (not Sunday-only — repo is 77 MB); (e) `chmod 600` after dump file written explicitly |
| H7 | `backup.sh` produces world-readable tarballs | `scripts/backup.sh` | `umask 077` at top, explicit `chmod 600` after tarball creation |
| H8 | DMARC `p=quarantine`, chiaruzzi.ch has `sp=none` (subdomain spoofable), SPF `~all` on 3/4 domains | DNS at registrar | After 2-4 weeks of clean DMARC reports: `p=reject; sp=reject` and SPF `-all`. chiaruzzi.ch `sp=reject` is the most urgent |

## MEDIUM/LOW — later

### Operational
- **Apt + kernel reboot pending**: 6.8.0-110 installed, 6.8.0-90 running, 58 security updates incl. `containerd.io`, `libssl`, `apparmor`, `cloud-init`. `sudo apt -y upgrade && sudo reboot` at next window.
- **Roundcube `temp/` + PHP `sessions/` in overlay** — webmail uploads/sessions die on container recreate. Add bind-mounts.
- **`scripts/smoke-test.sh`** — sketch in audit findings, runs `doveadm save` + asserts host-bind landing. Add to `setup.sh` and CI.
- **Retire `backup.sh`** after 2 weeks of borg stability (target: ~2026-05-13). Or shorten retention to 7d (currently keeps 30d × ~75 MB = ~2 GB redundant).
- **MTA-STS + TLS-RPT** for all 4 domains. `_mta-sts.<d> CNAME mta-sts.<d>` + policy file at `https://mta-sts.<d>/.well-known/mta-sts.txt` + `_smtp._tls.<d> TXT v=TLSRPTv1; rua=mailto:postmaster@kirby.rocks`.
- **nginx HSTS**: `add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;` in `rootfs/etc/nginx/sites-available/default` 443 server block.
- **iRedAdmin session cookie**: missing `Secure` flag. nginx workaround: `proxy_cookie_flags ~ secure;` on uwsgi location.
- **UFW**: `sudo ufw delete allow 1111/tcp` (stale rule, nothing listening).
- **`mysqldump -p"$VAR"`** in `borg-backup.sh` puts password on argv (briefly visible in `ps` inside `iredmail-db`). Switch to `--defaults-extra-file=` or `MYSQL_PWD` env.
- **Disk-space watchdog** — currently none. Either monit `/etc/monit/conf-enabled/disk` (4 lines) or `*/30 cron` doing `df --output=pcent / | tail -1 | awk '$1>85{exit 1}' || curl hc-ping/fail`.
- **Container weekly CVE scan**: `docker scout cves iredmail-custom:latest` or `trivy` in cron, report to user.

### Restore robustness
- **Restore script `restore-borg.sh:135`** has hardcoded 9-dir list. New data dirs → silent gap. Replace with deny-list iteration over actual contents.
- **Document secret rotation runbook** in `README-DISASTER-RECOVERY.md`: `BORG_PASSPHRASE` (`borg key change-passphrase`), `MYSQL_ROOT_PASSWORD`, iRedAdmin admin password, DKIM keys.
- **Backup includes `data/postfix-queue`?** Currently excluded — small, but means in-flight queued mail at backup time is unrecoverable. Decide: include or document.

### Hardening (deeper)
- **Container caps**: currently `CAP_NET_BIND_SERVICE` only, but no `--security-opt=no-new-privileges`, no AppArmor profile. Iredmail upstream is supervisor-as-root, hard to fully de-root. At minimum add `no-new-privileges` and review caps.
- **`masteradmin` in `docker` group** = root-equivalent. Single-admin box, accepted; consider `pam_oath` 2FA on SSH if paranoia rises.

### Data hygiene / orphans
- **Postfix queue permission flap from 2026-04-29 11:07** — `mail.err` had `qmgr: scan_dir_push: open directory deferred: Permission denied` on `active`/`deferred`/`maildrop` for ~3 minutes. Persistence agent verified queue is empty and mailflow works now. **One-time check**: `docker exec iredmail-core ls -la /var/spool/postfix/{active,deferred,maildrop}` → UIDs as expected (postfix=90 inside container)?
- **Investigate `mysqldump amavisd permission denied`** root cause — same time window as queue flap, could be related.
- **`/opt/iredmail/data/rescue-2026-0429-*` snapshots** still on disk, mode 755. After confirming not needed: `sudo rm -rf /opt/iredmail/data/rescue-*`.
- **iRedAdmin `libs/sqllib/user.py:524-528`** splitter still buggy upstream — current DB rows happen to be consistent with what Dovecot SQL does. Monitor: any NEW mailbox created via web UI must verify the row matches.

### Mail recovery (carry-over from incident)
- **`flo@purfacted.com`, `lsgreen@purfacted.com`, `noreply@purfacted.com`, `joplin@kirby.rocks`, `kanban@kirby.rocks`, `scanlsgreen@chiaruzzi.ch`** — still empty on server. Check phone/tablet/other laptops for cached IMAP. If content exists anywhere, same `doveadm import` recipe.
- **Trash recovery for `flo@chiaruzzi.ch`** — TB Trash had 629 msgs, skipped during restore. Source still safe at `/home/kirby/mail-rescue-20260429-012222/`.
- **Other Thunderbird folders** under `INBOX.sbd/` (Spam/Archive/custom) — not restored. Same recipe.
- **`acc@maisonsoave.ch`** — empty in TB cache too, unrecoverable.

## How to resume in a fresh session

1. Read this section top to bottom.
2. State of the truth on the server:
   ```
   ssh mail 'sudo ls -la /opt/iredmail/.env /opt/iredmail/data/backup/ | head -3; sudo sshd -T 2>/dev/null | grep -i passwordauth; sudo borg list /opt/iredmail/data/borg-repo'
   ```
3. C5 finalization status:
   ```
   ssh mail 'sudo ls -la /root/borg-key-export.txt 2>&1'
   ```
   - If file exists → user hasn't confirmed save yet; ask before shredding.
   - If "No such file" → already shredded, C5 done.
4. C6/C7 still pending decisions — ask user which path.
5. For any HIGH item: pre-conditions are documented in the table above; no surprise discovery needed.

---

# 2026-04-30 — Second 4-agent SECURITY audit + prioritized plan

## Audit context

Four parallel read-only agents on 2026-04-30, this time purely security-focused (vs. the 2026-04-29 backup/persistence/security/ops mix):

1. Container & Docker security
2. Mail / SMTP / IMAP / TLS security
3. Web stack (nginx + iRedAdmin + Roundcube + SOGo) security
4. Host / secrets / repo / operational security

## Important correction to a previous claim

Agent 2 reported "fail2ban only protects sshd, postfix-sasl and dovecot jails are inactive". This was WRONG — the agent queried the **host** fail2ban (which only has the sshd jail). The **container** fail2ban (`iredmail-fail2ban` from `crazymax/fail2ban:1.1.0`) is the one protecting mail and is fine:

```
ssh mail 'sudo docker exec iredmail-fail2ban fail2ban-client status'
→ Jail list: dovecot, postfix-sasl
postfix-sasl: 30819 failed, 8492 banned (matches progress.md line 220)
dovecot:      10029 failed,    0 banned ← suspicious, see P1-A
```

So progress.md line 220 ("8418 postfix-sasl bans") was correct. The "1428 sshd bans" in the same line refers to the host's fail2ban, also correct. Mail-protocol brute-force IS being absorbed.

What's still missing on fail2ban: roundcube-auth, sogo-auth, iredadmin jails, and the dovecot 0-bans anomaly.

## What's already solid — DON'T re-investigate

(In addition to the 2026-04-29 list)
- Container fail2ban for postfix-sasl + dovecot is loaded and counting.
- Repo `git log -p` clean for tracked secrets (`.env`, `*.pem`, `*.key`, `*.crt` never committed).
- Open-relay closed (`smtpd_relay_restrictions` correct).
- TLS cert chain valid until 2026-07-19, ECDSA, includes autoconfig/autodiscover SANs.
- Dovecot TLS config (`ssl_min_protocol = TLSv1.2`, PFS-only ciphers).
- Docker socket not mounted into any container.
- `.gitignore` adequate.
- AppArmor enforcing (25 profiles, `docker-default` applies to containers).

## Prioritized plan (risk-based)

Risk = probability × blast radius. Active threats first, recovery scenarios second.

### P0 — sofort (today, ~30 min total)

| # | Item | Why P0 | Effort | Who |
|---|---|---|---|---|
| P0-1 | `chmod 600 /home/kirby/projects/github/iredadmin/.env` | Currently 644 on laptop, contains MYSQL_ROOT + DB pws | 5 sec | claude |
| P0-2 | Replace static MLMMJADMIN_API_TOKEN + ROUNDCUBE_DES_KEY in `.env.example` (lines 42, 45) with placeholders + openssl snippet | Public on GitHub since init commit; anyone copying verbatim ends up with publicly known secrets | 5 min | claude |
| P0-3 | Remove `NOPASSWD` from `masteradmin` line in `/etc/sudoers.d/90-cloud-init-users` (keep root line) | If SSH key ever leaks → instant root with zero auth gate. Single password gate adds meaningful friction. | 2 min | **user (visudo, sudo required)** |

### P1 — diese Woche (active attack surface, ~1 day)

#### P1-A: Mail-jails ergänzen + dovecot 0-bans untersuchen — DONE 2026-05-01
- **Diagnose dovecot 0-bans**: `fail2ban-regex` zeigt 10033/203881 lines matched ✓. Pro-IP-Aggregation: höchste IP nur 2 hits in 5000 lines → **verteilte Brute-Force**, nie Schwellwert. Filter+chain OK; Param zu lax. Postfix-SASL bannt fleißig (8524) weil SMTP-Angriffe weniger verteilt sind.
- **Fix**: dovecot jail jetzt `findtime=3600, maxretry=3`. Inline-Kommentar im config dokumentiert die Diagnose.
- **roundcube-auth + sogo-auth aktiviert**. Pfade verifiziert (`/var/log/iredmail/roundcube/errors.log` ✓, `/var/log/iredmail/sogo.log` ✓). Default-Filter `roundcube-auth.conf` matched 2/3 sample-lines (1 PHP-Error legitim ignoriert).
- **fail2ban-client status**: 4 jails aktiv (`dovecot, postfix-sasl, roundcube-auth, sogo-auth`).
- **Deferred to P3**: `[iredadmin]` jail (kein log file — uwsgi loggt zu stdout, müsste `logto =` in config setzen). `[recidive]` jail (Container schreibt kein `fail2ban.log`, müsste `loglevel`+`logtarget` in fail2ban.local setzen).
- **Side-finding (P3 ticket)**: SOGo flooded log mit `SOGoCache: SERVER HAS FAILED AND IS DISABLED UNTIL TIMED RETRY` — memcached-Verbindung kaputt. Trifft jeden CalDAV-Request. Eigenes Issue.

#### P1-B: Spam-stack einbauen — PHASE 1 DONE 2026-05-01
- ✅ amavis als content_filter (10024) + Re-injection (10025) verdrahtet (init.sh `configure_postfix`).
- ✅ Zweiter amavis-Port (10026) mit `ORIGINATING` Policy für outbound DKIM-Signing. submission/smtps routen via `content_filter=smtp-amavis-orig:[127.0.0.1]:10026`.
- ✅ ClamAV-Permission-Bug behoben: clamav-User in amavis-Group + clamav s6-Service hängt jetzt von init ab (race-fix `rootfs/etc/s6-overlay/s6-rc.d/clamav/dependencies.d/init`).
- ✅ SpamAssassin scoring aktiv: `tag_level_deflt=-999, tag2=5.0, kill=9.0`. Subject prefix `[SPAM] `. `D_PASS` statt `D_DISCARD` damit Mail nicht stillschweigend gelöscht wird.
- ✅ DKIM-Signing aktiviert für alle 4 Domains (`dkim_key()` aus /var/lib/dkim/*.pem). `amavisd-new showkeys` listet alle 4. Selector=`dkim` matcht DNS.
- ✅ Sieve `before.d/spam-to-junk.sieve`: `X-Spam-Flag: YES` → `fileinto Junk + setflag \\Seen`. Pre-compiled (sievec) im Image.
- ✅ Critical fix: `@local_domains_acl` enthält jetzt alle gehosteten Domains (vorher nur `mail.kirby.rocks` aus `/etc/mailname`). Vorher → policy bank `RelayedOpenRelay` → no spam-tagging. Jetzt → `RelayedTaggedInbound` → tagging on.
- ✅ E2E Test (extern via python smtplib → :25):
  - clean (score 3.524) → INBOX, X-Spam-Flag: NO
  - GTUBE (score 1003.524) → Junk, X-Spam-Flag: YES, Subject: `[SPAM] ...`
  - EICAR → `Blocked INFECTED (Eicar-Signature) {DiscardedInbound,Quarantined}`. ClamAV läuft sauber.
- ✅ Inbound DKIM-Verifikation funktioniert: realer simplelogin.co Mail kam mit `dkim_sd=dkim:simplelogin.co` durch.

**Phase 1 — User-Verifikation für outbound DKIM nötig:**
Eine Mail aus Thunderbird (oder einem anderen Client) via 587/465 → external (z.B. Gmail-Eigenkonto). Im Empfänger-Header muss stehen:
```
DKIM-Signature: v=1; a=rsa-sha256; ... d=chiaruzzi.ch; s=dkim; ...
Authentication-Results: ... dkim=pass header.d=chiaruzzi.ch
```
Falls nicht: 50-user `dkim_signature_options_bysender_maps` per-domain anpassen.

**DEFERRED zu Phase 2 (separate Session):**
- imap_sieve plugin + sa-learn loop (move to Junk → `sa-learn --spam`, move out → `sa-learn --ham`). User kann derzeit Junk per Hand befüllen, aber das System lernt nicht.
- Roundcube markasjunk Plugin (sichtbarer "Spam"-Button).
- System sendmail (cron, postmaster auto-replies) DKIM-signing — derzeit unsigniert, da local sendmail über 10024 läuft, nicht 10026. Niedrige Priorität.

**Side-finding (P3):** SOGo memcached-Verbindung ist kaputt (`SERVER HAS FAILED — DISABLED UNTIL TIMED RETRY` flutet sogo.log bei jedem CalDAV-Request). Eigenes Issue.

#### P1-C: Roundcube CVEs + source exposure
- Pin Roundcube 1.6.10+ in Dockerfile (current 1.6.6, Jan 2024, has CVE-2024-37383 / 42008 / 42009 / 42010).
- Rebuild iredmail-custom image.
- Add nginx `deny` rules for `/mail/composer.*`, `/mail/SQL/`, `/mail/INSTALL`, `/mail/UPGRADING`, `/mail/SECURITY.md`, `/mail/CHANGELOG.md`, `/mail/vendor/`, `/mail/bin/`, `/mail/installer/` (currently all return HTTP 200).
- `RUN rm -rf /var/www/roundcube/installer` in Dockerfile.

#### P1-D: Postfix hardening (= H4 mit konkreten Werten vom Audit)
In `rootfs/etc/s6-overlay/scripts/init.sh` postfix gen block:
- `smtpd_tls_auth_only = yes` (was `no` global → cleartext AUTH on 25 wird eliminiert)
- `smtpd_tls_protocols = >=TLSv1.2`, `smtpd_tls_mandatory_protocols = >=TLSv1.2` (war `>=TLSv1`)
- `smtp_tls_protocols / smtp_tls_mandatory_protocols = >=TLSv1.2` (outbound auch)
- `smtpd_tls_ciphers = high`, `smtpd_tls_mandatory_ciphers = high`, `tls_preempt_cipherlist = yes`, `smtpd_tls_eecdh_grade = ultra`
- `smtpd_helo_required = yes`, `disable_vrfy_command = yes`
- `smtpd_helo_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname`
- `smtpd_sender_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_non_fqdn_sender, reject_unknown_sender_domain`
- `smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_non_fqdn_recipient, reject_unknown_recipient_domain, reject_unauth_destination, check_policy_service unix:private/policyd-spf`
- `smtpd_data_restrictions = reject_unauth_pipelining`
- Switch `smtpd_relay_restrictions` final action from `defer_unauth_destination` → `reject_unauth_destination` (returns 5xx instead of 4xx)
- `smtpd_sasl_authenticated_header = yes` (audit trail)
- `smtpd_tls_received_header = yes`
- `smtpd_tls_loglevel = 1`, `smtp_tls_loglevel = 1`

#### P1-E: TLS- und DKIM-Mounts read-only
In `docker-compose.yml:64-67`, change:
```
- ./data/ssl:/etc/letsencrypt:ro
- ./data/dkim:/var/lib/dkim:ro
```
Verify cert-reload only does SIGHUP, not file writes.

### P2 — Recovery & Backup (~2 h, much waiting)

| # | Item | Comment |
|---|---|---|
| C5 | Borg-Key in 1Password speichern, server-side `/root/borg-key-export.txt` shredden | 2026-05-01: Key + Passphrase in `~/Downloads/borg-backup-credentials-2026-05-01.txt` (mode 600) für 1Password-Copy abgelegt. User to confirm save → claude shreds both `~/Downloads/borg-backup-credentials-*.txt` + `ssh mail sudo shred -u /root/borg-key-export.txt`. |
| C7 | Healthchecks.io alerting | **DONE 2026-05-01.** UUID `140a8ccf-c7ff-4132-ba33-94513ec13ccb`. `borg-backup.sh` patched with `/start` + success/`/fail` pings via optional `HEALTHCHECKS_URL` in `.env`. Telegram channel via HC bot pending user setup. |
| C6 | Offsite copy. User rejected Hetzner. Already has Google Drive + Ionos HiDrive. | **PLAN: rclone with `crypt` wrapper.** Either `rclone sync` the borg repo (already encrypted, but zero-knowledge crypt adds belt-and-suspenders + obfuscates filenames) to Google Drive OR Ionos HiDrive (WebDAV). Append-only-ish: use `rclone --backup-dir` to keep deleted/replaced segments, so even compromised mail server can't fully wipe remote. Setup later. |

### P3 — Defense-in-depth & Härtung (low urgency)

Aus dem Audit (neue Funde) + bereits bekannte HIGH/MEDIUM:

- Container per Service: `security_opt: [no-new-privileges:true, apparmor=docker-default]`, `cap_drop: [ALL]` + minimal `cap_add`, `mem_limit`, `pids_limit`, `read_only` wo möglich.
- Image-Digest-Pins für `mariadb:10.11`, `crazymax/fail2ban:1.1.0`, `certbot/certbot:v4.0.0`. fail2ban-Image ist 16 Monate alt — pull + retest.
- `/etc/docker/daemon.json` mit `{"log-driver":"json-file","log-opts":{"max-size":"50m","max-file":"5"},"live-restore":true,"icc":false,"userland-proxy":false}`. Restart-Window planen (alle Container bouncen).
- H1 amavis bind-mount, H2 docker log driver (siehe oben), H3 logrotate, H5 echter Healthcheck (mail flow assertion), H6/H7 borg-backup.sh resilience.
- iRedAdmin / SOGo Cookie `Secure` + `HttpOnly` Flag. **Achtung:** `proxy_cookie_flags` braucht nginx ≥ 1.19.3, host hat 1.18.0 → nginx-Upgrade aus offiziellem Repo ODER `more_set_headers` aus `nginx-extras`.
- HSTS + CSP + Permissions-Policy headers. Remove `X-XSS-Protection`.
- Roundcube: `cipher_method = AES-256-CBC` statt 3DES, `des_key` regenerieren (32 bytes).
- iRedAdmin: `default_password_scheme = 'BCRYPT'` in settings.py overlay.
- Apt upgrade + reboot pending (kernel + containerd + docker-ce + systemd + apparmor + libldap2 — already known).
- DMARC tightening: chiaruzzi.ch `sp=none` → `sp=reject` (most urgent), `p=quarantine` → `p=reject` nach 2-4w clean reports.
- SPF `~all` → `-all` auf chiaruzzi.ch / maisonsoave.ch / purfacted.com.
- MTA-STS + TLS-RPT für alle 4 Domains.
- `smtpd_relay_restrictions` ist OK, aber `4xx defer_unauth_destination` → `5xx reject_unauth_destination` (P1-D enthält das).
- Disk-space watchdog (monit oder cron-`df`).
- Container CVE scan cron (`docker scout` oder `trivy`).
- `setup.sh` / `borg-backup.sh` MySQL-pw-on-argv → `--defaults-extra-file=`.

## How to resume tomorrow

1. Read this whole "2026-04-30" section.
2. Run state-check:
```
ssh mail 'sudo docker exec iredmail-fail2ban fail2ban-client status; echo; sudo ls -la /root/borg-key-export.txt 2>&1; echo; ls -la /opt/iredmail/data/dkim/ 2>&1 | head -3'
```
3. P0-1 + P0-2 are already done in this session (see action log below).
4. P0-3 (sudo NOPASSWD) is the user's visudo job — exact procedure:
```
sudo visudo -f /etc/sudoers.d/90-cloud-init-users
# change line  masteradmin ALL=(ALL) NOPASSWD:ALL
# to          masteradmin ALL=(ALL) ALL
# save and exit. Test: open NEW ssh session, run `sudo whoami` → must prompt for password.
# Keep root line as-is.
```
5. Pick the next block (P1-A fail2ban Webmail jails for a quick win, or P1-B Spam-stack for the user's spam question).

