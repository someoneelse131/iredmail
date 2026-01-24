#!/bin/bash
# =============================================================================
# Obtain Let's Encrypt SSL Certificate
# =============================================================================
# This script manages SSL certificates with smart domain handling:
#
# - Validates DNS for each domain in CERT_EXTRA_DOMAINS before requesting
# - Skips domains that don't resolve to this server (safe for stale entries)
# - Uses --expand to add new domains without forcing renewal
# - Only uses --force-renewal when explicitly requested with --force
#
# Usage:
#   ./obtain-cert.sh           # Normal run - expand if new domains, else keep
#   ./obtain-cert.sh --force   # Force full renewal (careful: rate limits!)
#
# Let's Encrypt Rate Limits:
#   - 50 certificates per domain per week
#   - 5 duplicate certificates per week
#   - Use --force sparingly!
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load environment
if [ -f "${PROJECT_DIR}/.env" ]; then
    source "${PROJECT_DIR}/.env"
else
    echo "ERROR: .env file not found!"
    echo "Please copy .env.example to .env and configure it."
    exit 1
fi

if [ -z "$HOSTNAME" ] || [ -z "$LETSENCRYPT_EMAIL" ]; then
    echo "ERROR: HOSTNAME and LETSENCRYPT_EMAIL must be set in .env"
    exit 1
fi

CERT_DIR="${PROJECT_DIR}/data/ssl/live/${HOSTNAME}"
CERT_FILE="${CERT_DIR}/fullchain.pem"

echo "=============================================="
echo "Let's Encrypt Certificate Management"
echo "=============================================="
echo "Hostname: $HOSTNAME"
echo "Email: $LETSENCRYPT_EMAIL"
echo ""

# -----------------------------------------------------------------------------
# Function to check if certificate is from Let's Encrypt
# Uses docker exec since cert files are owned by root
# -----------------------------------------------------------------------------
is_letsencrypt_cert() {
    # Check if issuer contains "Let's Encrypt" using docker exec for root access
    issuer=$(docker exec iredmail-core openssl x509 -in "/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem" -noout -issuer 2>/dev/null || echo "")
    if echo "$issuer" | grep -qi "Let's Encrypt"; then
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# Function to get certificate details
# -----------------------------------------------------------------------------
show_cert_details() {
    docker exec iredmail-core openssl x509 -in "/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem" -noout -subject -issuer -dates 2>/dev/null || echo "  (unable to read certificate)"
}

# -----------------------------------------------------------------------------
# Function to check certificate expiry (returns 0 if expiring within 30 days)
# -----------------------------------------------------------------------------
cert_expiring_soon() {
    # Check if cert expires within 30 days
    if docker exec iredmail-core openssl x509 -in "/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem" -noout -checkend 2592000 2>/dev/null; then
        return 1  # Not expiring soon
    fi
    return 0  # Expiring soon or invalid
}

# -----------------------------------------------------------------------------
# Function to check if any certificate exists
# -----------------------------------------------------------------------------
cert_exists() {
    docker exec iredmail-core test -f "/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem" 2>/dev/null
    return $?
}

# -----------------------------------------------------------------------------
# Function to reload all services
# -----------------------------------------------------------------------------
reload_services() {
    echo "Reloading services..."
    docker exec iredmail-core nginx -s reload 2>/dev/null || true
    docker exec iredmail-core postfix reload 2>/dev/null || true
    docker exec iredmail-core doveadm reload 2>/dev/null || true
    echo "Services reloaded."
}

# -----------------------------------------------------------------------------
# Function to get this server's public IP
# -----------------------------------------------------------------------------
get_server_ip() {
    # Try multiple methods to get public IP
    local ip=""
    ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null) ||
    ip=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null) ||
    ip=$(curl -s --max-time 5 https://icanhazip.com 2>/dev/null) ||
    ip=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null)
    echo "$ip"
}

# -----------------------------------------------------------------------------
# Function to check if a domain resolves to our server
# -----------------------------------------------------------------------------
domain_points_to_us() {
    local domain="$1"
    local our_ip="$2"

    # Get IP(s) the domain resolves to
    local resolved_ips=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')

    if [ -z "$resolved_ips" ]; then
        return 1  # Domain doesn't resolve
    fi

    # Check if any of the resolved IPs match ours
    for ip in $resolved_ips; do
        if [ "$ip" == "$our_ip" ]; then
            return 0  # Match found
        fi
    done

    return 1  # No match
}

# -----------------------------------------------------------------------------
# Check current certificate status
# -----------------------------------------------------------------------------
echo "Checking current certificate status..."

NEED_NEW_CERT="no"
CERT_VALID="no"
FORCE_FLAG="$1"

if cert_exists; then
    echo "Found existing certificate."
    echo ""
    echo "Certificate details:"
    show_cert_details
    echo ""

    if is_letsencrypt_cert; then
        echo "Status: Valid Let's Encrypt certificate"

        if cert_expiring_soon; then
            echo "Note: Certificate is expiring within 30 days, will renew"
            NEED_NEW_CERT="yes"
            CERT_VALID="no"
        else
            echo "Certificate is valid and not expiring soon."
            NEED_NEW_CERT="no"
            CERT_VALID="yes"
            FORCE_FLAG="$1"
        fi
    else
        echo "Status: Self-signed or non-Let's Encrypt certificate"
        echo "Will obtain a new Let's Encrypt certificate..."
        NEED_NEW_CERT="yes"

        # Remove self-signed certificate and any stale certbot data via docker (has root access)
        echo ""
        echo "Removing existing certificate data..."
        docker exec iredmail-core rm -rf "/etc/letsencrypt/live/${HOSTNAME}" 2>/dev/null || true
        docker exec iredmail-core rm -rf "/etc/letsencrypt/archive/${HOSTNAME}" 2>/dev/null || true
        docker exec iredmail-core rm -f "/etc/letsencrypt/renewal/${HOSTNAME}.conf" 2>/dev/null || true
    fi
else
    echo "No existing certificate found."
    NEED_NEW_CERT="yes"
fi

# -----------------------------------------------------------------------------
# Ensure services are running
# -----------------------------------------------------------------------------
echo ""
echo "Checking if services are running..."

if ! docker compose -f "${PROJECT_DIR}/docker-compose.yml" ps 2>/dev/null | grep -q "iredmail-core.*Up"; then
    echo "Starting services..."
    docker compose -f "${PROJECT_DIR}/docker-compose.yml" up -d iredmail
    echo "Waiting for services to start (30 seconds)..."
    sleep 30
fi

# -----------------------------------------------------------------------------
# Obtain certificate from Let's Encrypt
# -----------------------------------------------------------------------------
echo ""
echo "Requesting certificate from Let's Encrypt..."
echo "=============================================="

# Get our server's public IP for DNS validation
echo "Detecting server public IP..."
SERVER_IP=$(get_server_ip)

if [ -z "$SERVER_IP" ]; then
    echo "WARNING: Could not detect server public IP. Skipping DNS validation."
    echo "         Extra domains will be included without validation."
    SKIP_DNS_CHECK=true
else
    echo "Server IP: $SERVER_IP"
    SKIP_DNS_CHECK=false
fi
echo ""

# Build domain list starting with primary hostname
DOMAIN_ARGS="-d ${HOSTNAME}"
VALIDATED_DOMAINS="${HOSTNAME}"
SKIPPED_DOMAINS=""

# Add extra domains if configured (comma-separated list)
if [ -n "$CERT_EXTRA_DOMAINS" ]; then
    echo "Checking extra domains from CERT_EXTRA_DOMAINS..."
    echo ""
    IFS=',' read -ra EXTRA_DOMAINS <<< "$CERT_EXTRA_DOMAINS"
    for domain in "${EXTRA_DOMAINS[@]}"; do
        # Trim whitespace
        domain=$(echo "$domain" | xargs)
        if [ -z "$domain" ]; then
            continue
        fi

        if [ "$SKIP_DNS_CHECK" == "true" ]; then
            # No DNS check, include all
            echo "  [?] ${domain} (DNS check skipped)"
            DOMAIN_ARGS="$DOMAIN_ARGS -d $domain"
            VALIDATED_DOMAINS="${VALIDATED_DOMAINS}, ${domain}"
        elif domain_points_to_us "$domain" "$SERVER_IP"; then
            echo "  [OK] ${domain} -> ${SERVER_IP}"
            DOMAIN_ARGS="$DOMAIN_ARGS -d $domain"
            VALIDATED_DOMAINS="${VALIDATED_DOMAINS}, ${domain}"
        else
            resolved=$(dig +short "$domain" 2>/dev/null | head -1)
            if [ -z "$resolved" ]; then
                echo "  [SKIP] ${domain} (does not resolve - configure DNS first)"
            else
                echo "  [SKIP] ${domain} (resolves to ${resolved}, not our server)"
            fi
            SKIPPED_DOMAINS="${SKIPPED_DOMAINS}${domain}, "
        fi
    done
    echo ""
fi

echo "Domains to certify: ${VALIDATED_DOMAINS}"
if [ -n "$SKIPPED_DOMAINS" ]; then
    echo "Skipped domains:    ${SKIPPED_DOMAINS%, }"
    echo ""
    echo "Note: Skipped domains will be included once their DNS points to this server."
fi
echo ""

# -----------------------------------------------------------------------------
# Check if we need to expand the certificate (add new domains)
# -----------------------------------------------------------------------------
# Get current domains in certificate
CURRENT_CERT_DOMAINS=""
if cert_exists; then
    CURRENT_CERT_DOMAINS=$(docker exec iredmail-core openssl x509 -in "/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -1 | sed 's/DNS://g' | tr -d ' ' | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')
fi

# Build sorted list of requested domains for comparison
REQUESTED_DOMAINS_SORTED=$(echo "$VALIDATED_DOMAINS" | tr ',' '\n' | tr -d ' ' | sort | tr '\n' ',' | sed 's/,$//')
CURRENT_DOMAINS_SORTED=$(echo "$CURRENT_CERT_DOMAINS" | tr ',' '\n' | tr -d ' ' | sort | tr '\n' ',' | sed 's/,$//')

echo "Current cert domains: ${CURRENT_CERT_DOMAINS:-none}"
echo "Requested domains:    ${VALIDATED_DOMAINS}"
echo ""

# Determine certbot flags and whether to proceed
CERTBOT_FLAGS=""
DOMAINS_CHANGED="no"

if [ -n "$CURRENT_CERT_DOMAINS" ] && [ "$CURRENT_DOMAINS_SORTED" != "$REQUESTED_DOMAINS_SORTED" ]; then
    echo "Certificate domain list has changed - using --expand to add new domains"
    CERTBOT_FLAGS="--expand"
    DOMAINS_CHANGED="yes"
elif [ "$FORCE_FLAG" == "--force" ]; then
    echo "Force flag detected - will renew certificate"
    CERTBOT_FLAGS="--force-renewal"
elif [ "$CERT_VALID" == "yes" ]; then
    echo ""
    echo "Certificate is valid and domains haven't changed."
    echo "No action needed. Use --force to renew anyway."
    exit 0
else
    echo "Using --keep-until-expiring (won't renew if cert is still valid)"
    CERTBOT_FLAGS="--keep-until-expiring"
fi
echo ""

# Note: Must override entrypoint since docker-compose.yml sets it to a renewal loop
docker compose -f "${PROJECT_DIR}/docker-compose.yml" run --rm --entrypoint "certbot" certbot \
    certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "${LETSENCRYPT_EMAIL}" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    $CERTBOT_FLAGS \
    --cert-name "${HOSTNAME}" \
    $DOMAIN_ARGS

# -----------------------------------------------------------------------------
# Verify certificate was obtained and reload services
# -----------------------------------------------------------------------------
echo ""

# Give filesystem a moment to sync
sleep 2

if cert_exists && is_letsencrypt_cert; then
    echo "=============================================="
    echo "Certificate obtained successfully!"
    echo "=============================================="
    echo ""
    echo "Certificate details:"
    show_cert_details
    echo ""
    reload_services
    echo ""
    echo "Done! Your mail server is now using a valid Let's Encrypt certificate."
    echo ""
    echo "Automatic renewal is handled by the certbot container (checks every 12 hours)."
else
    echo "=============================================="
    echo "ERROR: Certificate was not obtained"
    echo "=============================================="
    echo ""
    echo "Please check:"
    echo "  1. DNS A record for ${HOSTNAME} points to this server's public IP"
    echo "  2. Port 80 is accessible from the internet"
    echo "  3. Firewall allows inbound HTTP traffic"
    echo ""
    echo "You can check the logs with:"
    echo "  docker compose logs certbot"
    exit 1
fi
