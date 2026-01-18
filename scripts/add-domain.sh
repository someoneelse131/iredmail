#!/bin/bash
# =============================================================================
# Add New Mail Domain
# =============================================================================

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

# =============================================================================
# Confirmation prompt
# =============================================================================
echo ""
echo "=============================================="
echo "Add Mail Domain"
echo "=============================================="
echo ""
echo "You are about to add: ${NEW_DOMAIN}"
echo ""
read -p "Is this correct? (y/n): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# =============================================================================
# Check if domain already exists
# =============================================================================
echo ""
echo "Checking if domain exists..."

DOMAIN_EXISTS=$(docker exec iredmail-db mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -N -e \
    "SELECT COUNT(*) FROM vmail.domain WHERE domain='${NEW_DOMAIN}';" 2>/dev/null)

if [ "$DOMAIN_EXISTS" == "1" ]; then
    echo "Domain '${NEW_DOMAIN}' already exists in database."
    ALREADY_EXISTS=true
else
    ALREADY_EXISTS=false

    # Add domain to database
    echo "Adding domain to database..."
    docker exec iredmail-db mysql -u root -p"${MYSQL_ROOT_PASSWORD}" vmail -e \
        "INSERT INTO domain (domain, transport, active, created) VALUES ('${NEW_DOMAIN}', 'dovecot', 1, NOW());" 2>/dev/null

    # Verify it was added
    VERIFY=$(docker exec iredmail-db mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -N -e \
        "SELECT COUNT(*) FROM vmail.domain WHERE domain='${NEW_DOMAIN}';" 2>/dev/null)

    if [ "$VERIFY" == "1" ]; then
        echo "Domain added successfully."
    else
        echo "ERROR: Failed to add domain to database!"
        exit 1
    fi
fi

# =============================================================================
# Generate DKIM key
# =============================================================================
echo ""
echo "Checking DKIM key..."

DKIM_EXISTS=$(docker exec iredmail-core test -f /var/lib/dkim/${NEW_DOMAIN}.pem && echo "yes" || echo "no")

if [ "$DKIM_EXISTS" == "yes" ]; then
    echo "DKIM key already exists."
else
    echo "Generating DKIM key..."
    docker exec iredmail-core bash -c "
        mkdir -p /var/lib/dkim
        openssl genrsa -out /var/lib/dkim/${NEW_DOMAIN}.pem 2048 2>/dev/null
        chown amavis:amavis /var/lib/dkim/${NEW_DOMAIN}.pem
        chmod 600 /var/lib/dkim/${NEW_DOMAIN}.pem
    "

    # Verify DKIM key was created
    DKIM_VERIFY=$(docker exec iredmail-core test -f /var/lib/dkim/${NEW_DOMAIN}.pem && echo "yes" || echo "no")
    if [ "$DKIM_VERIFY" == "yes" ]; then
        echo "DKIM key generated successfully."
    else
        echo "ERROR: Failed to generate DKIM key!"
        exit 1
    fi
fi

# =============================================================================
# Extract public key
# =============================================================================
PUBLIC_KEY=$(docker exec iredmail-core openssl rsa -in /var/lib/dkim/${NEW_DOMAIN}.pem -pubout 2>/dev/null | grep -v "PUBLIC KEY" | tr -d '\n')

if [ -z "$PUBLIC_KEY" ]; then
    echo "ERROR: Could not extract DKIM public key!"
    exit 1
fi

# =============================================================================
# Show results
# =============================================================================
echo ""
echo "=============================================="
if [ "$ALREADY_EXISTS" == "true" ]; then
    echo "Domain Already Configured"
else
    echo "Domain Added Successfully!"
fi
echo "=============================================="
echo ""
echo "Required DNS records for ${NEW_DOMAIN}:"
echo ""
echo "----------------------------------------------"
echo "1. MX Record (Mail Exchange)"
echo "----------------------------------------------"
echo "   Type:     MX"
echo "   Name:     @ (or ${NEW_DOMAIN})"
echo "   Priority: 10"
echo "   Value:    ${HOSTNAME}"
echo ""
echo "----------------------------------------------"
echo "2. SPF Record (Sender Policy Framework)"
echo "----------------------------------------------"
echo "   Type:  TXT"
echo "   Name:  @ (or ${NEW_DOMAIN})"
echo "   Value: v=spf1 mx ~all"
echo ""
echo "----------------------------------------------"
echo "3. DKIM Record (DomainKeys Identified Mail)"
echo "----------------------------------------------"
echo "   Type:  TXT"
echo "   Name:  dkim._domainkey"
echo "   Value: v=DKIM1; k=rsa; p=${PUBLIC_KEY}"
echo ""
echo "----------------------------------------------"
echo "4. DMARC Record (Domain-based Message Auth)"
echo "----------------------------------------------"
echo "   Type:  TXT"
echo "   Name:  _dmarc"
echo "   Value: v=DMARC1; p=quarantine; rua=mailto:postmaster@${FIRST_MAIL_DOMAIN}"
echo ""
echo "----------------------------------------------"
echo "5. Autodiscovery Records (Email Client Auto-Config)"
echo "----------------------------------------------"
echo "   # CNAME records for autodiscovery hostnames"
echo "   Type:  CNAME"
echo "   Name:  autoconfig"
echo "   Value: ${HOSTNAME}"
echo ""
echo "   Type:  CNAME"
echo "   Name:  autodiscover"
echo "   Value: ${HOSTNAME}"
echo ""
echo "   # SRV records for RFC 6186 (optional but recommended)"
echo "   Type:  SRV"
echo "   Name:  _imap._tcp"
echo "   Value: 0 1 993 ${HOSTNAME}"
echo ""
echo "   Type:  SRV"
echo "   Name:  _imaps._tcp"
echo "   Value: 0 1 993 ${HOSTNAME}"
echo ""
echo "   Type:  SRV"
echo "   Name:  _submission._tcp"
echo "   Value: 0 1 587 ${HOSTNAME}"
echo ""
echo "=============================================="
echo ""
echo "Create mailboxes at: https://${HOSTNAME}/iredadmin/"
echo ""
