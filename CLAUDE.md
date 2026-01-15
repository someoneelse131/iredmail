# Project: iRedMail Docker

## Overview
Production-ready iRedMail mail server running in Docker with s6-overlay for process supervision.

## Architecture
- **iredmail**: Main container with Postfix, Dovecot, Amavis, ClamAV, Nginx, Roundcube, SOGo, iRedAdmin
- **db**: MariaDB database
- **fail2ban**: Intrusion prevention (host network mode for iptables access)
- **certbot**: SSL certificate management

## Key Paths
- `rootfs/` - Files copied into the Docker image at build time
- `rootfs/etc/s6-overlay/scripts/init.sh` - Main initialization script (runs on every container start)
- `rootfs/etc/s6-overlay/s6-rc.d/` - s6 service definitions
- `config/` - Custom configuration files mounted into containers
- `data/` - Persistent data (created on remote server, not in repo)

## Logging
All services log to `/var/log/iredmail/` for fail2ban integration:
- `maillog` - Postfix (via rsyslog)
- `dovecot.log` - Dovecot
- `sogo.log` - SOGo
- `nginx-error.log` - Nginx
- `roundcube/errors.log` - Roundcube

## Deployment
This is a local development copy. Files are synced to remote server via rsync.
```bash
# On remote server:
docker compose down
docker compose build --no-cache
docker compose up -d
```

## Git Commits
- Never mention "Claude Code" or include "Co-Authored-By: Claude" in commit messages
- Keep commit messages concise and descriptive of the actual changes
