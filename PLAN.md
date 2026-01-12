# Dockerized iRedMail Mail Server - Implementation Plan

## Overview

A production-ready, dockerized iRedMail mail server that fixes all known issues with the archived official Docker version.

**Your Requirements:**
- iRedMail-based mail server
- Full stack: Roundcube, iRedAdmin, ClamAV, SpamAssassin, DKIM
- SOGo for calendar/contacts/ActiveSync
- Single domain to start, multi-domain support for later
- All free/open source components

---

## Architecture Decision: Hybrid Approach

| Container | Components | Purpose |
|-----------|------------|---------|
| **iredmail-core** | Postfix, Dovecot, Amavisd, ClamAV, SpamAssassin, iRedAPD, Nginx, PHP-FPM, Roundcube, iRedAdmin, SOGo | All mail + web services |
| **iredmail-db** | MariaDB 10.11 | Database (separate for safety/backups) |
| **iredmail-fail2ban** | Fail2ban | Intrusion prevention (host network) |
| **iredmail-certbot** | Certbot | SSL auto-renewal |

**Why hybrid instead of microservices?**
- Mail components (Postfix/Dovecot/Amavisd) are tightly coupled via sockets and queues
- Reduces complexity without sacrificing reliability
- Database separation allows independent backups and scaling

---

## Known Issues & Fixes

| Issue | Problem | Solution |
|-------|---------|----------|
| #1 | Archived/unstable | Build custom image from scratch |
| #2 | Custom config ignored | Enhanced entrypoint with explicit custom.sh execution |
| #3 | SASL auth fails | Install libsasl2-modules, configure Dovecot auth socket |
| #4 | Fail2ban/iptables | Separate container on host network with NET_ADMIN |
| #5 | Passwords reset on restart | Fixed passwords via .env, persistence check |
| #6 | Services not auto-starting | s6-overlay init system with proper dependencies |
| #7 | MariaDB settings ignored | Fix file permissions, separate container |
| #9 | Cloudflare/proxy issues | Nginx real_ip configuration |

---

## Technical Stack

- **Base OS:** Ubuntu 22.04 LTS
- **Init System:** s6-overlay v3 (proper PID 1, service dependencies, zombie reaping)
- **Database:** MariaDB 10.11 (external container)
- **Mail:** Postfix + Dovecot + Amavisd + ClamAV + SpamAssassin
- **Web:** Nginx + PHP-FPM + Roundcube + iRedAdmin + SOGo
- **SSL:** Let's Encrypt via Certbot

---

## Project Structure

```
/home/masteradmin/projects/github/iredadmin/
├── docker-compose.yml
├── Dockerfile
├── .env.example
├── .gitignore
├── README.md
├── rootfs/
│   └── etc/
│       └── s6-overlay/
│           ├── s6-rc.d/           # Service definitions
│           │   ├── postfix/
│           │   ├── dovecot/
│           │   ├── amavisd/
│           │   ├── clamav/
│           │   ├── nginx/
│           │   ├── php-fpm/
│           │   ├── sogo/
│           │   └── iredapd/
│           └── scripts/
│               ├── init.sh
│               └── configure-services.sh
├── config/
│   ├── mariadb/
│   │   └── custom.cnf
│   ├── postfix/
│   │   └── custom.sh
│   ├── dovecot/
│   │   └── custom.conf
│   ├── amavis/
│   │   └── 99-custom.conf
│   ├── nginx/
│   │   ├── nginx.conf
│   │   └── sites/
│   ├── roundcube/
│   │   └── config.inc.php
│   ├── sogo/
│   │   └── sogo.conf
│   └── fail2ban/
│       └── jail.d/
│           └── iredmail.local
├── scripts/
│   ├── backup.sh
│   ├── restore.sh
│   ├── obtain-cert.sh
│   └── add-domain.sh
└── data/                          # Created at runtime, gitignored
    ├── mysql/
    ├── vmail/
    ├── dkim/
    ├── ssl/
    ├── clamav/
    ├── spamassassin/
    ├── sogo/
    ├── logs/
    └── backup/
```

---

## Implementation Phases

### Phase 1: Project Foundation
- Create directory structure
- Create .env.example with all configuration variables
- Create .gitignore
- Create docker-compose.yml skeleton

### Phase 2: Database Container
- Configure MariaDB container
- Create initialization scripts for iRedMail databases
- Set up health checks

### Phase 3: Core Dockerfile
- Ubuntu 22.04 base with s6-overlay
- Install all mail server packages
- Install SASL packages (fix issue #3)
- Install Roundcube, iRedAdmin, SOGo
- Set up s6 service definitions

### Phase 4: Service Configuration
- Postfix configuration with SASL fix
- Dovecot configuration with auth socket
- Amavisd with ClamAV/SpamAssassin
- Nginx reverse proxy
- Roundcube webmail
- iRedAdmin panel
- SOGo groupware

### Phase 5: Security & SSL
- Fail2ban container setup
- Certbot integration
- Let's Encrypt automation

### Phase 6: Utilities
- Health check script
- Backup/restore scripts
- Domain management scripts

---

## Ports Exposed

| Port | Service | Protocol |
|------|---------|----------|
| 25 | SMTP | TCP |
| 465 | SMTPS | TCP |
| 587 | Submission | TCP |
| 110 | POP3 | TCP |
| 995 | POP3S | TCP |
| 143 | IMAP | TCP |
| 993 | IMAPS | TCP |
| 80 | HTTP | TCP |
| 443 | HTTPS | TCP |
| 4190 | ManageSieve | TCP |

---

## Multi-Domain Support

The architecture fully supports multiple domains:
- Each domain stored in `domain` table
- Per-domain DKIM keys in `/var/lib/dkim/`
- Script provided to add new domains with DKIM generation
- Multi-domain SSL via SAN certificates

---

## Requirements

- Docker Engine 20.10+
- Docker Compose v2+
- 4GB RAM minimum (8GB recommended with ClamAV)
- 20GB disk space minimum
- Valid domain with DNS control
- Clean IP (not on blacklists)

---

## Approval Request

**Do you approve this plan?**

Once approved, I will create all the files in the following order:
1. Directory structure and .gitignore
2. .env.example
3. docker-compose.yml
4. Dockerfile with s6-overlay
5. s6 service definitions
6. Configuration files
7. Utility scripts
8. README.md
