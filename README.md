# iRedMail Docker

A production-ready, dockerized iRedMail mail server with all components included.

## Features

- **Full Mail Stack**: Postfix, Dovecot, Amavisd, ClamAV, SpamAssassin
- **Webmail**: Roundcube
- **Groupware**: SOGo with Calendar, Contacts, and ActiveSync
- **Admin Panel**: iRedAdmin (free version)
- **Security**: Fail2ban, DKIM, SPF, DMARC support
- **SSL**: Let's Encrypt integration with auto-renewal
- **Multi-Domain**: Support for multiple mail domains

## Architecture

| Container | Purpose |
|-----------|---------|
| `iredmail-core` | All mail services + web apps |
| `iredmail-db` | MariaDB database |
| `iredmail-fail2ban` | Intrusion prevention |
| `iredmail-certbot` | SSL certificate management |

## Requirements

- Docker Engine 20.10+
- Docker Compose v2+
- 4GB RAM minimum (8GB recommended)
- 20GB disk space minimum
- Valid domain with DNS control
- Clean IP address (not on blacklists)

## Quick Start

### 1. Clone and Setup

```bash
git clone <repository>
cd iredadmin
./setup.sh
```

### 2. Configure Environment

Edit `.env` file with your settings:

```bash
nano .env
```

Required settings:
- `HOSTNAME`: Your mail server FQDN (e.g., `mail.example.com`)
- `FIRST_MAIL_DOMAIN`: Your primary mail domain (e.g., `example.com`)
- `FIRST_MAIL_DOMAIN_ADMIN_PASSWORD`: Admin password
- All database passwords (use strong, unique passwords)
- `LETSENCRYPT_EMAIL`: Email for SSL certificate notifications

### 3. Configure DNS

Before starting, configure these DNS records:

#### A Record
```
mail.example.com.  IN  A  YOUR_SERVER_IP
```

#### MX Record
```
example.com.  IN  MX  10  mail.example.com.
```

#### SPF Record
```
example.com.  IN  TXT  "v=spf1 mx -all"
```

#### DMARC Record
```
_dmarc.example.com.  IN  TXT  "v=DMARC1; p=quarantine; rua=mailto:postmaster@example.com"
```

#### PTR Record (Reverse DNS)
Configure with your hosting provider:
```
YOUR_SERVER_IP  ->  mail.example.com
```

### 4. Build and Start

```bash
# Build the image
docker compose build

# Start services
docker compose up -d

# View logs
docker compose logs -f
```

### 5. Obtain SSL Certificate

After DNS is configured and propagated (may take up to 24-48 hours):

```bash
./scripts/obtain-cert.sh
```

### 6. Access Your Mail Server

- **Webmail**: https://mail.example.com/mail/
- **Admin Panel**: https://mail.example.com/iredadmin/
- **SOGo**: https://mail.example.com/SOGo/

Default login: `postmaster@example.com`

## DKIM Setup

After first start, get your DKIM public key:

```bash
docker exec iredmail-core cat /var/lib/dkim/example.com.pem | openssl rsa -pubout
```

Add the DKIM DNS record:
```
dkim._domainkey.example.com.  IN  TXT  "v=DKIM1; k=rsa; p=YOUR_PUBLIC_KEY"
```

## Adding Additional Domains

```bash
./scripts/add-domain.sh newdomain.com
```

This will:
1. Add the domain to the database
2. Generate DKIM keys
3. Display required DNS records

## Backup & Restore

### Create Backup
```bash
./scripts/backup.sh
```

Backups are stored in `./data/backup/`

### Restore from Backup
```bash
./scripts/restore.sh ./data/backup/iredmail_backup_YYYYMMDD_HHMMSS.tar.gz
```

## Email Client Configuration

### IMAP
- Server: mail.example.com
- Port: 993 (SSL/TLS)
- Username: full email address

### SMTP
- Server: mail.example.com
- Port: 587 (STARTTLS) or 465 (SSL/TLS)
- Username: full email address

### ActiveSync (SOGo)
- Server: mail.example.com
- Domain: (leave empty)
- Username: full email address

## Customization

### Custom Postfix Settings
Edit `config/postfix/custom.sh` to add postconf commands.

### Custom Dovecot Settings
Edit `config/dovecot/custom.conf` for Dovecot customizations.

### Custom Amavis Settings
Edit `config/amavis/99-custom.conf` for spam/virus settings.

### Custom Nginx Settings
Edit `config/nginx/custom.conf` for web server customizations.

## Ports

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

## Troubleshooting

### View Logs
```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f iredmail

# Mail logs inside container
docker exec iredmail-core tail -f /var/log/mail.log
```

### Check Service Status
```bash
docker exec iredmail-core postfix status
docker exec iredmail-core doveadm who
docker exec iredmail-core nginx -t
```

### Test Email Sending
```bash
docker exec iredmail-core swaks --to test@gmail.com --from postmaster@example.com --server localhost
```

### Check DNS Configuration
```bash
# MX record
dig MX example.com

# SPF record
dig TXT example.com

# DKIM record
dig TXT dkim._domainkey.example.com

# DMARC record
dig TXT _dmarc.example.com
```

### Common Issues

**Certificate errors**: Ensure DNS is configured and run `./scripts/obtain-cert.sh`

**Cannot send/receive email**: Check firewall allows ports 25, 465, 587

**Blacklisted IP**: Check at https://mxtoolbox.com/blacklists.aspx

**High spam score**: Ensure SPF, DKIM, and DMARC are configured correctly

## Security Considerations

1. Use strong, unique passwords for all database accounts
2. Keep the system updated: `docker compose pull && docker compose up -d`
3. Monitor Fail2ban logs for intrusion attempts
4. Regularly backup your data
5. Consider using a firewall (ufw, iptables)

## License

This project is open source. iRedMail is released under the GPL v3 license.

## Credits

- [iRedMail](https://www.iredmail.org/) - The mail server solution
- [s6-overlay](https://github.com/just-containers/s6-overlay) - Container init system
- [SOGo](https://www.sogo.nu/) - Groupware
- [Roundcube](https://roundcube.net/) - Webmail
