#!/bin/bash
# =============================================================================
# Add New Mail Domain
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

NEW_DOMAIN="$1"

if [ -z "$NEW_DOMAIN" ]; then
    echo "Usage: $0 <domain.com>"
    exit 1
fi

# Load environment
if [ -f "${PROJECT_DIR}/.env" ]; then
    source "${PROJECT_DIR}/.env"
fi

echo "=============================================="
echo "Adding New Mail Domain"
echo "=============================================="
echo "Domain: $NEW_DOMAIN"
echo ""

# Add domain to database
echo "Adding domain to database..."
docker exec iredmail-db mysql -u root -p"${MYSQL_ROOT_PASSWORD}" vmail << EOF
INSERT IGNORE INTO domain (domain, transport, active, created)
VALUES ('${NEW_DOMAIN}', 'dovecot', 1, NOW());
EOF
echo "Domain added to database."

# Generate DKIM key
echo ""
echo "Generating DKIM key..."
DKIM_KEY_FILE="${PROJECT_DIR}/data/dkim/${NEW_DOMAIN}.pem"
mkdir -p "${PROJECT_DIR}/data/dkim"

openssl genrsa -out "$DKIM_KEY_FILE" 2048 2>/dev/null
chmod 600 "$DKIM_KEY_FILE"

# Generate public key for DNS
PUBLIC_KEY=$(openssl rsa -in "$DKIM_KEY_FILE" -pubout 2>/dev/null | \
    grep -v "PUBLIC KEY" | tr -d '\n')

echo ""
echo "=============================================="
echo "Domain Added Successfully!"
echo "=============================================="
echo ""
echo "Required DNS Records for ${NEW_DOMAIN}:"
echo ""
echo "1. MX Record:"
echo "   Name: ${NEW_DOMAIN}"
echo "   Type: MX"
echo "   Priority: 10"
echo "   Value: ${HOSTNAME}"
echo ""
echo "2. SPF Record:"
echo "   Name: ${NEW_DOMAIN}"
echo "   Type: TXT"
echo "   Value: v=spf1 mx -all"
echo ""
echo "3. DKIM Record:"
echo "   Name: dkim._domainkey.${NEW_DOMAIN}"
echo "   Type: TXT"
echo "   Value: v=DKIM1; k=rsa; p=${PUBLIC_KEY}"
echo ""
echo "4. DMARC Record:"
echo "   Name: _dmarc.${NEW_DOMAIN}"
echo "   Type: TXT"
echo "   Value: v=DMARC1; p=quarantine; rua=mailto:postmaster@${NEW_DOMAIN}"
echo ""
echo "After adding DNS records, you can create mailboxes via:"
echo "  - iRedAdmin: https://${HOSTNAME}/iredadmin/"
echo ""
