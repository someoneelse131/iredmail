#!/bin/bash
# =============================================================================
# Add New Mail Domain
# =============================================================================
# Idempotent script - safe to run multiple times
# Automatically updates CERT_EXTRA_DOMAINS in .env for autodiscovery
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Parse arguments
NEW_DOMAIN=""
SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --yes|-y)
            SKIP_CONFIRM=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 <domain.com> [options]"
            echo ""
            echo "Options:"
            echo "  --yes, -y      Skip confirmation prompt"
            echo "  --help, -h     Show this help"
            echo ""
            echo "Examples:"
            echo "  $0 example.com"
            echo "  $0 example.com --yes"
            echo ""
            echo "After adding a domain:"
            echo "  1. Configure DNS records (shown after running)"
            echo "  2. Run ./scripts/obtain-cert.sh --force to update SSL certificate"
            exit 0
            ;;
        *)
            if [ -z "$NEW_DOMAIN" ]; then
                NEW_DOMAIN="$1"
            fi
            shift
            ;;
    esac
done

if [ -z "$NEW_DOMAIN" ]; then
    echo "Usage: $0 <domain.com> [--yes]"
    echo "Use --help for more options"
    exit 1
fi

# Load environment
if [ -f "${PROJECT_DIR}/.env" ]; then
    source "${PROJECT_DIR}/.env"
else
    echo "ERROR: .env file not found!"
    exit 1
fi

# =============================================================================
# Confirmation prompt
# =============================================================================
echo ""
echo "=============================================="
echo "Add Mail Domain"
echo "=============================================="
echo ""
echo "Domain:      ${NEW_DOMAIN}"
echo "Mail Server: ${HOSTNAME}"
echo ""

if [ "$SKIP_CONFIRM" != "true" ]; then
    read -p "Continue? (y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# =============================================================================
# Check if containers are running
# =============================================================================
if ! docker ps --format '{{.Names}}' | grep -q "iredmail-core"; then
    echo "ERROR: iredmail-core container is not running!"
    echo "Start it with: docker compose up -d"
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -q "iredmail-db"; then
    echo "ERROR: iredmail-db container is not running!"
    echo "Start it with: docker compose up -d"
    exit 1
fi

# =============================================================================
# Track what changed (for certificate renewal decision)
# =============================================================================
CHANGES_MADE=false

# =============================================================================
# Add domain to database (idempotent)
# =============================================================================
echo ""
echo "Checking domain in database..."

DOMAIN_EXISTS=$(docker exec iredmail-db mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -N -e \
    "SELECT COUNT(*) FROM vmail.domain WHERE domain='${NEW_DOMAIN}';" 2>/dev/null)

if [ "$DOMAIN_EXISTS" == "1" ]; then
    echo "  [OK] Domain already exists in database"
else
    echo "  [+] Adding domain to database..."
    docker exec iredmail-db mysql -u root -p"${MYSQL_ROOT_PASSWORD}" vmail -e \
        "INSERT INTO domain (domain, transport, active, created) VALUES ('${NEW_DOMAIN}', 'dovecot', 1, NOW());" 2>/dev/null

    # Verify
    VERIFY=$(docker exec iredmail-db mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -N -e \
        "SELECT COUNT(*) FROM vmail.domain WHERE domain='${NEW_DOMAIN}';" 2>/dev/null)

    if [ "$VERIFY" == "1" ]; then
        echo "  [OK] Domain added successfully"
        CHANGES_MADE=true
    else
        echo "  [ERROR] Failed to add domain!"
        exit 1
    fi
fi

# =============================================================================
# Generate DKIM key (idempotent)
# =============================================================================
echo ""
echo "Checking DKIM key..."

DKIM_EXISTS=$(docker exec iredmail-core test -f /var/lib/dkim/${NEW_DOMAIN}.pem && echo "yes" || echo "no")

if [ "$DKIM_EXISTS" == "yes" ]; then
    echo "  [OK] DKIM key already exists"
else
    echo "  [+] Generating DKIM key..."
    docker exec iredmail-core bash -c "
        mkdir -p /var/lib/dkim
        openssl genrsa -out /var/lib/dkim/${NEW_DOMAIN}.pem 2048 2>/dev/null
        chown amavis:amavis /var/lib/dkim/${NEW_DOMAIN}.pem
        chmod 600 /var/lib/dkim/${NEW_DOMAIN}.pem
    "

    # Verify
    DKIM_VERIFY=$(docker exec iredmail-core test -f /var/lib/dkim/${NEW_DOMAIN}.pem && echo "yes" || echo "no")
    if [ "$DKIM_VERIFY" == "yes" ]; then
        echo "  [OK] DKIM key generated"
        CHANGES_MADE=true
    else
        echo "  [ERROR] Failed to generate DKIM key!"
        exit 1
    fi
fi

# =============================================================================
# Update CERT_EXTRA_DOMAINS in .env (idempotent)
# =============================================================================
echo ""
echo "Checking SSL certificate domains..."

AUTOCONFIG_DOMAIN="autoconfig.${NEW_DOMAIN}"
AUTODISCOVER_DOMAIN="autodiscover.${NEW_DOMAIN}"
CERT_UPDATED=false

# Read current CERT_EXTRA_DOMAINS
CURRENT_CERT_DOMAINS="${CERT_EXTRA_DOMAINS:-}"

# Check if autoconfig domain is already included
if echo "$CURRENT_CERT_DOMAINS" | grep -q "$AUTOCONFIG_DOMAIN"; then
    echo "  [OK] ${AUTOCONFIG_DOMAIN} already in certificate"
else
    echo "  [+] Adding ${AUTOCONFIG_DOMAIN} to certificate domains"
    if [ -z "$CURRENT_CERT_DOMAINS" ]; then
        CURRENT_CERT_DOMAINS="$AUTOCONFIG_DOMAIN"
    else
        CURRENT_CERT_DOMAINS="${CURRENT_CERT_DOMAINS},${AUTOCONFIG_DOMAIN}"
    fi
    CERT_UPDATED=true
fi

# Check if autodiscover domain is already included
if echo "$CURRENT_CERT_DOMAINS" | grep -q "$AUTODISCOVER_DOMAIN"; then
    echo "  [OK] ${AUTODISCOVER_DOMAIN} already in certificate"
else
    echo "  [+] Adding ${AUTODISCOVER_DOMAIN} to certificate domains"
    if [ -z "$CURRENT_CERT_DOMAINS" ]; then
        CURRENT_CERT_DOMAINS="$AUTODISCOVER_DOMAIN"
    else
        CURRENT_CERT_DOMAINS="${CURRENT_CERT_DOMAINS},${AUTODISCOVER_DOMAIN}"
    fi
    CERT_UPDATED=true
fi

# Update .env file if needed
if [ "$CERT_UPDATED" == "true" ]; then
    echo ""
    echo "Updating .env file..."

    # Check if CERT_EXTRA_DOMAINS line exists
    if grep -q "^CERT_EXTRA_DOMAINS=" "${PROJECT_DIR}/.env"; then
        # Update existing line
        sed -i "s|^CERT_EXTRA_DOMAINS=.*|CERT_EXTRA_DOMAINS=${CURRENT_CERT_DOMAINS}|" "${PROJECT_DIR}/.env"
    else
        # Add new line
        echo "" >> "${PROJECT_DIR}/.env"
        echo "# Extra domains for SSL certificate (autodiscovery)" >> "${PROJECT_DIR}/.env"
        echo "CERT_EXTRA_DOMAINS=${CURRENT_CERT_DOMAINS}" >> "${PROJECT_DIR}/.env"
    fi

    echo "  [OK] .env updated with: CERT_EXTRA_DOMAINS=${CURRENT_CERT_DOMAINS}"
    CHANGES_MADE=true
fi

# =============================================================================
# Extract DKIM public key for DNS
# =============================================================================
PUBLIC_KEY=$(docker exec iredmail-core openssl rsa -in /var/lib/dkim/${NEW_DOMAIN}.pem -pubout 2>/dev/null | grep -v "PUBLIC KEY" | tr -d '\n')

if [ -z "$PUBLIC_KEY" ]; then
    echo "ERROR: Could not extract DKIM public key!"
    exit 1
fi

# =============================================================================
# Show DNS records
# =============================================================================
echo ""
echo "=============================================="
echo "Domain Configuration Complete"
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
echo "   # CNAME records for autodiscovery"
echo "   Type:  CNAME"
echo "   Name:  autoconfig"
echo "   Value: ${HOSTNAME}"
echo ""
echo "   Type:  CNAME"
echo "   Name:  autodiscover"
echo "   Value: ${HOSTNAME}"
echo ""
echo "   # SRV records for email (RFC 6186)"
echo "   Type:  SRV"
echo "   Name:  _imap._tcp"
echo "   Value: 0 1 993 ${HOSTNAME}"
echo ""
echo "   Type:  SRV"
echo "   Name:  _submission._tcp"
echo "   Value: 0 1 587 ${HOSTNAME}"
echo ""
echo "   # SRV records for CalDAV/CardDAV (RFC 6764)"
echo "   Type:  SRV"
echo "   Name:  _caldavs._tcp"
echo "   Value: 0 1 443 ${HOSTNAME}"
echo ""
echo "   Type:  SRV"
echo "   Name:  _carddavs._tcp"
echo "   Value: 0 1 443 ${HOSTNAME}"
echo ""
echo "=============================================="
echo ""
echo "NEXT STEPS:"
echo ""
echo "1. Configure the DNS records above at your DNS provider"
echo ""
echo "2. Wait for DNS propagation (can take a few minutes to hours)"
echo ""
echo "3. Update SSL certificate to include autodiscovery domains:"
echo "   ./scripts/obtain-cert.sh"
echo ""
echo "   The script will:"
echo "   - Validate DNS for each domain (skip if not pointing to this server)"
echo "   - Use --expand to add new domains (no unnecessary renewal)"
echo "   - Respect Let's Encrypt rate limits"
echo ""
echo "4. Create mailboxes at: https://${HOSTNAME}/iredadmin/"
echo ""
