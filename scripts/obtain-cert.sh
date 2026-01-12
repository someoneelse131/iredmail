#!/bin/bash
# =============================================================================
# Obtain Let's Encrypt SSL Certificate
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

echo "=============================================="
echo "Obtaining Let's Encrypt Certificate"
echo "=============================================="
echo "Hostname: $HOSTNAME"
echo "Email: $LETSENCRYPT_EMAIL"
echo ""

# Check if services are running
if ! docker compose -f "${PROJECT_DIR}/docker-compose.yml" ps | grep -q "iredmail-core.*Up"; then
    echo "Starting services..."
    docker compose -f "${PROJECT_DIR}/docker-compose.yml" up -d iredmail
    echo "Waiting for services to start..."
    sleep 30
fi

# Obtain certificate
echo ""
echo "Requesting certificate from Let's Encrypt..."
docker compose -f "${PROJECT_DIR}/docker-compose.yml" run --rm certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "${LETSENCRYPT_EMAIL}" \
    --agree-tos \
    --no-eff-email \
    --force-renewal \
    -d "${HOSTNAME}"

# Check if certificate was obtained
if [ -f "${PROJECT_DIR}/data/ssl/live/${HOSTNAME}/fullchain.pem" ]; then
    echo ""
    echo "=============================================="
    echo "Certificate obtained successfully!"
    echo "=============================================="
    echo ""
    echo "Certificate files:"
    echo "  ${PROJECT_DIR}/data/ssl/live/${HOSTNAME}/fullchain.pem"
    echo "  ${PROJECT_DIR}/data/ssl/live/${HOSTNAME}/privkey.pem"
    echo ""
    echo "Reloading services..."
    docker exec iredmail-core nginx -s reload
    docker exec iredmail-core postfix reload
    docker exec iredmail-core doveadm reload
    echo "Done!"
else
    echo ""
    echo "ERROR: Certificate was not obtained."
    echo "Please check:"
    echo "  1. DNS is configured correctly (A record for ${HOSTNAME})"
    echo "  2. Port 80 is accessible from the internet"
    echo "  3. Firewall allows inbound HTTP traffic"
    exit 1
fi
