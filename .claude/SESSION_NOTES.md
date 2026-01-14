# iRedMail Docker - Session Notes

## Issues Fixed

### 1. Dovecot SQL Authentication
**Problem:** Webmail login failed - Dovecot couldn't authenticate users.

**Root Cause:**
- `/etc/dovecot/dovecot-sql.conf.ext` was empty (only template comments)
- `/etc/dovecot/conf.d/10-auth.conf` was using `auth-system.conf.ext` (PAM) instead of `auth-sql.conf.ext` (MySQL)

**Fix in `init.sh` - `configure_dovecot()`:**
- Generate `dovecot-sql.conf.ext` with database connection and queries
- Replace `auth-system.conf.ext` with `auth-sql.conf.ext` in `10-auth.conf`

### 2. Dovecot Auth Socket for Postfix SASL
**Problem:** SMTP authentication failed - "SASL: Connect to private/auth failed: No such file or directory"

**Root Cause:** Dovecot wasn't creating the auth socket for Postfix.

**Fix in `init.sh` - `configure_dovecot()`:**
- Create `/etc/dovecot/conf.d/10-master-override.conf` with:
  - `service auth` unix_listener at `/var/spool/postfix/private/auth`
  - `service lmtp` unix_listener at `/var/spool/postfix/private/dovecot-lmtp`

### 3. Roundcube Addressbook Error
**Problem:** "Addressbook source (collected_addresses) not found" when composing mail.

**Root Cause:** `collected_addresses` plugin referenced but not enabled.

**Fix in `init.sh` - `create_roundcube_config()`:**
- Changed `autocomplete_addressbooks` from `array('sql', 'collected_addresses')` to `array('sql')`

### 4. Roundcube SMTP Connection
**Problem:** "SMTP Error Connection to server failed"

**Root Cause:** Roundcube configured to use port 587 (submission) which requires TLS for localhost connections.

**Fix in `init.sh` - `create_roundcube_config()`:**
- Changed `smtp_host` from `localhost:587` to `localhost:25`

### 5. Postfix Submission/SMTPS Ports
**Problem:** Ports 587 and 465 not listening.

**Root Cause:** Submission and SMTPS services commented out in `/etc/postfix/master.cf`.

**Fix in `init.sh` - `configure_postfix()`:**
- Append submission (587) and smtps (465) service definitions to `master.cf`

### 6. Postfix DNS Resolution (Chroot)
**Problem:** "Host or domain name not found" when sending mail, even though `dig` and `host` work.

**Root Cause:** Postfix runs in a chroot (`/var/spool/postfix/`) and couldn't access `/etc/resolv.conf`.

**Fix in `init.sh` - `configure_postfix()`:**
```bash
mkdir -p /var/spool/postfix/etc
cp /etc/resolv.conf /var/spool/postfix/etc/resolv.conf
```

## VPS Provider Notes

### IONOS Port 25 Block
IONOS blocks **outbound** port 25 by default to prevent spam.

- **Receiving mail:** Works (inbound port 25 is open)
- **Sending mail:** Blocked (outbound port 25 blocked)

**Solution:** Contact IONOS customer service by phone to request port 25 unblock.

German notice from IONOS:
> "Aus Sicherheitsgründen ist der SMTP-Port 25 (ausgehend) standardmäßig geschlossen."

## Files Modified

### `rootfs/etc/s6-overlay/scripts/init.sh`
- `configure_dovecot()`: Added SQL config, auth socket, auth-sql enablement
- `configure_postfix()`: Added DNS chroot fix, submission/smtps ports
- `create_roundcube_config()`: Fixed SMTP port and addressbook

### `setup.sh`
- Added firewall setup prompt

### `scripts/setup-firewall.sh` (new)
- UFW configuration for all required ports:
  - 22 (SSH)
  - 25 (SMTP)
  - 80 (HTTP)
  - 443 (HTTPS)
  - 587 (Submission)
  - 465 (SMTPS)
  - 143 (IMAP)
  - 993 (IMAPS)
  - 4190 (ManageSieve)

## Architecture Notes

### Port Usage
| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 25 | SMTP | Both | Server-to-server mail |
| 587 | Submission | Inbound | Authenticated client submission |
| 465 | SMTPS | Inbound | Secure client submission |
| 143 | IMAP | Inbound | Mail retrieval |
| 993 | IMAPS | Inbound | Secure mail retrieval |
| 4190 | Sieve | Inbound | Mail filter management |

### Authentication Flow
1. User → Roundcube/SOGo → Dovecot (IMAP auth via SQL)
2. User → Roundcube → Postfix (port 25) → External server
3. External server → Postfix (port 25) → Dovecot LMTP → Mailbox

### Database Users
- `vmail`: Read-only access to vmail database (Dovecot auth)
- `vmailadmin`: Full access to vmail database (iRedAdmin)
- `roundcube`: Roundcube sessions/contacts
- `sogo`: SOGo data
- `iredadmin`: iRedAdmin sessions/logs
- `iredapd`: Policy daemon data
- `amavisd`: Spam/virus data
