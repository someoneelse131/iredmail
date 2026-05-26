# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.3.0] - 2026-05-26

### Added
- Borg backup pipeline: 4-hour cadence, deduplicating, encrypted with `repokey-blake2`, retention 6h / 14d / 8w / 12m, weekly `borg compact`. Atomic DB-dump rename so a failed `mysqldump` doesn't clobber the last good dump.
- Offsite mirror: rclone WebDAV to Ionos HiDrive after every successful Borg run. Versioned trash via `--backup-dir` for ransomware-resistance. Sub-user scope-locked to `/backup/`.
- Two independent Healthchecks.io dead-man's switches: `HEALTHCHECKS_URL` (local Borg) and `HEALTHCHECKS_OFFSITE_URL` (HiDrive sync). `/start`, success, and `/fail` pings for both legs.
- User-trained Bayes spam learning (P1-B Phase 2): Dovecot `imap_sieve` fires on IMAP COPY/APPEND in/out of Junk → `sa-learn-pipe.sh` wrapper (PATH-pinned, mode-whitelist, sudo-gated `vmail→amavis`) → `sa-learn`. Bayes DB persisted via bind mount `data/amavis-spamassassin/`. Roundcube `markasjunk` plugin enabled (IMAP-move only).
- Postfix hardening (P1-D): TLSv1.2+ mandatory in/out, `smtpd_tls_auth_only`, HELO required, VRFY off, FQDN sender/recipient checks, 5xx `reject_unauth_destination`.
- recidive fail2ban jail (6th jail): 1-week bans for repeated cross-jail offenders, `iptables-allports` on DOCKER-USER, watches own `fail2ban.log`.
- iRedAdmin fail2ban jail: SQL backend patched in Dockerfile to emit `logger.warning`, rsyslog routes `local5` → `iredadmin.log`, filter+jail bind-mounted RO.
- `scripts/restore-borg.sh` — interactive Borg restore (list / extract single file / full restore mode).
- `README-DISASTER-RECOVERY.md` — worst-case fresh-server recovery recipe.
- MTA-STS + TLS-RPT rollout spec and 16-task implementation plan (`docs/superpowers/`); not yet deployed.

### Changed
- Roundcube 1.6.6 → 1.6.15 (multiple security fixes; P1-C, commit `98c05c6`).
- `data/ssl` mounted read-only on the iredmail-core container (P1-E); certbot container keeps rw for renewal.
- Borg backup script wraps `borg create/prune/compact` so `rc=1` (warning, e.g. "file changed while we backed it up") is treated as success. Prevents transient warnings from killing the script and silently skipping the downstream offsite sync.
- `data/amavis-spamassassin/` excluded from Borg archives. Bayes hashdbs are regenerable and SDBM files are not crash-consistent to copy live; restore relies on `init.sh` bayes-bootstrap to recreate the dir + empty DB.
- `data/ssl` mount changed to ro on iredmail-core, kept rw on certbot (P1-E, commit `628a0ea`).
- Two-week observation note: `data/amavis-spamassassin/` bind mount required ownership 111:115 (in-container `amavis`) — never `chown -R` the iRedMail tree.

### Fixed
- Mail storage-path bug (2026-04-29): container recreate no longer loses messages; `init.sh` regenerates correct paths from scratch on every start, 1083+ msgs restored from TB cache, all subfolders subscribed.
- Pigeonhole `imap_sieve` config: `MOVE` is not a valid event cause; replaced with `COPY APPEND` (IMAP MOVE is COPY+EXPUNGE so COPY already catches drag-and-drop). Commit `ba7624d`.
- Amavis `local_domains_acl` not populated after rebuild → DKIM signing now works for all 4 active domains.
- Amavis ORIGINATING port 10026 wired for outbound DKIM signing; clamav-group + init-dep ordering fixes amavis startup race.
- Healthchecks.io schedule timezone set to `Europe/Zurich` (was UTC, caused 2h-offset false-DOWN alerts every cycle).
- `data/fail2ban-logs/fail2ban.log` pre-created before first start so the recidive jail doesn't abort container startup.

### Security
- Port 25 enforces TLSv1.2+ with AUTH gated on TLS, FQDN sender/recipient checks, 5xx for relay attempts.
- TLS cert volume is read-only on the iredmail-core container.
- Roundcube 1.6.15 patches CVEs accumulated since 1.6.6.

## [1.2.0] - 2026-01-15

### Changed
- Pin all Python dependencies to exact versions for reproducible builds
- Pin Docker images to specific versions (fail2ban:1.1.0, certbot:v4.0.0)
- Update s6-overlay from 3.1.6.2 to 3.2.0.3
- Update Roundcube from 1.6.6 to 1.6.12 (security fixes)
- Update iRedAPD from 5.6.0 to 5.9.1
- Update iRedAdmin from 2.6 to 2.7

### Security
- Roundcube 1.6.12 fixes XSS vulnerability via SVG animate tag
- Roundcube 1.6.12 fixes information disclosure in HTML style sanitizer

## [1.1.1] - 2026-01-15

### Fixed
- Fail2ban container restart loop due to missing/inaccessible log files
- All services now log directly to `/var/log/iredmail/` (shared volume)
- rsyslog writes mail logs to shared directory
- Dovecot, Nginx, Roundcube, and SOGo log paths updated for fail2ban integration

### Changed
- `setup_logging()` now runs on every container startup, not just first initialization
- Removed broken symlinks in favor of direct log file paths

## [1.1.0] - 2026-01-14

### Added
- UFW firewall setup script (`scripts/setup-firewall.sh`)
- Automatic firewall configuration in setup.sh
- SOGo users SQL view for proper authentication
- Session documentation in `.claude/SESSION_NOTES.md`

### Fixed
- Dovecot SQL authentication (was using system auth instead of SQL)
- Dovecot auth socket for Postfix SASL authentication
- Postfix submission (587) and smtps (465) ports not enabled
- Postfix DNS resolution in chroot environment
- Roundcube addressbook error (collected_addresses not found)
- Roundcube SMTP connection (changed from port 587 to 25 for local delivery)
- SOGo authentication (SQL view mapping mailbox columns to expected c_* columns)
- SOGo SMTP port configuration

### Changed
- SOGo now uses `sogo_users` view instead of direct mailbox table access
- Removed incomplete custom sogo.conf that was overwriting generated config

## [1.0.0] - 2026-01-14

### Added
- Initial release of iRedMail Docker
- Full mail stack: Postfix, Dovecot, Amavisd, ClamAV, SpamAssassin
- Web interfaces: Roundcube, iRedAdmin, SOGo
- Policy server: iRedAPD
- SSL/TLS: Let's Encrypt integration with auto-renewal
- Security: Fail2ban integration
- Process management: s6-overlay for service supervision
- Multi-domain support with DKIM
- Backup and restore scripts
- Certificate management script (obtain-cert.sh)
- Domain management script (add-domain.sh)

### Fixed
- All known issues from archived official iRedMail Docker image
- SASL authentication with libsasl2-modules
- Fail2ban iptables access via host network
- Password persistence across restarts
- Service auto-start with s6-overlay
- MariaDB configuration loading
