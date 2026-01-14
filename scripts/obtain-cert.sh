#!/bin/bash
# =============================================================================
# Obtain Let's Encrypt SSL Certificate
# =============================================================================
# This script checks if a valid Let's Encrypt certificate exists.
# If not (or if only a self-signed cert exists), it obtains a new one.
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
# Check current certificate status
# -----------------------------------------------------------------------------
echo "Checking current certificate status..."

NEED_NEW_CERT="no"

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
        else
            echo ""
            echo "Certificate is valid and not expiring soon."
            echo "To force renewal, run: $0 --force"

            if [ "$1" != "--force" ]; then
                echo ""
                echo "Exiting (no action needed)."
                exit 0
            fi
            echo ""
            echo "Force flag detected, proceeding with renewal..."
            NEED_NEW_CERT="yes"
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
# Exit if no new cert needed
# -----------------------------------------------------------------------------
if [ "$NEED_NEW_CERT" != "yes" ]; then
    echo ""
    echo "No certificate action needed."
    exit 0
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

# Note: Must override entrypoint since docker-compose.yml sets it to a renewal loop
# Using --keep-until-expiring to avoid interactive prompts when cert exists
docker compose -f "${PROJECT_DIR}/docker-compose.yml" run --rm --entrypoint "certbot" certbot \
    certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "${LETSENCRYPT_EMAIL}" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --keep-until-expiring \
    --cert-name "${HOSTNAME}" \
    -d "${HOSTNAME}"

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
