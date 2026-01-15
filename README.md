# iRedMail Docker

A production-ready, dockerized iRedMail mail server with all components included in a single, easy-to-deploy solution.

This project addresses known issues with the archived official iRedMail Docker image and provides a stable, maintainable alternative.

## Features

- **Full Mail Stack**: Postfix (MTA), Dovecot (IMAP/POP3), Amavisd, ClamAV, SpamAssassin
- **Webmail**: Roundcube webmail client
- **Groupware**: SOGo with Calendar, Contacts, and ActiveSync support
- **Admin Panel**: iRedAdmin for user and domain management
- **Policy Server**: iRedAPD for greylisting, throttling, and access control
- **Security**: Fail2ban intrusion prevention, DKIM, SPF, DMARC support
- **SSL/TLS**: Let's Encrypt integration with automatic renewal
- **Multi-Domain**: Support for unlimited mail domains
- **Process Management**: s6-overlay for reliable service supervision

## Architecture

### Container Layout

| Container | Components | Purpose |
|-----------|------------|---------|
| `iredmail-core` | Postfix, Dovecot, Amavisd, ClamAV, SpamAssassin, iRedAPD, Nginx, PHP-FPM, Roundcube, iRedAdmin, SOGo | All mail + web services |
| `iredmail-db` | MariaDB 10.11 | Database (separate for safety/backups) |
| `iredmail-fail2ban` | Fail2ban | Intrusion prevention (host network) |
| `iredmail-certbot` | Certbot | SSL auto-renewal |

### Why This Design?

**Hybrid approach instead of microservices:**
- Mail components (Postfix/Dovecot/Amavisd) are tightly coupled via sockets and queues
- Reduces complexity without sacrificing reliability
- Database separation allows independent backups and scaling
- Single container simplifies deployment while maintaining all functionality

## Known Issues Fixed

This project fixes all known issues from the archived official iRedMail Docker image:

| Issue | Problem | Solution |
|-------|---------|----------|
| Archived/unstable | Official image no longer maintained | Built custom image from scratch with Ubuntu 22.04 |
| Custom config ignored | Configuration changes not applied | Enhanced init with explicit custom config loading |
| SASL auth fails | SMTP authentication broken | Installed libsasl2-modules, configured Dovecot auth socket |
| Fail2ban/iptables | Cannot access host iptables | Separate container on host network with NET_ADMIN |
| Passwords reset | Credentials reset on container restart | Fixed passwords via .env with persistence check |
| Services not starting | Services fail to auto-start | s6-overlay init system with proper dependencies |
| MariaDB settings ignored | Database config not applied | Separate container with proper file permissions |
| Cloudflare/proxy issues | Real IP not detected behind proxy | Nginx real_ip configuration included |

## Requirements

- Docker Engine 20.10+
- Docker Compose v2+
- 4GB RAM minimum (8GB recommended for ClamAV)
- 20GB disk space minimum
- Valid domain with DNS control
- Clean IP address (not on blacklists)
- Ports 25, 80, 443, 587, 993 accessible

## Quick Start

### 1. Clone and Setup

```bash
git clone https://github.com/yourusername/iredmail-docker.git
cd iredmail-docker
./setup.sh
```

The setup script creates necessary directories, copies the example environment file, and optionally configures UFW firewall rules.

### 2. Configure Environment

Edit `.env` file with your settings:

```bash
nano .env
```

**Required settings:**

| Variable | Description | Example |
|----------|-------------|---------|
| `HOSTNAME` | Mail server FQDN | `mail.example.com` |
| `FIRST_MAIL_DOMAIN` | Primary mail domain | `example.com` |
| `FIRST_MAIL_DOMAIN_ADMIN_PASSWORD` | Postmaster password | `SecurePassword123!` |
| `MYSQL_ROOT_PASSWORD` | Database root password | `RandomSecureString` |
| `LETSENCRYPT_EMAIL` | SSL notification email | `admin@example.com` |

> **Security Note**: Generate strong, unique passwords for all database credentials.

### 3. Configure DNS

Before starting, configure these DNS records for your domain:

#### Required Records

| Type | Name | Value |
|------|------|-------|
| A | `mail.example.com` | `YOUR_SERVER_IP` |
| MX | `example.com` | `10 mail.example.com` |
| TXT | `example.com` | `v=spf1 mx -all` |
| TXT | `_dmarc.example.com` | `v=DMARC1; p=quarantine; rua=mailto:postmaster@example.com` |
| PTR | `YOUR_SERVER_IP` | `mail.example.com` (configure with hosting provider) |

#### DKIM Record (add after first start)

```
dkim._domainkey.example.com.  IN  TXT  "v=DKIM1; k=rsa; p=YOUR_PUBLIC_KEY"
```

### 4. Build and Start

```bash
# Build the image
docker compose build

# Start services
docker compose up -d

# Watch startup logs (Ctrl+C to exit)
docker compose logs -f
```

First startup takes 3-5 minutes while ClamAV downloads virus definitions.

### 5. Obtain SSL Certificate

After DNS is configured and propagated:

```bash
./scripts/obtain-cert.sh
```

The script will:
- Detect if a valid Let's Encrypt certificate exists
- Obtain a new certificate if needed (or if only self-signed exists)
- Automatically reload all services
- Skip renewal if certificate is valid for more than 30 days

> **Note**: Certificate auto-renewal runs every 12 hours via the certbot container.

### 6. Access Your Mail Server

| Service | URL | Default Login |
|---------|-----|---------------|
| **Webmail** | `https://mail.example.com/mail/` | `postmaster@example.com` |
| **Admin Panel** | `https://mail.example.com/iredadmin/` | `postmaster@example.com` |
| **SOGo** | `https://mail.example.com/SOGo/` | `postmaster@example.com` |

## Project Structure

```
iredmail-docker/
├── docker-compose.yml          # Container orchestration
├── Dockerfile                  # Main image build
├── .env.example                # Environment template
├── setup.sh                    # Initial setup script
├── rootfs/
│   └── etc/
│       └── s6-overlay/
│           ├── s6-rc.d/        # Service definitions
│           │   ├── postfix/
│           │   ├── dovecot/
│           │   ├── amavisd/
│           │   ├── clamav/
│           │   ├── nginx/
│           │   ├── php-fpm/
│           │   ├── sogo/
│           │   ├── iredapd/
│           │   ├── iredadmin/
│           │   └── cert-reload/
│           └── scripts/
│               └── init.sh     # Initialization script
├── config/                     # Custom configuration overrides
│   ├── postfix/
│   ├── dovecot/
│   ├── amavis/
│   ├── nginx/
│   ├── roundcube/
│   ├── sogo/
│   └── fail2ban/
├── scripts/
│   ├── obtain-cert.sh          # SSL certificate management
│   ├── add-domain.sh           # Add mail domains
│   ├── setup-firewall.sh       # UFW firewall configuration
│   ├── backup.sh               # Backup utility
│   └── restore.sh              # Restore utility
├── sql/                        # Database schemas
│   ├── vmail.sql
│   ├── iredadmin.sql
│   ├── roundcubemail.sql
│   └── sogo.sql
└── data/                       # Runtime data (gitignored)
    ├── mysql/
    ├── vmail/
    ├── dkim/
    ├── ssl/
    ├── clamav/
    ├── sogo/
    ├── logs/
    └── backup/
```

## DKIM Setup

After first start, retrieve your DKIM public key:

```bash
docker exec iredmail-core amavisd-new showkeys
```

Or extract just the key:

```bash
docker exec iredmail-core cat /var/lib/dkim/example.com.pem | \
    openssl rsa -pubout 2>/dev/null | \
    grep -v '^-' | tr -d '\n'
```

Add the DKIM DNS record with the output.

## Adding Domains

```bash
./scripts/add-domain.sh newdomain.com
```

This will:
1. Add the domain to the database
2. Generate DKIM keys
3. Display required DNS records for the new domain

## Email Client Configuration

### IMAP (Recommended)

| Setting | Value |
|---------|-------|
| Server | `mail.example.com` |
| Port | `993` |
| Security | SSL/TLS |
| Username | Full email address |

### SMTP (Outgoing)

| Setting | Value |
|---------|-------|
| Server | `mail.example.com` |
| Port | `587` (STARTTLS) or `465` (SSL/TLS) |
| Security | STARTTLS or SSL/TLS |
| Username | Full email address |

### ActiveSync (Mobile)

| Setting | Value |
|---------|-------|
| Server | `mail.example.com` |
| Domain | (leave empty) |
| Username | Full email address |

### CalDAV/CardDAV

| Service | URL |
|---------|-----|
| Calendar | `https://mail.example.com/SOGo/dav/USERNAME/Calendar/personal/` |
| Contacts | `https://mail.example.com/SOGo/dav/USERNAME/Contacts/personal/` |

## Ports

| Port | Service | Protocol | Notes |
|------|---------|----------|-------|
| 25 | SMTP | TCP | Incoming mail |
| 465 | SMTPS | TCP | Secure SMTP submission |
| 587 | Submission | TCP | STARTTLS submission |
| 143 | IMAP | TCP | Unencrypted (redirects to TLS) |
| 993 | IMAPS | TCP | Secure IMAP |
| 80 | HTTP | TCP | Let's Encrypt challenges |
| 443 | HTTPS | TCP | Web interfaces |
| 4190 | ManageSieve | TCP | Sieve filter management |

> **Note**: POP3 ports (110, 995) are disabled by default. Enable in `docker-compose.yml` if needed.

## Data Persistence

All data is stored in the `./data/` directory:

| Directory | Contents |
|-----------|----------|
| `data/mysql/` | Database files |
| `data/vmail/` | Email storage |
| `data/dkim/` | DKIM keys |
| `data/ssl/` | SSL certificates |
| `data/clamav/` | Virus definitions |
| `data/sogo/` | SOGo cache |
| `data/logs/` | Service logs (shared with fail2ban) |

## Backup & Restore

### Create Backup

```bash
./scripts/backup.sh
```

Backups include database, email, DKIM keys, and configuration.

### Restore from Backup

```bash
./scripts/restore.sh ./data/backup/iredmail_backup_YYYYMMDD_HHMMSS.tar.gz
```

## Customization

Configuration overrides can be placed in the `config/` directory:

| File | Purpose |
|------|---------|
| `config/postfix/custom.cf` | Postfix main.cf overrides |
| `config/dovecot/custom.conf` | Dovecot configuration |
| `config/amavis/50-custom.conf` | Amavis/SpamAssassin settings |
| `config/nginx/custom.conf` | Nginx configuration |
| `config/roundcube/custom.inc.php` | Roundcube settings |
| `config/sogo/custom.conf` | SOGo configuration |

## Troubleshooting

### View Logs

```bash
# All containers
docker compose logs -f

# Specific container
docker compose logs -f iredmail

# Mail log inside container
docker exec iredmail-core tail -f /var/log/iredmail/maillog
```

### Check Service Status

```bash
# Service overview
docker exec iredmail-core s6-rc -a list

# Individual services
docker exec iredmail-core postfix status
docker exec iredmail-core doveadm who
docker exec iredmail-core nginx -t
docker exec iredmail-core clamd --version
```

### Test Email

```bash
# Send test email
docker exec iredmail-core swaks \
    --to test@gmail.com \
    --from postmaster@example.com \
    --server localhost

# Check mail queue
docker exec iredmail-core postqueue -p
```

### DNS Verification

```bash
# All records at once
dig MX example.com +short
dig TXT example.com +short
dig TXT dkim._domainkey.example.com +short
dig TXT _dmarc.example.com +short
```

### Common Issues

| Issue | Solution |
|-------|----------|
| Certificate errors | Run `./scripts/obtain-cert.sh` |
| Cannot send email | Check firewall allows port 25, 465, 587 |
| Cannot receive email | Verify MX record and port 25 |
| High spam score | Configure SPF, DKIM, DMARC, PTR |
| Blacklisted IP | Check at [MXToolbox](https://mxtoolbox.com/blacklists.aspx) |
| ClamAV using high memory | Normal - needs ~1-2GB for virus definitions |
| VPS blocks outbound port 25 | Contact your VPS provider to unblock (common with IONOS, AWS, etc.) |

## Updating

```bash
# Pull latest changes
git pull

# Rebuild and restart
docker compose build
docker compose up -d
```

## Security Recommendations

1. **Strong Passwords**: Use unique, random passwords for all accounts
2. **Firewall**: Run `sudo ./scripts/setup-firewall.sh` to configure UFW with all required ports
3. **Updates**: Regularly rebuild to get security updates
4. **Monitoring**: Check Fail2ban logs for intrusion attempts
5. **Backups**: Schedule regular backups to external storage
6. **DNS**: Ensure SPF, DKIM, and DMARC are properly configured

## Component Versions

| Component | Version |
|-----------|---------|
| Ubuntu | 22.04 LTS |
| s6-overlay | 3.2.0.3 |
| Postfix | System package |
| Dovecot | System package |
| Roundcube | 1.6.12 |
| SOGo | 5.x (nightly) |
| iRedAdmin | 2.7 |
| iRedAPD | 5.9.1 |
| MariaDB | 10.11 |
| Fail2ban | 1.1.0 |
| Certbot | 4.0.0 |

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

### Third-Party Licenses

This project incorporates several open-source components:

- **iRedMail** - GPL v3 - https://www.iredmail.org/
- **Postfix** - IBM Public License - http://www.postfix.org/
- **Dovecot** - MIT/LGPL - https://dovecot.org/
- **SOGo** - GPL v2 - https://www.sogo.nu/
- **Roundcube** - GPL v3 - https://roundcube.net/
- **s6-overlay** - ISC License - https://github.com/just-containers/s6-overlay

## Credits

- [iRedMail](https://www.iredmail.org/) - The mail server solution this project is based on
- [s6-overlay](https://github.com/just-containers/s6-overlay) - Container init and process supervision
- [SOGo](https://www.sogo.nu/) - Groupware server
- [Roundcube](https://roundcube.net/) - Webmail client
- [Postfix](http://www.postfix.org/) - Mail transfer agent
- [Dovecot](https://dovecot.org/) - IMAP/POP3 server

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.
