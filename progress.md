# iRedMail server — progress

Active log. Pre-2026-05-01 history is in `progress-archive.md` (562-line incident timeline + 4-agent audit findings + full P3 backlog).

## Status — 2026-05-04

| Area | State |
|---|---|
| Mail persistence | Storage-path bug fixed 2026-04-29. Container recreate no longer loses data. 1083+ msgs restored from TB cache, all subfolders subscribed. |
| Backup — local | Borg 4h, encrypted (`repokey-blake2`), dedup ~250×, repo ~94 MB at `/opt/iredmail/data/borg-repo`. Cron `15 */4 * * *` verified firing. Old `backup.sh` daily 02:00 still running as safety net (retire ~2026-05-13). |
| Backup — alerting | Two independent Healthchecks.io checks. Local borg: `HEALTHCHECKS_URL=…/140a8ccf-…` (existed). Offsite: `HEALTHCHECKS_OFFSITE_URL=…/5e26d866-…` (added 2026-05-02). Each gets `/start` + success + `/fail` pings, so a silent HiDrive outage alerts independently from a successful local borg. **Gotcha (2026-05-02):** Schedule-Time-Zone auf hc.io muss `Europe/Zurich` sein (nicht `UTC`), sonst feuert die Cron-Expression `15 */4 * * *` 2h verschoben gegen die Server-CEST-Pings → konstante 30min-Grace-DOWN-Alerts. Beide Checks auf `Europe/Zurich` gesetzt. |
| Backup — offsite | **ACTIVE** (C6 done 2026-05-01, paths reorganised + alerting dedicated 2026-05-02). rclone WebDAV → Ionos HiDrive 100 GB (1.36 €/mo). Sub-user `hidrive-kirby-backup`, locked to `/backup/` (HiDrive returns 403 on writes outside it — verified). Layout: `hidrive:/backup/iredmail/data/` (borg repo) + `hidrive:/backup/iredmail/.trash/<ts>/` (versioned trash from `--backup-dir`). Mirrors after every borg run. `--backup-dir` keeps replaced/deleted segments → ransomware-from-server can't wipe history. Restore: `rclone copy hidrive:/backup/iredmail/data /opt/iredmail/data/borg-repo`. |
| Borg key | In 1Password + paper. Server `/root/borg-key-export.txt` shredded 2026-05-01. |
| Spam stack | amavis 10024 (inbound) + 10025 (re-injection) + 10026 (ORIGINATING, signs DKIM outbound). SA scoring `tag2=5.0 kill=9.0`, `D_PASS`. ClamAV runs. Sieve `before.d/spam-to-junk.sieve` files `X-Spam-Flag:YES` → Junk. **Bayes-learning (P1-B Phase 2) live 2026-05-04:** Dovecot imap_sieve fires on user IMAP COPY/MOVE/APPEND in/out of Junk → `sa-learn-pipe.sh` wrapper (PATH-pinned, mode-whitelist, sudo-gated to `vmail→amavis`) → `sa-learn`. Bayes DB persisted via bind mount `data/amavis-spamassassin/` (was in writable layer pre-migration → wiped on rebuild). Roundcube `markasjunk` plugin enabled (IMAP-move only, `learning_driver=null` so the sieve is the single training path). Host cron `*/15 * * * *` runs `sa-learn --sync` to flush journal. DKIM signing for all 4 domains; verifier.port25.com confirms `dkim=pass spf=pass iprev=pass` for kirby.rocks (final domain verified 2026-05-01 16:50 after DNS update). |
| fail2ban (container) | **6 jails active** (recidive added 2026-05-02): dovecot (`findtime=3600 maxretry=3` for distributed brute-force), postfix-sasl (8500+ bans), roundcube-auth, sogo-auth, iredadmin, recidive (`bantime=1w findtime=1d maxretry=3`, `iptables-allports` on DOCKER-USER, watches own `fail2ban.log`). **Brute-force surface fully closed.** Note: `F2B_LOG_TARGET=/var/log/fail2ban/fail2ban.log` and persistent volume `data/fail2ban-logs` are required prerequisites — if either is missing the recidive jail aborts container startup with "Have not found any log file". On fresh deploys: `mkdir -p data/fail2ban-logs && touch data/fail2ban-logs/fail2ban.log` before first `docker compose up`. |
| fail2ban (host) | sshd jail. 1428+ bans. |
| SSH | Password auth disabled (cloud-init drop-in renamed to `.disabled`). |
| Permissions | `.env` 600. `data/backup/*.tar.gz` 600. All `privkey*.pem` 600. UID alignment vmail 2000:2000 host↔container. |
| TLS | Cert valid until 2026-07-19, ECDSA, certbot renewal cron OK. |

## Open — pick next

In risk × effort order. Pull from top. **P1-B Phase 2 spam-learning live 2026-05-04 (see "What's SOLID"); P1-C Roundcube CVE pin is now top.**

1. **P1-C Roundcube CVE pin** — bump from 1.6.6 → 1.6.10+ in Dockerfile (CVE-2024-37383 / 42008 / 42009 / 42010). Add nginx `deny` for `/mail/composer.*`, `/mail/SQL/`, `/mail/installer/`, `/mail/INSTALL`, `/mail/UPGRADING`, `/mail/SECURITY.md`, `/mail/CHANGELOG.md`, `/mail/vendor/`, `/mail/bin/`. Dockerfile `RUN rm -rf /var/www/roundcube/installer`.
2. **P1-D Postfix hardening** — see "P1-D values" below for the full list.
3. **P1-E read-only mounts** — `docker-compose.yml:64-67`: append `:ro` to `./data/ssl:/etc/letsencrypt` and `./data/dkim:/var/lib/dkim`. Verify cert-reload only does SIGHUP.
4. **P1-B Phase 2 — user-UI verification matrix** (carried over from 2026-05-04 deploy). Spam-learning is live and 7/11 tests passed programmatically; the 4 IMAP-driven tests require a real client (Roundcube + Thunderbird) — see "P1-B residual user tests" below.
5. **P0-3 sudo NOPASSWD** — user job (visudo on server). Procedure:
   ```
   sudo visudo -f /etc/sudoers.d/90-cloud-init-users
   # change:  masteradmin ALL=(ALL) NOPASSWD:ALL  →  masteradmin ALL=(ALL) ALL
   # test in NEW ssh session: `sudo whoami` must prompt for password.
   ```
6. **P3 backlog** — see `progress-archive.md` "P3" sections. Highlights: SOGo memcached broken (floods sogo.log), H1 amavis bind-mount (DONE 2026-05-04 as part of P1-B Phase 2), H2 docker log driver + `live-restore`, H3 logrotate iRedMail logs, H5 real mailflow healthcheck, H6/H7 borg-backup.sh resilience patches, MTA-STS + TLS-RPT, HSTS, BCRYPT in iRedAdmin, container `no-new-privileges`/cap drops, kernel reboot pending.

## P1-B residual user tests

These need a real IMAP client (Roundcube + Thunderbird) — `doveadm move` bypasses `imap_sieve` per Pigeonhole docs, so they couldn't be automated.

- [ ] **Step 3 — Roundcube spam-learn:** send a fresh non-GTUBE test mail to a regular user inbox; in Roundcube webmail, select → "Mark as junk" button. Verify mail moves to Junk and `nspam` increments by 1 (`ssh mail 'sudo /usr/bin/timeout 60 /usr/bin/docker exec --user amavis iredmail-core /usr/bin/sa-learn --sync && sudo docker exec --user amavis iredmail-core sa-learn --dump magic | grep nspam'`).
- [ ] **Step 4 — Thunderbird drag spam:** repeat with TB drag-to-Junk on a different fresh test mail. Sync, expect another `nspam` +1.
- [ ] **Step 5 — Ham-learn (drag back):** drag a clean message from Junk to INBOX. Sync, expect `nham` +1.
- [ ] **Step 6 — Re-classification refusal:** move the same mail BACK toward the wrong direction (Junk-trained mail back to INBOX). Expect `nham` UNCHANGED and a `mail.warning sa-learn-pipe ... err=…` line in `/opt/iredmail/data/logs/maillog` (sa-learn refuses opposite class).
- [ ] **Step 9 — Pipe size DoS guard runtime:** static check passes (sieve has `if size :over 10M { stop; }`, sievec compiled clean). Programmatic test would need a real IMAP APPEND >10 MB into Junk. If you ever want to confirm runtime, IMAP-APPEND a 20 MB payload from Roundcube/TB into Junk and verify NO `sa-learn-pipe trained` line appears in maillog.

## P1-D values — concrete diff for `init.sh` postfix gen block

- `smtpd_tls_auth_only = yes`           (eliminates cleartext AUTH on 25)
- `smtpd_tls_protocols = >=TLSv1.2`
- `smtpd_tls_mandatory_protocols = >=TLSv1.2`
- `smtp_tls_protocols = >=TLSv1.2`        (outbound)
- `smtp_tls_mandatory_protocols = >=TLSv1.2`
- `smtpd_tls_ciphers = high`
- `smtpd_tls_mandatory_ciphers = high`
- `tls_preempt_cipherlist = yes`
- `smtpd_tls_eecdh_grade = ultra`
- `smtpd_helo_required = yes`
- `disable_vrfy_command = yes`
- `smtpd_helo_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname`
- `smtpd_sender_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_non_fqdn_sender, reject_unknown_sender_domain`
- `smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_non_fqdn_recipient, reject_unknown_recipient_domain, reject_unauth_destination, check_policy_service unix:private/policyd-spf`
- `smtpd_data_restrictions = reject_unauth_pipelining`
- `smtpd_relay_restrictions`: switch final action `defer_unauth_destination` → `reject_unauth_destination` (5xx instead of 4xx)
- `smtpd_sasl_authenticated_header = yes`
- `smtpd_tls_received_header = yes`
- `smtpd_tls_loglevel = 1`, `smtp_tls_loglevel = 1`

## What's SOLID — DON'T re-investigate

- Storage-path fix durable: inodes identical host↔container, `init.sh` regenerates correct paths from scratch on every container start, all 10 DB rows consistent (`storagebasedirectory='/var/vmail', storagenode='vmail1'`).
- Borg pipeline: `borg check --repository-only` clean, atomic `.tmp` rename for DB dump, restore-drill bit-identical.
- Repo == server: `sha256sum init.sh + docker-compose.yml` identical.
- Open-relay closed (`smtpd_relay_restrictions` correct).
- Docker socket NOT mounted into any container.
- AppArmor enforcing (`docker-default`).
- E2E tested via python smtplib → :25:
  - clean (score 3.5) → INBOX, `X-Spam-Flag: NO`
  - GTUBE (score 1003) → Junk via sieve, `[SPAM]` subject prefix
  - EICAR → `Blocked INFECTED (Eicar-Signature) {DiscardedInbound,Quarantined}`
  - inbound DKIM verify works (real simplelogin.co mail came with `dkim_sd=`).
- Verifier.port25.com confirms outbound: `kirby.rocks dkim=pass spf=pass iprev=pass header.d=kirby.rocks`. (Other 3 domains verified earlier in same session.)
- iRedAdmin fail2ban jail (closed 2026-05-02): SQL backend's `controllers/sql/basic.py` patched in Dockerfile to emit `logger.warning` (LDAP backend already does), rsyslog routes facility `local5` → `/var/log/iredmail/iredadmin.log`, fail2ban filter+jail bind-mounted RO. End-to-end verified: 6 fail-POSTs → ban triggered, iptables `f2b-iredadmin` chain in DOCKER-USER, unban clean. Persistent across container rebuild (Dockerfile sed has `grep -q` + `py_compile` guards that fail the build if upstream renames the patched lines). Independently re-verified by 2 agents.
- recidive jail (closed 2026-05-02): docker-compose `F2B_LOG_TARGET` → `/var/log/fail2ban/fail2ban.log` + persistent volume `data/fail2ban-logs`, jail watches own log with `bantime=1w findtime=1d maxretry=3` and `iptables-allports[chain=DOCKER-USER]`. End-to-end verified: 3 manual bans for TEST-NET IP `198.51.100.99` from iredadmin/postfix-sasl/dovecot triggered the recidive ban exactly at the 3rd hit (`NOTICE [recidive] Ban 198.51.100.99` in fail2ban.log), unbanned clean across all 4 jails.
- **Bayes-learning live (P1-B Phase 2 done 2026-05-04):**
  - 8 commits a3d57ff…8b89c5e (Dockerfile sudo + visudo build-gate, sudoers `vmail→amavis spam|ham only`, `sa-learn-pipe.sh` wrapper, two `imap_sieve` sieves, dovecot conf merge, `init.sh` bayes-bootstrap + sievec loop, compose bind mount `data/amavis-spamassassin`, Roundcube `markasjunk` plugin). Each implemented + reviewed (spec + quality) by isolated subagents.
  - Server migration ~38s mailflow downtime: pre-built image while old container running, then stop → `docker cp` Bayes DB to host bind mount (uid 111:115, dir 0700, files 0600) → `docker compose up -d` (no `--build`) → all ports 25/143/10024/10025/10026 live.
  - Verification matrix programmatic 7/11 PASS (1 SA-username = amavis, 2 LMTP no-trigger, 7 sudo argv mismatch, 8 sudo `-E` blocked by `env_reset`, 10 Bayes survives container restart, 11 borg archive includes `opt/iredmail/data/amavis-spamassassin/{bayes_seen,bayes_toks}` 0600 111:115). Step 9 (pipe size DoS) static-PASS (`if size :over 10M { stop; }` present, sievec compiled). Steps 3,4,5,6 carried over to "P1-B residual user tests" — `doveadm move` bypasses `imap_sieve` per Pigeonhole docs, real RC/TB IMAP needed.
  - Host cron `*/15 * * * *` (`/etc/cron.d/sa-learn-sync`) flushes Bayes journal via `docker exec --user amavis sa-learn --sync`. Manual one-shot returned OK.
  - Pre-migration baseline `/tmp/bayes-pre.txt` (laptop) + `/tmp/iredmail-pre-spamlearn-snapshot/` (server) preserve the 5 originals (Dockerfile, docker-compose.yml, 91-iredmail-sieve.conf, init.sh, roundcube/config.inc.php) for rollback if a regression surfaces in the next 24h.

## How to resume

1. Read this file. For pre-2026-05-01 history (incident timeline, audit details, full P3 list) → `progress-archive.md`.
2. State-check (expect **6 jails**, amavis ports listening, Bayes bind-mount populated, sa-learn cron present):
   ```
   ssh mail 'sudo docker exec iredmail-fail2ban fail2ban-client status; \
     sudo docker exec iredmail-core ss -ltn | grep -E "10024|10025|10026"; \
     sudo ls -la /opt/iredmail/data/amavis-spamassassin/; \
     sudo cat /etc/cron.d/sa-learn-sync; \
     sudo docker exec --user amavis iredmail-core sa-learn --dump magic | grep -E "nspam|nham|ntokens"; \
     sudo grep -E "^HEALTHCHECKS" /opt/iredmail/.env'
   ```
3. **P1-B Phase 2 residual:** Steps 3,4,5,6 of the verification matrix are user-UI tests (Roundcube + Thunderbird). See "P1-B residual user tests" above — pick a regular user mailbox (NOT postmaster — its Junk folder doesn't exist), do the 4 IMAP-driven moves, expect `nspam` / `nham` increments. After ~24h of real usage with no regressions, delete the rollback artefacts:
   - `ssh mail 'sudo rm -rf /tmp/iredmail-pre-spamlearn-snapshot'`
   - laptop: `rm -f /tmp/bayes-pre.txt`
4. **Server `/opt/iredmail/` git tree** still months out-of-sync with `origin/main`. Files are now even more divergent after the 2026-05-04 deploy (we scp'd 9 files in directly per Task 10 plan). `git pull` on server would conflict heavily. Reconcile via either: (a) `cd /opt/iredmail && sudo git fetch && sudo git reset --hard origin/main` once we trust the deploy is stable, or (b) keep the deploy-via-scp pattern and never touch git on the server. See todo.md "Cleanup ideas".
5. Other items in "Open — pick next" can be picked up freely now.

## Open questions

See `todo.md`.
