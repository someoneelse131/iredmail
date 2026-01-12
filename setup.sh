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

echo ""
echo "=============================================="
echo "Setup Complete!"
echo "=============================================="
echo ""
echo "Next steps:"
echo ""
echo "1. Review and edit .env file if needed:"
echo "   nano ${SCRIPT_DIR}/.env"
echo ""
echo "2. Build the Docker image:"
echo "   docker compose build"
echo ""
echo "3. Start the services:"
echo "   docker compose up -d"
echo ""
echo "4. Obtain SSL certificate (after DNS is configured):"
echo "   ./scripts/obtain-cert.sh"
echo ""
echo "5. Access your mail server:"
echo "   Webmail: https://\${HOSTNAME}/mail/"
echo "   Admin:   https://\${HOSTNAME}/iredadmin/"
echo "   SOGo:    https://\${HOSTNAME}/SOGo/"
echo ""
echo "Required DNS Records:"
echo "   See README.md for complete DNS configuration"
echo ""
