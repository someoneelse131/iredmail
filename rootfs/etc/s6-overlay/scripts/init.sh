#!/bin/bash
# =============================================================================
# iRedMail Docker Initialization Script
# Runs once on container startup before services start
# =============================================================================

set -e

echo "========================================"
echo "iRedMail Docker Initialization"
echo "========================================"

# =============================================================================
# Configuration Variables
# =============================================================================
STATE_DIR="/opt/iredmail/state"
STATE_FILE="${STATE_DIR}/initialized"
DB_HOST="db"
DB_PORT="3306"

# =============================================================================
# Wait for MariaDB
# =============================================================================
wait_for_db() {
    echo "Waiting for MariaDB at ${DB_HOST}:${DB_PORT}..."
    local max_attempts=60
    local attempt=0

    while ! nc -z "${DB_HOST}" "${DB_PORT}" 2>/dev/null; do
        attempt=$((attempt + 1))
        if [ $attempt -ge $max_attempts ]; then
            echo "ERROR: MariaDB not available after ${max_attempts} attempts"
            exit 1
        fi
        echo "Waiting for MariaDB... (${attempt}/${max_attempts})"
        sleep 2
    done

    echo "MariaDB is available!"

    # Additional wait for MariaDB to be fully ready
    sleep 5
}

# =============================================================================
# Initialize Database
# =============================================================================
init_database() {
    echo "Initializing databases..."

    # Check if vmail database exists
    if mysql -h "${DB_HOST}" -u root -p"${MYSQL_ROOT_PASSWORD}" -e "USE vmail" 2>/dev/null; then
        echo "Database 'vmail' already exists, skipping initialization"
        return 0
    fi

    echo "Creating iRedMail databases..."

    # Create databases
    mysql -h "${DB_HOST}" -u root -p"${MYSQL_ROOT_PASSWORD}" << EOF
-- Create vmail database
CREATE DATABASE IF NOT EXISTS vmail CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS amavisd CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS iredadmin CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS iredapd CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS roundcubemail CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS sogo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Create users
CREATE USER IF NOT EXISTS 'vmail'@'%' IDENTIFIED BY '${VMAIL_DB_PASSWORD}';
CREATE USER IF NOT EXISTS 'vmailadmin'@'%' IDENTIFIED BY '${VMAIL_DB_ADMIN_PASSWORD}';
CREATE USER IF NOT EXISTS 'amavisd'@'%' IDENTIFIED BY '${AMAVISD_DB_PASSWORD}';
CREATE USER IF NOT EXISTS 'iredadmin'@'%' IDENTIFIED BY '${IREDADMIN_DB_PASSWORD}';
CREATE USER IF NOT EXISTS 'iredapd'@'%' IDENTIFIED BY '${IREDAPD_DB_PASSWORD}';
CREATE USER IF NOT EXISTS 'roundcube'@'%' IDENTIFIED BY '${ROUNDCUBE_DB_PASSWORD}';
CREATE USER IF NOT EXISTS 'sogo'@'%' IDENTIFIED BY '${SOGO_DB_PASSWORD}';

-- Grant privileges
GRANT SELECT ON vmail.* TO 'vmail'@'%';
GRANT ALL PRIVILEGES ON vmail.* TO 'vmailadmin'@'%';
GRANT ALL PRIVILEGES ON amavisd.* TO 'amavisd'@'%';
GRANT ALL PRIVILEGES ON iredadmin.* TO 'iredadmin'@'%';
GRANT ALL PRIVILEGES ON iredapd.* TO 'iredapd'@'%';
GRANT ALL PRIVILEGES ON roundcubemail.* TO 'roundcube'@'%';
GRANT ALL PRIVILEGES ON sogo.* TO 'sogo'@'%';
GRANT SELECT ON vmail.* TO 'sogo'@'%';

FLUSH PRIVILEGES;
EOF

    # Import SQL schemas
    if [ -d "/opt/iredmail/sql" ]; then
        echo "Importing SQL schemas..."
        for sql_file in /opt/iredmail/sql/*.sql; do
            if [ -f "$sql_file" ]; then
                db_name=$(basename "$sql_file" .sql)
                echo "Importing $sql_file to database $db_name..."
                if ! mysql -h "${DB_HOST}" -u root -p"${MYSQL_ROOT_PASSWORD}" "$db_name" < "$sql_file"; then
                    echo "ERROR: Failed to import $sql_file"
                fi
            fi
        done
    fi

    # Create SOGo users view (maps mailbox columns to SOGo expected c_* columns)
    echo "Creating SOGo users view..."
    mysql -h "${DB_HOST}" -u root -p"${MYSQL_ROOT_PASSWORD}" vmail << 'EOF'
CREATE OR REPLACE VIEW sogo_users AS
SELECT
    username AS c_uid,
    username AS c_name,
    password AS c_password,
    name AS c_cn,
    username AS mail
FROM mailbox WHERE active = 1;
EOF

    echo "Database initialization complete!"
}

# =============================================================================
# Create Admin User
# =============================================================================
create_admin_user() {
    echo "Creating admin user..."

    local domain="${FIRST_MAIL_DOMAIN}"
    local admin_email="postmaster@${domain}"

    # Check if admin already exists
    local exists=$(mysql -h "${DB_HOST}" -u root -p"${MYSQL_ROOT_PASSWORD}" -N -e \
        "SELECT COUNT(*) FROM vmail.mailbox WHERE username='${admin_email}';" 2>/dev/null || echo "0")

    if [ "$exists" != "0" ] && [ "$exists" != "" ]; then
        echo "Admin user already exists"
        return 0
    fi

    # Generate password hash (SSHA512)
    local password_hash=$(python3 -c "
import hashlib
import os
import base64
password = '${FIRST_MAIL_DOMAIN_ADMIN_PASSWORD}'
salt = os.urandom(8)
h = hashlib.sha512(password.encode() + salt).digest()
print('{SSHA512}' + base64.b64encode(h + salt).decode())
")

    echo "Creating domain: ${domain}"
    mysql -h "${DB_HOST}" -u root -p"${MYSQL_ROOT_PASSWORD}" vmail << EOF
-- Insert domain with unlimited accounts (0 = unlimited in iRedAdmin)
INSERT IGNORE INTO domain (domain, description, aliases, mailboxes, maillists, maxquota, quota, transport, active, created, modified)
VALUES ('${domain}', 'Primary mail domain', 0, 0, 0, 0, 0, 'dovecot', 1, NOW(), NOW());

-- Insert admin mailbox (iRedMail 1.7.x compatible schema)
-- Note: Columns with special chars use defaults, no need to specify
INSERT IGNORE INTO mailbox (
    username, password, name, language,
    mailboxformat, mailboxfolder,
    storagebasedirectory, storagenode, maildir,
    quota, domain, transport,
    isadmin, isglobaladmin,
    enablesmtp, enablesmtpsecured,
    enablepop3, enablepop3secured, enablepop3tls,
    enableimap, enableimapsecured, enableimaptls,
    enabledeliver, enablelda,
    enablemanagesieve, enablemanagesievesecured,
    enablesieve, enablesievesecured, enablesievetls,
    enableinternal, enabledoveadm,
    enablelmtp, enabledsync, enablesogo,
    enablesogowebmail, enablesogocalendar, enablesogoactivesync,
    active, created, modified
) VALUES (
    '${admin_email}',
    '${password_hash}',
    'Postmaster',
    'en_US',
    'maildir',
    'Maildir',
    '/var/vmail',
    'vmail1',
    '${domain}/p/o/s/postmaster-${domain}/',
    0,
    '${domain}',
    '',
    1, 1,
    1, 1,
    1, 1, 1,
    1, 1, 1,
    1, 1,
    1, 1,
    1, 1, 1,
    1, 1,
    1, 1, 1,
    'y', 'y', 'y',
    1, NOW(), NOW()
);

-- Link global admin to domain_admins (required for iRedAdmin permissions)
-- Note: Authentication uses mailbox table with isglobaladmin=1
INSERT IGNORE INTO domain_admins (username, domain, active, created)
VALUES ('${admin_email}', 'ALL', 1, NOW());

-- Insert alias for postmaster
INSERT IGNORE INTO alias (address, name, domain, active, created, modified)
VALUES ('${admin_email}', 'Postmaster', '${domain}', 1, NOW(), NOW());

-- Insert forwardings
INSERT IGNORE INTO forwardings (address, forwarding, domain, dest_domain, is_mailbox, active)
VALUES ('${admin_email}', '${admin_email}', '${domain}', '${domain}', 1, 1);
EOF

    echo "Admin user created: ${admin_email}"
}

# =============================================================================
# Generate DKIM Keys
# =============================================================================
generate_dkim() {
    local domain="${FIRST_MAIL_DOMAIN}"
    local dkim_dir="/var/lib/dkim"
    local key_file="${dkim_dir}/${domain}.pem"

    if [ -f "$key_file" ]; then
        echo "DKIM key already exists for ${domain}"
        return 0
    fi

    echo "Generating DKIM key for ${domain}..."
    mkdir -p "$dkim_dir"

    openssl genrsa -out "$key_file" 2048 2>/dev/null
    chown amavis:amavis "$key_file"
    chmod 600 "$key_file"

    # Generate public key for DNS
    local public_key=$(openssl rsa -in "$key_file" -pubout 2>/dev/null | \
        grep -v "PUBLIC KEY" | tr -d '\n')

    echo ""
    echo "=========================================="
    echo "DKIM DNS Record for ${domain}"
    echo "=========================================="
    echo "Add this TXT record to your DNS:"
    echo ""
    echo "Name: dkim._domainkey.${domain}"
    echo "Value: v=DKIM1; k=rsa; p=${public_key}"
    echo "=========================================="
    echo ""
}

# =============================================================================
# Configure Services
# =============================================================================
configure_postfix() {
    echo "Configuring Postfix..."

    # Setup Postfix chroot DNS resolution
    mkdir -p /var/spool/postfix/etc
    cp /etc/resolv.conf /var/spool/postfix/etc/resolv.conf

    # Set hostname
    postconf -e "myhostname = ${HOSTNAME}"
    postconf -e "mydomain = ${FIRST_MAIL_DOMAIN}"
    postconf -e "myorigin = \$mydomain"

    # SASL configuration (Fix for Issue #3)
    postconf -e "smtpd_sasl_type = dovecot"
    postconf -e "smtpd_sasl_path = private/auth"
    postconf -e "smtpd_sasl_auth_enable = yes"
    postconf -e "smtpd_sasl_security_options = noanonymous"
    postconf -e "smtpd_sasl_local_domain = \$myhostname"
    postconf -e "broken_sasl_auth_clients = yes"

    # TLS settings
    postconf -e "smtpd_tls_cert_file = /etc/letsencrypt/live/${HOSTNAME}/fullchain.pem"
    postconf -e "smtpd_tls_key_file = /etc/letsencrypt/live/${HOSTNAME}/privkey.pem"
    postconf -e "smtpd_use_tls = yes"
    postconf -e "smtpd_tls_security_level = may"
    postconf -e "smtp_tls_security_level = may"

    # MySQL lookups
    postconf -e "virtual_mailbox_domains = proxy:mysql:/etc/postfix/mysql/virtual_mailbox_domains.cf"
    postconf -e "virtual_mailbox_maps = proxy:mysql:/etc/postfix/mysql/virtual_mailbox_maps.cf"
    postconf -e "virtual_alias_maps = proxy:mysql:/etc/postfix/mysql/virtual_alias_maps.cf"

    # Virtual transport to Dovecot LMTP
    postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"
    postconf -e "virtual_mailbox_base = /var/vmail"
    postconf -e "virtual_minimum_uid = 2000"
    postconf -e "virtual_uid_maps = static:2000"
    postconf -e "virtual_gid_maps = static:2000"

    # Message size limit
    postconf -e "message_size_limit = ${MESSAGE_SIZE_LIMIT:-52428800}"

    # Enable submission (587) and smtps (465) ports in master.cf
    if ! grep -q "^submission inet" /etc/postfix/master.cf; then
        echo "Enabling submission and smtps ports..."
        cat >> /etc/postfix/master.cf << 'MASTEREOF'

# Submission port (587) for authenticated mail submission
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_tls_auth_only=yes
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject

# SMTPS port (465) for legacy SSL
smtps     inet  n       -       y       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
MASTEREOF
    fi

    # Apply custom configuration
    if [ -x "/opt/iredmail/custom/postfix/custom.sh" ]; then
        echo "Applying custom Postfix configuration..."
        /opt/iredmail/custom/postfix/custom.sh
    fi
}

configure_dovecot() {
    echo "Configuring Dovecot..."

    # Create auth socket for Postfix SASL
    mkdir -p /var/spool/postfix/private
    chown postfix:postfix /var/spool/postfix/private

    # Create Dovecot SQL configuration for user authentication
    echo "Creating Dovecot SQL configuration..."
    cat > /etc/dovecot/dovecot-sql.conf.ext << EOF
# Dovecot SQL Authentication Configuration
# Auto-generated by init.sh

driver = mysql
connect = host=${DB_HOST} dbname=vmail user=vmail password=${VMAIL_DB_PASSWORD}

# Password scheme used in database
default_pass_scheme = SSHA512

# Password query - authenticate users from mailbox table
password_query = SELECT username AS user, password, \\
    CONCAT('/var/vmail/', maildir) AS userdb_home, \\
    2000 AS userdb_uid, \\
    2000 AS userdb_gid, \\
    CONCAT('maildir:/var/vmail/', maildir) AS userdb_mail \\
    FROM mailbox \\
    WHERE username = '%u' AND active = 1

# User query - get user information
user_query = SELECT \\
    CONCAT('/var/vmail/', maildir) AS home, \\
    2000 AS uid, \\
    2000 AS gid, \\
    CONCAT('maildir:/var/vmail/', maildir) AS mail \\
    FROM mailbox \\
    WHERE username = '%u' AND active = 1

# Iterate query - list all users (for doveadm)
iterate_query = SELECT username AS user FROM mailbox WHERE active = 1
EOF

    # Secure the file
    chmod 640 /etc/dovecot/dovecot-sql.conf.ext
    chown root:dovecot /etc/dovecot/dovecot-sql.conf.ext

    # Enable SQL authentication instead of system (PAM) authentication
    sed -i 's/!include auth-system.conf.ext/!include auth-sql.conf.ext/' /etc/dovecot/conf.d/10-auth.conf

    # Configure Dovecot auth socket for Postfix SASL
    echo "Configuring Dovecot auth socket for Postfix..."
    cat > /etc/dovecot/conf.d/10-master-override.conf << 'MASTEREOF'
# Dovecot auth socket for Postfix SASL authentication
# Auto-generated by init.sh

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}

# LMTP socket for mail delivery
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}
MASTEREOF

    # Apply custom configuration
    if [ -f "/opt/iredmail/custom/dovecot/custom.conf" ]; then
        echo "Applying custom Dovecot configuration..."
        cp /opt/iredmail/custom/dovecot/custom.conf /etc/dovecot/conf.d/99-custom.conf
    fi

    echo "Dovecot configuration complete."
}

configure_nginx() {
    echo "Configuring Nginx..."

    # Create SSL directory if it doesn't exist
    mkdir -p /etc/letsencrypt/live/${HOSTNAME}

    # Generate self-signed cert if Let's Encrypt not yet available
    if [ ! -f "/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem" ]; then
        echo "Generating temporary self-signed certificate..."
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "/etc/letsencrypt/live/${HOSTNAME}/privkey.pem" \
            -out "/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem" \
            -subj "/CN=${HOSTNAME}" 2>/dev/null
    fi

    # Replace HOSTNAME placeholder in nginx config
    if [ -f "/etc/nginx/sites-available/default" ]; then
        sed -i "s|/etc/letsencrypt/live/HOSTNAME/|/etc/letsencrypt/live/${HOSTNAME}/|g" /etc/nginx/sites-available/default
    fi

    # Configure email autodiscovery files (dynamic PHP handlers)
    local autoconfig_file="/var/www/html/autodiscover/autoconfig.php"
    local autodiscover_file="/var/www/html/autodiscover/autodiscover.php"

    if [ -f "$autoconfig_file" ]; then
        sed -i "s|HOSTNAME|${HOSTNAME}|g" "$autoconfig_file"
        sed -i "s|FIRST_MAIL_DOMAIN|${FIRST_MAIL_DOMAIN}|g" "$autoconfig_file"
        chown www-data:www-data "$autoconfig_file"
        echo "Configured Mozilla Autoconfig (dynamic)"
    fi

    if [ -f "$autodiscover_file" ]; then
        sed -i "s|HOSTNAME|${HOSTNAME}|g" "$autodiscover_file"
        sed -i "s|FIRST_MAIL_DOMAIN|${FIRST_MAIL_DOMAIN}|g" "$autodiscover_file"
        chown www-data:www-data "$autodiscover_file"
        echo "Configured Microsoft Autodiscover"
    fi

    # Enable the site
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-enabled/default.dpkg-dist 2>/dev/null || true

    # Apply custom configuration
    if [ -f "/opt/iredmail/custom/nginx/custom.conf" ]; then
        echo "Applying custom Nginx configuration..."
        cp /opt/iredmail/custom/nginx/custom.conf /etc/nginx/conf.d/99-custom.conf
    fi
}

configure_clamav() {
    if [ "${DISABLE_CLAMAV}" = "YES" ]; then
        echo "ClamAV disabled by configuration"
        return 0
    fi

    echo "Configuring ClamAV..."

    # Create log directory with proper permissions
    mkdir -p /var/log/clamav /run/clamav /var/lib/clamav
    chown -R clamav:clamav /var/lib/clamav /var/log/clamav /run/clamav

    # Note: Virus definitions will be downloaded by the ClamAV s6 service
    # We just ensure directories exist with proper permissions here
}

configure_sogo() {
    echo "Configuring SOGo..."

    # Set permissions
    chown -R sogo:sogo /var/lib/sogo /run/sogo

    # Apply custom configuration
    if [ -f "/opt/iredmail/custom/sogo/sogo.conf" ]; then
        echo "Applying custom SOGo configuration..."
        cp /opt/iredmail/custom/sogo/sogo.conf /etc/sogo/sogo.conf
        chown sogo:sogo /etc/sogo/sogo.conf
    fi
}

# =============================================================================
# Create Postfix MySQL Lookup Files
# =============================================================================
create_postfix_mysql_configs() {
    echo "Creating Postfix MySQL configuration files..."

    mkdir -p /etc/postfix/mysql

    # Virtual mailbox domains lookup
    cat > /etc/postfix/mysql/virtual_mailbox_domains.cf << EOF
user = vmail
password = ${VMAIL_DB_PASSWORD}
hosts = ${DB_HOST}
dbname = vmail
query = SELECT domain FROM domain WHERE domain='%s' AND active=1
EOF

    # Virtual mailbox maps lookup
    cat > /etc/postfix/mysql/virtual_mailbox_maps.cf << EOF
user = vmail
password = ${VMAIL_DB_PASSWORD}
hosts = ${DB_HOST}
dbname = vmail
query = SELECT maildir FROM mailbox WHERE username='%s' AND active=1
EOF

    # Virtual alias maps lookup
    cat > /etc/postfix/mysql/virtual_alias_maps.cf << EOF
user = vmail
password = ${VMAIL_DB_PASSWORD}
hosts = ${DB_HOST}
dbname = vmail
query = SELECT forwarding FROM forwardings WHERE address='%s' AND active=1
EOF

    # Sender login maps
    cat > /etc/postfix/mysql/sender_login_maps.cf << EOF
user = vmail
password = ${VMAIL_DB_PASSWORD}
hosts = ${DB_HOST}
dbname = vmail
query = SELECT username FROM mailbox WHERE username='%s' AND active=1
EOF

    chmod 640 /etc/postfix/mysql/*.cf
    chown root:postfix /etc/postfix/mysql/*.cf

    echo "Postfix MySQL configuration files created."
}

# =============================================================================
# Create iRedAPD Settings
# =============================================================================
create_iredapd_settings() {
    echo "Creating iRedAPD settings..."

    local srs_secret=$(openssl rand -hex 16)

    cat > /opt/iredapd/settings.py << EOF
# iRedAPD settings
# Auto-generated by init.sh

# Import default settings first
try:
    from libs.default_settings import *
except ImportError:
    pass

# Listen address and port
listen_address = '127.0.0.1'
listen_port = 7777
srs_forward_port = 7778
srs_reverse_port = 7779

run_as_user = 'iredapd'
pid_file = '/run/iredapd/iredapd.pid'

# Logging
log_level = 'info'
log_file = '/var/log/iredapd/iredapd.log'

# Backend
backend = 'mysql'

# Enabled plugins
plugins = ['reject_null_sender', 'wblist_rdns', 'reject_sender_login_mismatch', 'greylisting', 'throttle', 'amavisd_wblist', 'sql_alias_access_policy']

# SRS (Sender Rewriting Scheme)
srs_secrets = ['${srs_secret}']
srs_domain = '${FIRST_MAIL_DOMAIN}'

# vmail database
vmail_db_server = '${DB_HOST}'
vmail_db_port = 3306
vmail_db_name = 'vmail'
vmail_db_user = 'vmail'
vmail_db_password = '${VMAIL_DB_PASSWORD}'

# Amavisd database
amavisd_db_server = '${DB_HOST}'
amavisd_db_port = 3306
amavisd_db_name = 'amavisd'
amavisd_db_user = 'amavisd'
amavisd_db_password = '${AMAVISD_DB_PASSWORD}'

# iRedAPD database
iredapd_db_server = '${DB_HOST}'
iredapd_db_port = 3306
iredapd_db_name = 'iredapd'
iredapd_db_user = 'iredapd'
iredapd_db_password = '${IREDAPD_DB_PASSWORD}'
EOF

    # Create iredapd user if not exists
    id -u iredapd &>/dev/null || useradd -r -s /sbin/nologin iredapd

    # Create runtime and log directories
    mkdir -p /run/iredapd /var/log/iredapd
    chown iredapd:iredapd /run/iredapd /var/log/iredapd
    chown iredapd:iredapd /opt/iredapd/settings.py
    chmod 600 /opt/iredapd/settings.py

    # Create /etc/mailname
    echo "${HOSTNAME}" > /etc/mailname

    echo "iRedAPD settings created."
}

# =============================================================================
# Create iRedAdmin Settings
# =============================================================================
create_iredadmin_settings() {
    echo "Creating iRedAdmin settings..."

    cat > /var/www/iredadmin/settings.py << EOF
# iRedAdmin settings
# Auto-generated by init.sh

# Import default settings first (provides MAILDIR_HASHED, etc.)
from libs.default_settings import *

# General settings
webmaster = 'postmaster@${FIRST_MAIL_DOMAIN}'
first_mail_domain = '${FIRST_MAIL_DOMAIN}'
default_language = 'en_US'

# Backend type
backend = 'mysql'

# Database settings (vmail - mail accounts)
vmail_db_host = '${DB_HOST}'
vmail_db_port = 3306
vmail_db_name = 'vmail'
vmail_db_user = 'vmailadmin'
vmail_db_password = '${VMAIL_DB_ADMIN_PASSWORD}'

# Database settings (iredadmin)
iredadmin_db_host = '${DB_HOST}'
iredadmin_db_port = 3306
iredadmin_db_name = 'iredadmin'
iredadmin_db_user = 'iredadmin'
iredadmin_db_password = '${IREDADMIN_DB_PASSWORD}'

# Amavisd database (for spam/virus stats)
amavisd_db_host = '${DB_HOST}'
amavisd_db_port = 3306
amavisd_db_name = 'amavisd'
amavisd_db_user = 'amavisd'
amavisd_db_password = '${AMAVISD_DB_PASSWORD}'
amavisd_enable_logging = True
amavisd_enable_quarantine = True
amavisd_quarantine_port = 9998
amavisd_enable_policy_lookup = True

# iRedAPD database
iredapd_enabled = True
iredapd_db_host = '${DB_HOST}'
iredapd_db_port = 3306
iredapd_db_name = 'iredapd'
iredapd_db_user = 'iredapd'
iredapd_db_password = '${IREDAPD_DB_PASSWORD}'

# Mail storage
storage_base_directory = '/var/vmail'
storage_node = 'vmail1'
default_mta_transport = 'dovecot'

# Password settings
min_passwd_length = 8
max_passwd_length = 0

# DKIM
amavisd_dkim_key_dir = '/var/lib/dkim'
EOF

    chown www-data:www-data /var/www/iredadmin/settings.py
    chmod 600 /var/www/iredadmin/settings.py

    echo "iRedAdmin settings created."
}

# =============================================================================
# Create Roundcube Configuration
# =============================================================================
create_roundcube_config() {
    echo "Creating Roundcube configuration..."

    cat > /var/www/roundcube/config/config.inc.php << EOF
<?php
// Roundcube configuration
// Auto-generated by init.sh

// Database connection
\$config['db_dsnw'] = 'mysql://roundcube:${ROUNDCUBE_DB_PASSWORD}@${DB_HOST}/roundcubemail';

// Default host for IMAP connection
\$config['imap_host'] = 'localhost:143';

// SMTP server (use port 25 for local delivery)
\$config['smtp_host'] = 'localhost:25';
\$config['smtp_user'] = '%u';
\$config['smtp_pass'] = '%p';

// Encryption key (for session cookies)
\$config['des_key'] = '${ROUNDCUBE_DES_KEY:-$(openssl rand -base64 24 | head -c 24)}';

// Name of the product
\$config['product_name'] = 'Webmail';

// Default skin
\$config['skin'] = 'elastic';

// Logging - write to shared directory for fail2ban integration
\$config['log_driver'] = 'file';
\$config['log_dir'] = '/var/log/iredmail/roundcube/';

// Temp directory
\$config['temp_dir'] = '/tmp/roundcube';

// Message size limit
\$config['max_message_size'] = '50M';

// Default charset
\$config['default_charset'] = 'UTF-8';

// Plugins
\$config['plugins'] = array(
    'archive',
    'zipdownload',
    'managesieve',
);

// ManageSieve settings
\$config['managesieve_port'] = 4190;
\$config['managesieve_host'] = 'localhost';
\$config['managesieve_auth_type'] = 'PLAIN';

// Addressbook for autocomplete
\$config['autocomplete_addressbooks'] = array('sql');

// Session settings
\$config['session_lifetime'] = 10;
\$config['session_domain'] = '';

// User preferences
\$config['preview_pane'] = true;
\$config['list_cols'] = array('subject', 'from', 'date', 'size', 'flag', 'attachment');

// Include custom settings if exists
if (file_exists('/opt/iredmail/custom/roundcube/config.inc.php')) {
    include '/opt/iredmail/custom/roundcube/config.inc.php';
}
EOF

    # Create required directories
    mkdir -p /var/log/iredmail/roundcube /tmp/roundcube
    chown -R www-data:www-data /var/www/roundcube/config /var/log/iredmail/roundcube /tmp/roundcube
    chmod 600 /var/www/roundcube/config/config.inc.php

    echo "Roundcube configuration created."
}

# =============================================================================
# Create SOGo Configuration
# =============================================================================
create_sogo_config() {
    echo "Creating SOGo configuration..."

    cat > /etc/sogo/sogo.conf << EOF
{
    // SOGo configuration
    // Auto-generated by init.sh

    // General settings
    SOGoTimeZone = "${TZ:-UTC}";
    SOGoPageTitle = "SOGo";
    SOGoLanguage = English;
    SOGoAppointmentSendEMailNotifications = YES;
    WOWorkersCount = ${SOGO_WORKERS:-3};

    // Logging - write to shared directory for fail2ban integration
    WOLogFile = /var/log/iredmail/sogo.log;

    // User sources (MySQL auth via vmail database)
    SOGoUserSources = (
        {
            type = sql;
            id = vmail;
            viewURL = "mysql://vmail:${VMAIL_DB_PASSWORD}@${DB_HOST}:3306/vmail/sogo_users";
            canAuthenticate = YES;
            isAddressBook = NO;
            userPasswordAlgorithm = ssha512;

            // Field mapping for sogo_users view (c_* columns)
            LoginFieldNames = (c_uid);
            MailFieldNames = (mail);
            UIDFieldName = c_uid;
            CNFieldName = c_cn;
        }
    );

    // Database
    SOGoProfileURL = "mysql://sogo:${SOGO_DB_PASSWORD}@${DB_HOST}:3306/sogo/sogo_user_profile";
    OCSFolderInfoURL = "mysql://sogo:${SOGO_DB_PASSWORD}@${DB_HOST}:3306/sogo/sogo_folder_info";
    OCSSessionsFolderURL = "mysql://sogo:${SOGO_DB_PASSWORD}@${DB_HOST}:3306/sogo/sogo_sessions_folder";
    OCSEMailAlarmsFolderURL = "mysql://sogo:${SOGO_DB_PASSWORD}@${DB_HOST}:3306/sogo/sogo_alarms_folder";
    OCSStoreURL = "mysql://sogo:${SOGO_DB_PASSWORD}@${DB_HOST}:3306/sogo/sogo_store";
    OCSAclURL = "mysql://sogo:${SOGO_DB_PASSWORD}@${DB_HOST}:3306/sogo/sogo_acl";
    OCSCacheFolderURL = "mysql://sogo:${SOGO_DB_PASSWORD}@${DB_HOST}:3306/sogo/sogo_cache_folder";

    // IMAP settings
    SOGoIMAPServer = "imap://localhost:143";
    SOGoSieveServer = "sieve://localhost:4190";

    // SMTP settings (use port 25 for local delivery)
    SOGoSMTPServer = "smtp://localhost:25";
    SOGoMailingMechanism = smtp;
    SOGoSMTPAuthenticationType = PLAIN;

    // Web UI settings
    SOGoMailDomain = "${FIRST_MAIL_DOMAIN}";
    SOGoFirstDayOfWeek = 1;
    SOGoDraftsFolderName = Drafts;
    SOGoSentFolderName = Sent;
    SOGoTrashFolderName = Trash;
    SOGoJunkFolderName = Junk;

    // ActiveSync
    SOGoMaximumPingInterval = 3540;
    SOGoMaximumSyncInterval = 3540;
    SOGoInternalSyncInterval = 30;

    // Caching
    SOGoCacheCleanupInterval = 300;
    SOGoMaximumFailedLoginCount = 5;
    SOGoMaximumFailedLoginInterval = 300;

    // Debug (set to YES for troubleshooting)
    // SOGoDebugRequests = YES;
    // SoDebugBaseURL = YES;
    // ImapDebugEnabled = YES;
}
EOF

    chown sogo:sogo /etc/sogo/sogo.conf
    chmod 600 /etc/sogo/sogo.conf

    echo "SOGo configuration created."
}

# =============================================================================
# Setup Logging for Fail2ban Integration
# =============================================================================
setup_logging() {
    echo "Setting up logging..."

    # Create log directories - all in /var/log/iredmail for fail2ban access
    mkdir -p /var/log/iredmail
    mkdir -p /var/log/iredmail/roundcube
    mkdir -p /var/log/nginx

    # Create log files if they don't exist (required for fail2ban)
    # These files are written directly by rsyslog, dovecot, and other services
    touch /var/log/iredmail/maillog
    touch /var/log/iredmail/dovecot.log
    touch /var/log/iredmail/auth.log
    touch /var/log/iredmail/sogo.log
    touch /var/log/iredmail/nginx-error.log
    touch /var/log/iredmail/roundcube/errors.log

    # Set proper permissions
    chmod 644 /var/log/iredmail/*.log 2>/dev/null || true
    chmod 644 /var/log/iredmail/roundcube/*.log 2>/dev/null || true
    chown -R www-data:www-data /var/log/iredmail/roundcube

    echo "Logging setup complete."
}

# =============================================================================
# Create iRedMail Release File
# =============================================================================
create_iredmail_release() {
    echo "Creating iRedMail release file..."

    cat > /etc/iredmail-release << EOF
1.7.0 MYSQL
EOF

    echo "iRedMail release file created."
}

# =============================================================================
# Main Initialization
# =============================================================================
main() {
    # Wait for database
    wait_for_db

    # Check if already initialized
    if [ -f "$STATE_FILE" ]; then
        echo "Container already initialized, running configuration updates only..."
        setup_logging
        create_postfix_mysql_configs
        create_iredapd_settings
        create_iredadmin_settings
        create_roundcube_config
        create_sogo_config
        configure_postfix
        configure_dovecot
        configure_nginx
        configure_sogo
        create_iredmail_release
        echo "Configuration updates complete!"
        exit 0
    fi

    # First-time initialization
    echo "Performing first-time initialization..."

    # Initialize database
    init_database

    # Create admin user
    create_admin_user

    # Generate DKIM
    generate_dkim

    # Create config files
    create_postfix_mysql_configs
    create_iredapd_settings
    create_iredadmin_settings
    create_roundcube_config
    create_sogo_config

    # Configure services
    configure_postfix
    configure_dovecot
    configure_nginx
    configure_clamav
    configure_sogo

    # Setup logging
    setup_logging

    # Create iredmail-release file for version display
    create_iredmail_release

    # Mark as initialized
    mkdir -p "$STATE_DIR"
    touch "$STATE_FILE"

    echo "========================================"
    echo "Initialization Complete!"
    echo "========================================"
    echo ""
    echo "Admin login: postmaster@${FIRST_MAIL_DOMAIN}"
    echo "Webmail: https://${HOSTNAME}/mail/"
    echo "Admin panel: https://${HOSTNAME}/iredadmin/"
    echo "SOGo: https://${HOSTNAME}/SOGo/"
    echo ""
}

main "$@"
