#!/bin/bash
# =============================================================================
# iRedMail Docker Backup Script
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${PROJECT_DIR}/data/backup"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=${RETENTION_DAYS:-30}

# Load environment
if [ -f "${PROJECT_DIR}/.env" ]; then
    source "${PROJECT_DIR}/.env"
fi

echo "=============================================="
echo "iRedMail Docker Backup"
echo "Date: $(date)"
echo "=============================================="

# Create backup directory
mkdir -p "${BACKUP_DIR}/${DATE}"

# Backup MariaDB
echo ""
echo "Backing up database..."
docker exec iredmail-db mysqldump \
    -u root \
    -p"${MYSQL_ROOT_PASSWORD}" \
    --all-databases \
    --single-transaction \
    --quick \
    > "${BACKUP_DIR}/${DATE}/all_databases.sql"
echo "Database backup complete."

# Backup mail storage
echo ""
echo "Backing up mail storage..."
if [ -d "${PROJECT_DIR}/data/vmail" ]; then
    tar -czf "${BACKUP_DIR}/${DATE}/vmail.tar.gz" \
        -C "${PROJECT_DIR}/data" vmail
    echo "Mail storage backup complete."
else
    echo "No mail storage found, skipping."
fi

# Backup DKIM keys
echo ""
echo "Backing up DKIM keys..."
if [ -d "${PROJECT_DIR}/data/dkim" ]; then
    tar -czf "${BACKUP_DIR}/${DATE}/dkim.tar.gz" \
        -C "${PROJECT_DIR}/data" dkim
    echo "DKIM backup complete."
else
    echo "No DKIM keys found, skipping."
fi

# Backup SSL certificates
echo ""
echo "Backing up SSL certificates..."
if [ -d "${PROJECT_DIR}/data/ssl" ]; then
    tar -czf "${BACKUP_DIR}/${DATE}/ssl.tar.gz" \
        -C "${PROJECT_DIR}/data" ssl
    echo "SSL backup complete."
else
    echo "No SSL certificates found, skipping."
fi

# Backup configuration
echo ""
echo "Backing up configuration..."
tar -czf "${BACKUP_DIR}/${DATE}/config.tar.gz" \
    -C "${PROJECT_DIR}" config .env 2>/dev/null || \
tar -czf "${BACKUP_DIR}/${DATE}/config.tar.gz" \
    -C "${PROJECT_DIR}" config
echo "Configuration backup complete."

# Create final archive
echo ""
echo "Creating final backup archive..."
tar -czf "${BACKUP_DIR}/iredmail_backup_${DATE}.tar.gz" \
    -C "${BACKUP_DIR}" "${DATE}"

# Remove temporary directory
rm -rf "${BACKUP_DIR}/${DATE}"

# Calculate size
BACKUP_SIZE=$(du -h "${BACKUP_DIR}/iredmail_backup_${DATE}.tar.gz" | cut -f1)

echo ""
echo "=============================================="
echo "Backup Complete!"
echo "=============================================="
echo "File: ${BACKUP_DIR}/iredmail_backup_${DATE}.tar.gz"
echo "Size: ${BACKUP_SIZE}"
echo ""

# Clean old backups
echo "Cleaning backups older than ${RETENTION_DAYS} days..."
find "${BACKUP_DIR}" -name "iredmail_backup_*.tar.gz" \
    -mtime +${RETENTION_DAYS} -delete
echo "Done."
