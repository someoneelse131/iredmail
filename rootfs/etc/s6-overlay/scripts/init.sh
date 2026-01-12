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
                echo "Importing $sql_file..."
                mysql -h "${DB_HOST}" -u root -p"${MYSQL_ROOT_PASSWORD}" "$db_name" < "$sql_file" 2>/dev/null || true
            fi
        done
    fi

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
-- Insert domain
INSERT IGNORE INTO domain (domain, transport, active, created)
VALUES ('${domain}', 'dovecot', 1, NOW());

-- Insert admin mailbox
INSERT IGNORE INTO mailbox (
    username, password, name, maildir, quota, domain,
    isadmin, isglobaladmin, active, created
) VALUES (
    '${admin_email}',
    '${password_hash}',
    'Postmaster',
    '${domain}/p/o/s/postmaster-${domain}/',
    0,
    '${domain}',
    1, 1, 1, NOW()
);

-- Insert alias for postmaster
INSERT IGNORE INTO alias (address, domain, active, created)
VALUES ('${admin_email}', '${domain}', 1, NOW());

-- Insert forwardings
INSERT IGNORE INTO forwardings (address, forwarding, domain, is_mailbox, active)
VALUES ('${admin_email}', '${admin_email}', '${domain}', 1, 1);
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

    # Message size limit
    postconf -e "message_size_limit = ${MESSAGE_SIZE_LIMIT:-52428800}"

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

    # Apply custom configuration
    if [ -f "/opt/iredmail/custom/dovecot/custom.conf" ]; then
        echo "Applying custom Dovecot configuration..."
        cp /opt/iredmail/custom/dovecot/custom.conf /etc/dovecot/conf.d/99-custom.conf
    fi
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

    # Update virus definitions if not present
    if [ ! -f "/var/lib/clamav/main.cvd" ]; then
        echo "Downloading initial ClamAV definitions..."
        freshclam --quiet || true
    fi

    chown -R clamav:clamav /var/lib/clamav
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
# Create Log Symlinks
# =============================================================================
setup_logging() {
    echo "Setting up logging..."

    # Create log directory
    mkdir -p /var/log/iredmail

    # Symlink important logs
    ln -sf /var/log/mail.log /var/log/iredmail/maillog
    ln -sf /var/log/dovecot.log /var/log/iredmail/dovecot.log
    ln -sf /var/log/nginx/error.log /var/log/iredmail/nginx-error.log

    touch /var/log/mail.log
    touch /var/log/dovecot.log
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
        configure_postfix
        configure_dovecot
        configure_nginx
        configure_sogo
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

    # Configure services
    configure_postfix
    configure_dovecot
    configure_nginx
    configure_clamav
    configure_sogo

    # Setup logging
    setup_logging

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
