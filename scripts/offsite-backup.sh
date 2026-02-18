#!/bin/bash
# =============================================================================
# iRedMail Offsite Backup – scp to Synology NAS via WireGuard
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${PROJECT_DIR}/data/backup"

SSH_KEY="/root/.ssh/id_ed25519_synology_backup"
REMOTE_USER="backup_user"
REMOTE_HOST="10.0.0.2"
REMOTE_DIR="/volume1/backup/iredmail"
REMOTE_PORT=44
REMOTE_RETENTION_DAYS=30

SSH_OPTS="-p ${REMOTE_PORT} -i ${SSH_KEY} -o StrictHostKeyChecking=accept-new"

echo "=============================================="
echo "iRedMail Offsite Backup"
echo "Date: $(date)"
echo "=============================================="

# Find newest local backup
LATEST_BACKUP=$(ls -t "${BACKUP_DIR}"/iredmail_backup_*.tar.gz 2>/dev/null | head -1)

if [ -z "$LATEST_BACKUP" ]; then
    echo "ERROR: No local backup found in ${BACKUP_DIR}"
    exit 1
fi

echo "Latest backup: ${LATEST_BACKUP}"
echo "Size: $(du -h "$LATEST_BACKUP" | cut -f1)"

# Check VPN connectivity
echo ""
echo "Checking VPN connectivity..."
if ! ping -c 3 -W 5 "$REMOTE_HOST" > /dev/null 2>&1; then
    echo "ERROR: Cannot reach ${REMOTE_HOST} – VPN down?"
    exit 1
fi
echo "VPN connection OK."

# scp to NAS
echo ""
echo "Copying to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}..."
scp -O -P "${REMOTE_PORT}" -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new \
    "$LATEST_BACKUP" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"

echo "Copy complete."

# Clean old remote backups
echo ""
echo "Cleaning remote backups older than ${REMOTE_RETENTION_DAYS} days..."
ssh ${SSH_OPTS} "${REMOTE_USER}@${REMOTE_HOST}" \
    "find ${REMOTE_DIR} -name 'iredmail_backup_*.tar.gz' -mtime +${REMOTE_RETENTION_DAYS} -delete"
echo "Remote cleanup done."

echo ""
echo "=============================================="
echo "Offsite Backup Complete!"
echo "=============================================="
