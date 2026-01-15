# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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
