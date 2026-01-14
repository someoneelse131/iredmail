# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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
