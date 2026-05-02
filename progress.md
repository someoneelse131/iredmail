# iRedMail server — progress

Active log. Pre-2026-05-01 history is in `progress-archive.md` (562-line incident timeline + 4-agent audit findings + full P3 backlog).

## Status — 2026-05-02

| Area | State |
|---|---|
| Mail persistence | Storage-path bug fixed 2026-04-29. Container recreate no longer loses data. 1083+ msgs restored from TB cache, all subfolders subscribed. |
| Backup — local | Borg 4h, encrypted (`repokey-blake2`), dedup ~250×, repo ~99 MB at `/opt/iredmail/data/borg-repo`. Cron `15 */4 * * *` verified firing. Old `backup.sh` daily 02:00 still running as safety net (retire ~2026-05-13). |
| Backup — alerting | Two independent Healthchecks.io checks. Local borg: `HEALTHCHECKS_URL=…/140a8ccf-…` (existed). Offsite: `HEALTHCHECKS_OFFSITE_URL=…/5e26d866-…` (added 2026-05-02). Each gets `/start` + success + `/fail` pings, so a silent HiDrive outage alerts independently from a successful local borg. **Gotcha (2026-05-02):** Schedule-Time-Zone auf hc.io muss `Europe/Zurich` sein (nicht `UTC`), sonst feuert die Cron-Expression `15 */4 * * *` 2h verschoben gegen die Server-CEST-Pings → konstante 30min-Grace-DOWN-Alerts. Beide Checks auf `Europe/Zurich` gesetzt. |
| Backup — offsite | **ACTIVE** (C6 done 2026-05-01, paths reorganised + alerting dedicated 2026-05-02). rclone WebDAV → Ionos HiDrive 100 GB (1.36 €/mo). Sub-user `hidrive-kirby-backup`, locked to `/backup/` (HiDrive returns 403 on writes outside it — verified). Layout: `hidrive:/backup/iredmail/data/` (borg repo, 188 obj / 97 MiB) + `hidrive:/backup/iredmail/.trash/<ts>/` (versioned trash from `--backup-dir`). Mirrors after every borg run. `--backup-dir` keeps replaced/deleted segments → ransomware-from-server can't wipe history. Restore: `rclone copy hidrive:/backup/iredmail/data /opt/iredmail/data/borg-repo`. |
| Borg key | In 1Password + paper. Server `/root/borg-key-export.txt` shredded 2026-05-01. |
| Spam stack | amavis 10024 (inbound) + 10025 (re-injection) + 10026 (ORIGINATING, signs DKIM outbound). SA scoring `tag2=5.0 kill=9.0`, `D_PASS`. ClamAV runs. Sieve `before.d/spam-to-junk.sieve` files `X-Spam-Flag:YES` → Junk. DKIM signing for all 4 domains; verifier.port25.com confirms `dkim=pass spf=pass iprev=pass` for kirby.rocks (final domain verified 2026-05-01 16:50 after DNS update). |
| fail2ban (container) | **5 jails active** (added iredadmin 2026-05-02): dovecot (`findtime=3600 maxretry=3` for distributed brute-force), postfix-sasl (8500+ bans), roundcube-auth, sogo-auth, iredadmin (`maxretry=5`, action chain DOCKER-USER on 80,443, logpath `/var/log/iredmail/iredadmin.log`). **1 jail still missing: recidive cross-jail repeater.** |
| fail2ban (host) | sshd jail. 1428+ bans. |
| SSH | Password auth disabled (cloud-init drop-in renamed to `.disabled`). |
| Permissions | `.env` 600. `data/backup/*.tar.gz` 600. All `privkey*.pem` 600. UID alignment vmail 2000:2000 host↔container. |
| TLS | Cert valid until 2026-07-19, ECDSA, certbot renewal cron OK. |

## Open — pick next

In risk × effort order. Pull from top. **iRedAdmin jail (was top) closed 2026-05-02; recidive cross-jail repeat-offender now leads.**

1. **recidive jail (cross-jail repeat-offender)** — currently bans inside one jail expire and the same IP comes back from a different jail. Recidive watches `fail2ban.log` and bans IPs that get banned ≥3× across all jails for a long window (e.g. 1 week). Container's fail2ban currently doesn't write `fail2ban.log` — need:
   - `loglevel = INFO` and `logtarget = /var/log/fail2ban/fail2ban.log` in `fail2ban.local` of the container.
   - Mount that log volume so it persists.
   - Add `[recidive] enabled=true bantime=1w findtime=1d maxretry=3 logpath=/var/log/fail2ban/fail2ban.log`.
   - Verify by manually banning an IP three times in different jails → recidive should pick it up.

2. **P1-B Phase 2 — learning spam filter** — add imap_sieve plugin + sa-learn pipe scripts (Junk move → `sa-learn --spam`, out-of-Junk → `sa-learn --ham`). Roundcube `markasjunk` plugin for visible Spam button. Note: cron/postmaster local sendmail goes through 10024 → unsigned. Low priority.
3. **P1-C Roundcube CVE pin** — bump from 1.6.6 → 1.6.10+ in Dockerfile (CVE-2024-37383 / 42008 / 42009 / 42010). Add nginx `deny` for `/mail/composer.*`, `/mail/SQL/`, `/mail/installer/`, `/mail/INSTALL`, `/mail/UPGRADING`, `/mail/SECURITY.md`, `/mail/CHANGELOG.md`, `/mail/vendor/`, `/mail/bin/`. Dockerfile `RUN rm -rf /var/www/roundcube/installer`.
4. **P1-D Postfix hardening** — see "P1-D values" below for the full list.
5. **P1-E read-only mounts** — `docker-compose.yml:64-67`: append `:ro` to `./data/ssl:/etc/letsencrypt` and `./data/dkim:/var/lib/dkim`. Verify cert-reload only does SIGHUP.
6. **P0-3 sudo NOPASSWD** — user job (visudo on server). Procedure:
   ```
   sudo visudo -f /etc/sudoers.d/90-cloud-init-users
   # change:  masteradmin ALL=(ALL) NOPASSWD:ALL  →  masteradmin ALL=(ALL) ALL
   # test in NEW ssh session: `sudo whoami` must prompt for password.
   ```
7. **P3 backlog** — see `progress-archive.md` "P3" sections. Highlights: SOGo memcached broken (floods sogo.log), H1 amavis bind-mount, H2 docker log driver + `live-restore`, H3 logrotate iRedMail logs, H5 real mailflow healthcheck, H6/H7 borg-backup.sh resilience patches, MTA-STS + TLS-RPT, HSTS, BCRYPT in iRedAdmin, container `no-new-privileges`/cap drops, kernel reboot pending.

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
- iRedAdmin fail2ban jail (closed 2026-05-02): SQL backend's `controllers/sql/basic.py` patched in Dockerfile to emit `logger.warning` (LDAP backend already does), rsyslog routes facility `local5` → `/var/log/iredmail/iredadmin.log`, fail2ban filter+jail bind-mounted RO. End-to-end verified: 6 fail-POSTs → ban triggered, iptables `f2b-iredadmin` chain in DOCKER-USER, unban clean. Persistent across container rebuild (Dockerfile sed has `grep -q` + `py_compile` guards that fail the build if upstream renames the patched lines).

## How to resume

1. Read this file. For pre-2026-05-01 history (incident timeline, audit details, full P3 list) → `progress-archive.md`.
2. State-check:
   ```
   ssh mail 'sudo docker exec iredmail-fail2ban fail2ban-client status; \
     sudo docker exec iredmail-core ss -ltn | grep -E "10024|10025|10026"; \
     sudo borg list /opt/iredmail/data/borg-repo | tail -3'
   ```
3. Pick next from "Open — pick next" above.

## Open questions

See `todo.md`.
