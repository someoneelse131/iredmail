# iRedMail server — progress

Active log. Pre-2026-05-01 history is in `progress-archive.md` (562-line incident timeline + 4-agent audit findings + full P3 backlog).

## Status — 2026-05-02

| Area | State |
|---|---|
| Mail persistence | Storage-path bug fixed 2026-04-29. Container recreate no longer loses data. 1083+ msgs restored from TB cache, all subfolders subscribed. |
| Backup — local | Borg 4h, encrypted (`repokey-blake2`), dedup ~250×, repo ~99 MB at `/opt/iredmail/data/borg-repo`. Cron `15 */4 * * *` verified firing. Old `backup.sh` daily 02:00 still running as safety net (retire ~2026-05-13). |
| Backup — alerting | Two independent Healthchecks.io checks. Local borg: `HEALTHCHECKS_URL=…/140a8ccf-…` (existed). Offsite: `HEALTHCHECKS_OFFSITE_URL=…/5e26d866-…` (added 2026-05-02). Each gets `/start` + success + `/fail` pings, so a silent HiDrive outage alerts independently from a successful local borg. |
| Backup — offsite | **ACTIVE** (C6 done 2026-05-01, paths reorganised + alerting dedicated 2026-05-02). rclone WebDAV → Ionos HiDrive 100 GB (1.36 €/mo). Sub-user `hidrive-kirby-backup`, locked to `/backup/` (HiDrive returns 403 on writes outside it — verified). Layout: `hidrive:/backup/iredmail/data/` (borg repo, 188 obj / 97 MiB) + `hidrive:/backup/iredmail/.trash/<ts>/` (versioned trash from `--backup-dir`). Mirrors after every borg run. `--backup-dir` keeps replaced/deleted segments → ransomware-from-server can't wipe history. Restore: `rclone copy hidrive:/backup/iredmail/data /opt/iredmail/data/borg-repo`. |
| Borg key | In 1Password + paper. Server `/root/borg-key-export.txt` shredded 2026-05-01. |
| Spam stack | amavis 10024 (inbound) + 10025 (re-injection) + 10026 (ORIGINATING, signs DKIM outbound). SA scoring `tag2=5.0 kill=9.0`, `D_PASS`. ClamAV runs. Sieve `before.d/spam-to-junk.sieve` files `X-Spam-Flag:YES` → Junk. DKIM signing for all 4 domains; verifier.port25.com confirms `dkim=pass spf=pass iprev=pass` for kirby.rocks (final domain verified 2026-05-01 16:50 after DNS update). |
| fail2ban (container) | 4 jails active: dovecot (`findtime=3600 maxretry=3` for distributed brute-force), postfix-sasl (8500+ bans), roundcube-auth, sogo-auth. **2 jails still missing: iRedAdmin web panel (= top of pick-next), recidive cross-jail repeater.** |
| fail2ban (host) | sshd jail. 1428+ bans. |
| SSH | Password auth disabled (cloud-init drop-in renamed to `.disabled`). |
| Permissions | `.env` 600. `data/backup/*.tar.gz` 600. All `privkey*.pem` 600. UID alignment vmail 2000:2000 host↔container. |
| TLS | Cert valid until 2026-07-19, ECDSA, certbot renewal cron OK. |

## Open — pick next

In risk × effort order. Pull from top. **Top two were promoted from P3 backlog on 2026-05-01 after user identified the gaps: brute-force closure on iRedAdmin and cross-jail repeat-offenders.**

1. **iRedAdmin fail2ban jail** — only auth surface NOT currently bannable. **Plan finalised 2026-05-02 after reconnaissance**:

   *Key finding that invalidated the older plan:* the LDAP backend's `controllers/ldap/basic.py:73` emits `logger.warning("Web login failed: client_address={}, username={}".format(web.ctx.ip, username))`, but **the active SQL backend's `controllers/sql/basic.py:74` does NOT** — it just `raise web.seeother('/login?msg=INVALID_CREDENTIALS')`. Triggered a real failed POST and confirmed: zero log line emitted. nginx access.log shows the POST line but its default `combined` format omits `$sent_http_location`, so the redirect target isn't visible there either. → no usable signal exists today.

   **Path forward (c): patch iRedAdmin SQL controller to emit the same warning the LDAP path emits, route iRedAdmin's syslog to a dedicated file in the shared `/var/log/iredmail/` volume, then standard filter+jail.**

   - **Dockerfile change** — after the iRedAdmin tarball extract block (`Dockerfile:154-158`, `RUN curl … | tar -xz -C /var/www/iredadmin …`), add a sed step in the same RUN to insert one line before the `INVALID_CREDENTIALS` redirect:
     ```
     sed -i "/raise web.seeother('\/login?msg=INVALID_CREDENTIALS')/i\\            logger.warning(\"Web login failed: client_address={}, username={}\".format(web.ctx.ip, username))" \
         /var/www/iredadmin/controllers/sql/basic.py
     ```
     `web` and `logger` are already in scope in that file (it uses `web.input`/`web.seeother`, and imports `logger` via `from libs.logger import logger` — verify before sed). Indent must be 12 spaces (matches existing line).

   - **rsyslog routing** — append to `rootfs/etc/rsyslog.d/50-iredmail.conf`:
     ```
     # Route iRedAdmin (program name "iredadmin", local5 facility) to its own
     # file in the shared volume, so the fail2ban container can read it.
     :programname, isequal, "iredadmin"   /var/log/iredmail/iredadmin.log
     & stop
     ```
     fail2ban already mounts `/opt/iredmail/data/logs` → `/var/log/iredmail` RO (see `docker-compose.yml:110`).

   - **New filter** `config/fail2ban/filter.d/iredadmin.conf`:
     ```
     [Definition]
     failregex = ^.*iredadmin Web login failed: client_address=<HOST>, username=
     ignoreregex =
     ```
     The `iredadmin` program-name prefix is rsyslog's, not iRedAdmin's — set by `logger = logging.getLogger("iredadmin")` in `/var/www/iredadmin/libs/logger.py`.

   - **Append to `config/fail2ban/jail.d/iredmail.local`**:
     ```
     [iredadmin]
     enabled = true
     filter = iredadmin
     action = iptables-multiport[name=iredadmin, port="80,443", protocol=tcp, chain=DOCKER-USER]
     logpath = /var/log/iredmail/iredadmin.log
     maxretry = 5
     ```

   - **Apply on running server (without rebuild)** so we can verify before committing the Dockerfile change:
     1. `docker exec iredmail-core sed -i …` (same sed as above)
     2. `docker exec iredmail-core sh -c "echo … >> /etc/rsyslog.d/50-iredmail.conf && pkill -HUP rsyslogd"`
     3. `touch /opt/iredmail/data/logs/iredadmin.log; chown 102:106 …` (rsyslog runs as syslog:adm in this image — check uid)
     4. Drop the new filter + jail snippet into `/opt/iredmail/config/fail2ban/`
     5. `docker exec iredmail-fail2ban fail2ban-client reload`

   - **Verify**:
     - Trigger a failed login: `curl -sk -X POST https://mail.kirby.rocks/iredadmin/login -d "username=postmaster@kirby.rocks&password=wrong"` — should land in `/var/log/iredmail/iredadmin.log` as `… mail iredadmin iredadmin Web login failed: client_address=<IP>, username=postmaster@kirby.rocks (…)`
     - `fail2ban-regex /var/log/iredmail/iredadmin.log /etc/fail2ban/filter.d/iredadmin.conf` — should match.
     - 5 fails in `findtime` from one IP → `fail2ban-client status iredadmin` lists banned IP.
     - `fail2ban-client status` now shows **5 jails** (was 4: dovecot, postfix-sasl, roundcube-auth, sogo-auth).

   - **Then commit**: Dockerfile sed step + rootfs/etc/rsyslog.d/50-iredmail.conf addition + config/fail2ban/{filter.d/iredadmin.conf, jail.d/iredmail.local}. Idempotent across container rebuilds.

   - **Watch out for noise**: Uptime-Kuma at `212.227.103.144` hits `/iredadmin` every minute (visible in `docker logs iredmail-core`). The failregex only matches `Web login failed:` warnings, not GETs, so monitor traffic won't trip the jail.

2. **recidive jail (cross-jail repeat-offender)** — currently bans inside one jail expire and the same IP comes back from a different jail. Recidive watches `fail2ban.log` and bans IPs that get banned ≥3× across all jails for a long window (e.g. 1 week). Container's fail2ban currently doesn't write `fail2ban.log` — need:
   - `loglevel = INFO` and `logtarget = /var/log/fail2ban/fail2ban.log` in `fail2ban.local` of the container.
   - Mount that log volume so it persists.
   - Add `[recidive] enabled=true bantime=1w findtime=1d maxretry=3 logpath=/var/log/fail2ban/fail2ban.log`.
   - Verify by manually banning an IP three times in different jails → recidive should pick it up.

3. **P1-B Phase 2 — learning spam filter** — add imap_sieve plugin + sa-learn pipe scripts (Junk move → `sa-learn --spam`, out-of-Junk → `sa-learn --ham`). Roundcube `markasjunk` plugin for visible Spam button. Note: cron/postmaster local sendmail goes through 10024 → unsigned. Low priority.
4. **P1-C Roundcube CVE pin** — bump from 1.6.6 → 1.6.10+ in Dockerfile (CVE-2024-37383 / 42008 / 42009 / 42010). Add nginx `deny` for `/mail/composer.*`, `/mail/SQL/`, `/mail/installer/`, `/mail/INSTALL`, `/mail/UPGRADING`, `/mail/SECURITY.md`, `/mail/CHANGELOG.md`, `/mail/vendor/`, `/mail/bin/`. Dockerfile `RUN rm -rf /var/www/roundcube/installer`.
5. **P1-D Postfix hardening** — see "P1-D values" below for the full list.
6. **P1-E read-only mounts** — `docker-compose.yml:64-67`: append `:ro` to `./data/ssl:/etc/letsencrypt` and `./data/dkim:/var/lib/dkim`. Verify cert-reload only does SIGHUP.
7. **P0-3 sudo NOPASSWD** — user job (visudo on server). Procedure:
   ```
   sudo visudo -f /etc/sudoers.d/90-cloud-init-users
   # change:  masteradmin ALL=(ALL) NOPASSWD:ALL  →  masteradmin ALL=(ALL) ALL
   # test in NEW ssh session: `sudo whoami` must prompt for password.
   ```
8. **P3 backlog** — see `progress-archive.md` "P3" sections. Highlights: SOGo memcached broken (floods sogo.log), H1 amavis bind-mount, H2 docker log driver + `live-restore`, H3 logrotate iRedMail logs, H5 real mailflow healthcheck, H6/H7 borg-backup.sh resilience patches, MTA-STS + TLS-RPT, HSTS, BCRYPT in iRedAdmin, container `no-new-privileges`/cap drops, kernel reboot pending.

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
