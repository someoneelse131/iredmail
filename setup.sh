#!/bin/bash
# =============================================================================
# iRedMail Docker Setup Script
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=============================================="
echo "iRedMail Docker Setup"
echo "=============================================="
echo ""

# Create data directories
echo "Creating data directories..."
mkdir -p "${SCRIPT_DIR}/data/mysql"
mkdir -p "${SCRIPT_DIR}/data/vmail"
mkdir -p "${SCRIPT_DIR}/data/dkim"
mkdir -p "${SCRIPT_DIR}/data/ssl"
mkdir -p "${SCRIPT_DIR}/data/certbot-www"
mkdir -p "${SCRIPT_DIR}/data/mlmmj"
mkdir -p "${SCRIPT_DIR}/data/mlmmj-archive"
mkdir -p "${SCRIPT_DIR}/data/imapsieve_copy"
mkdir -p "${SCRIPT_DIR}/data/clamav"
mkdir -p "${SCRIPT_DIR}/data/spamassassin"
mkdir -p "${SCRIPT_DIR}/data/sogo"
mkdir -p "${SCRIPT_DIR}/data/postfix-queue"
mkdir -p "${SCRIPT_DIR}/data/logs"
mkdir -p "${SCRIPT_DIR}/data/logs/roundcube"

# Create log files for fail2ban (must exist before containers start)
touch "${SCRIPT_DIR}/data/logs/maillog"
touch "${SCRIPT_DIR}/data/logs/dovecot.log"
touch "${SCRIPT_DIR}/data/logs/nginx-error.log"
touch "${SCRIPT_DIR}/data/logs/sogo.log"
touch "${SCRIPT_DIR}/data/logs/roundcube/errors.log"
mkdir -p "${SCRIPT_DIR}/data/iredmail-state"
mkdir -p "${SCRIPT_DIR}/data/backup/mysql"
echo "Data directories created."

# Check for .env file
if [ ! -f "${SCRIPT_DIR}/.env" ]; then
    echo ""
    echo "Creating .env file from template..."
    cp "${SCRIPT_DIR}/.env.example" "${SCRIPT_DIR}/.env"
    echo ""
    echo "IMPORTANT: You must edit .env and configure:"
    echo "  - HOSTNAME (your mail server FQDN)"
    echo "  - FIRST_MAIL_DOMAIN (your primary mail domain)"
    echo "  - FIRST_MAIL_DOMAIN_ADMIN_PASSWORD"
    echo "  - All database passwords"
    echo "  - LETSENCRYPT_EMAIL"
    echo ""
    read -p "Press Enter to edit .env file now, or Ctrl+C to exit..."
    ${EDITOR:-nano} "${SCRIPT_DIR}/.env"
fi

# Make scripts executable
chmod +x "${SCRIPT_DIR}/scripts/"*.sh

# Setup firewall rules
echo ""
echo "Checking firewall configuration..."
if [ "$EUID" -eq 0 ]; then
    "${SCRIPT_DIR}/scripts/setup-firewall.sh"
else
    echo "Run firewall setup with sudo:"
    echo "  sudo ${SCRIPT_DIR}/scripts/setup-firewall.sh"
    echo ""
    read -p "Run firewall setup now? (requires sudo) [y/N]: " run_fw
    if [[ "$run_fw" =~ ^[Yy]$ ]]; then
        sudo "${SCRIPT_DIR}/scripts/setup-firewall.sh"
    fi
fi

# Install cron jobs (backup + lazy_expunge cleanup)
echo ""
echo "Installing cron jobs..."
if [ "$EUID" -eq 0 ]; then
    cp "${SCRIPT_DIR}/scripts/backup-cron" /etc/cron.d/iredmail-backup
    chmod 644 /etc/cron.d/iredmail-backup
    echo "Cron jobs installed."
else
    echo "Install cron jobs with sudo:"
    echo "  sudo cp ${SCRIPT_DIR}/scripts/backup-cron /etc/cron.d/iredmail-backup"
    echo "  sudo chmod 644 /etc/cron.d/iredmail-backup"
    echo ""
    read -p "Install cron jobs now? (requires sudo) [y/N]: " install_cron
    if [[ "$install_cron" =~ ^[Yy]$ ]]; then
        sudo cp "${SCRIPT_DIR}/scripts/backup-cron" /etc/cron.d/iredmail-backup
        sudo chmod 644 /etc/cron.d/iredmail-backup
        echo "Cron jobs installed."
    fi
fi

# Borg backup setup (4h dedup+encrypted backup, primary going forward)
echo ""
echo "Setting up Borg backup (every 4h, encrypted, deduplicating)..."

setup_borg() {
    # Install borg if missing
    if ! command -v borg >/dev/null 2>&1; then
        echo "  Installing borgbackup..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y borgbackup
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y borgbackup
        else
            echo "  WARNING: unsupported package manager. Install borgbackup manually."
            return 1
        fi
    fi
    echo "  borg version: $(borg --version)"

    # Ensure BORG_PASSPHRASE in .env
    if ! grep -q '^BORG_PASSPHRASE=' "${SCRIPT_DIR}/.env"; then
        echo "  Generating BORG_PASSPHRASE (64 hex chars) and appending to .env..."
        local pp
        pp="$(openssl rand -hex 32)"
        printf '\n# Borg backup passphrase (added by setup.sh)\nBORG_PASSPHRASE=%s\n' "${pp}" >> "${SCRIPT_DIR}/.env"
    else
        echo "  BORG_PASSPHRASE already set in .env"
    fi

    # Init repo if not yet present
    local repo="${SCRIPT_DIR}/data/borg-repo"
    if [ ! -d "${repo}/data" ]; then
        echo "  Initialising Borg repo at ${repo}..."
        local pp
        pp="$(grep '^BORG_PASSPHRASE=' "${SCRIPT_DIR}/.env" | head -n1 | cut -d= -f2-)"
        BORG_PASSPHRASE="${pp}" borg init --encryption=repokey-blake2 "${repo}"
        echo "  Borg repo initialised."
    else
        echo "  Borg repo already exists at ${repo}"
    fi

    # Install Borg cron
    cp "${SCRIPT_DIR}/scripts/borg-backup-cron" /etc/cron.d/iredmail-borg-backup
    chmod 644 /etc/cron.d/iredmail-borg-backup
    echo "  Borg cron installed at /etc/cron.d/iredmail-borg-backup"
}

if [ "$EUID" -eq 0 ]; then
    setup_borg
else
    echo "Borg setup requires root (apt install + cron file). Run setup as root or run manually:"
    echo "  sudo apt-get install -y borgbackup"
    echo "  echo 'BORG_PASSPHRASE='\$(openssl rand -hex 32) | sudo tee -a ${SCRIPT_DIR}/.env"
    echo "  export BORG_PASSPHRASE=\$(grep ^BORG_PASSPHRASE= ${SCRIPT_DIR}/.env | cut -d= -f2-)"
    echo "  sudo borg init --encryption=repokey-blake2 ${SCRIPT_DIR}/data/borg-repo"
    echo "  sudo cp ${SCRIPT_DIR}/scripts/borg-backup-cron /etc/cron.d/iredmail-borg-backup"
    echo "  sudo chmod 644 /etc/cron.d/iredmail-borg-backup"
    echo ""
    read -p "Set up Borg now? (requires sudo) [y/N]: " setup_borg_now
    if [[ "$setup_borg_now" =~ ^[Yy]$ ]]; then
        sudo bash -c "$(declare -f setup_borg); SCRIPT_DIR='${SCRIPT_DIR}' setup_borg"
    fi
fi

echo ""
echo "=============================================="
echo "Setup Complete!"
echo "=============================================="
echo ""

# Load environment for DNS instructions
if [ -f "${SCRIPT_DIR}/.env" ]; then
    source "${SCRIPT_DIR}/.env"
fi

# Use defaults if not set
HOSTNAME="${HOSTNAME:-mail.example.com}"
FIRST_MAIL_DOMAIN="${FIRST_MAIL_DOMAIN:-example.com}"

echo "Next steps:"
echo ""
echo "1. Review and edit .env file if needed:"
echo "   nano ${SCRIPT_DIR}/.env"
echo ""
echo "2. Configure DNS records for ${FIRST_MAIL_DOMAIN}:"
echo ""
echo "   Required Records:"
echo "   -----------------"
echo "   Type   Name                      Value"
echo "   A      ${HOSTNAME}               YOUR_SERVER_IP"
echo "   MX     ${FIRST_MAIL_DOMAIN}      10 ${HOSTNAME}"
echo "   TXT    ${FIRST_MAIL_DOMAIN}      v=spf1 mx ~all"
echo "   TXT    _dmarc.${FIRST_MAIL_DOMAIN}   v=DMARC1; p=quarantine; rua=mailto:postmaster@${FIRST_MAIL_DOMAIN}"
echo "   PTR    YOUR_SERVER_IP            ${HOSTNAME} (set via hosting provider)"
echo ""
echo "   Autodiscovery Records (for automatic email client setup):"
echo "   ---------------------------------------------------------"
echo "   Type   Name                            Value"
echo "   CNAME  autoconfig.${FIRST_MAIL_DOMAIN}      ${HOSTNAME}"
echo "   CNAME  autodiscover.${FIRST_MAIL_DOMAIN}    ${HOSTNAME}"
echo "   SRV    _imap._tcp.${FIRST_MAIL_DOMAIN}      0 1 993 ${HOSTNAME}"
echo "   SRV    _imaps._tcp.${FIRST_MAIL_DOMAIN}     0 1 993 ${HOSTNAME}"
echo "   SRV    _submission._tcp.${FIRST_MAIL_DOMAIN} 0 1 587 ${HOSTNAME}"
echo ""
echo "   Note: DKIM record will be shown after first start."
echo ""
echo "3. Build the Docker image:"
echo "   docker compose build"
echo ""
echo "4. Start the services:"
echo "   docker compose up -d"
echo ""
echo "5. Obtain SSL certificate (after DNS is configured):"
echo "   ./scripts/obtain-cert.sh"
echo ""
echo "6. Access your mail server:"
echo "   Webmail: https://${HOSTNAME}/mail/"
echo "   Admin:   https://${HOSTNAME}/iredadmin/"
echo "   SOGo:    https://${HOSTNAME}/SOGo/"
echo ""
