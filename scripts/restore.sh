#!/bin/bash
# =============================================================================
# iRedMail Docker Restore Script
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESTORE_DIR="/tmp/iredmail_restore_$$"

BACKUP_FILE="$1"

if [ -z "$BACKUP_FILE" ]; then
    echo "Usage: $0 <backup_file.tar.gz>"
    echo ""
    echo "Available backups:"
    ls -la "${PROJECT_DIR}/data/backup/"*.tar.gz 2>/dev/null || echo "  No backups found."
    exit 1
fi

if [ ! -f "$BACKUP_FILE" ]; then
    echo "ERROR: Backup file not found: $BACKUP_FILE"
    exit 1
fi

# Load environment
if [ -f "${PROJECT_DIR}/.env" ]; then
    source "${PROJECT_DIR}/.env"
fi

echo "=============================================="
echo "iRedMail Docker Restore"
echo "Date: $(date)"
echo "Backup: $BACKUP_FILE"
echo "=============================================="
echo ""
echo "WARNING: This will overwrite existing data!"
read -p "Are you sure you want to continue? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Restore cancelled."
    exit 0
fi

# Stop services
echo ""
echo "Stopping services..."
docker compose -f "${PROJECT_DIR}/docker-compose.yml" stop iredmail

# Create restore directory
mkdir -p "$RESTORE_DIR"

# Extract backup
echo ""
echo "Extracting backup..."
tar -xzf "$BACKUP_FILE" -C "$RESTORE_DIR"

# Find extracted directory
EXTRACTED_DIR=$(ls -d "${RESTORE_DIR}"/*/ | head -1)

# Restore database
echo ""
echo "Restoring database..."
if [ -f "${EXTRACTED_DIR}/all_databases.sql" ]; then
    docker exec -i iredmail-db mysql \
        -u root \
        -p"${MYSQL_ROOT_PASSWORD}" \
        < "${EXTRACTED_DIR}/all_databases.sql"
    echo "Database restored."
else
    echo "No database backup found, skipping."
fi

# Restore mail storage
echo ""
echo "Restoring mail storage..."
if [ -f "${EXTRACTED_DIR}/vmail.tar.gz" ]; then
    tar -xzf "${EXTRACTED_DIR}/vmail.tar.gz" -C "${PROJECT_DIR}/data/"
    echo "Mail storage restored."
else
    echo "No mail storage backup found, skipping."
fi

# Restore DKIM keys
echo ""
echo "Restoring DKIM keys..."
if [ -f "${EXTRACTED_DIR}/dkim.tar.gz" ]; then
    tar -xzf "${EXTRACTED_DIR}/dkim.tar.gz" -C "${PROJECT_DIR}/data/"
    echo "DKIM keys restored."
else
    echo "No DKIM backup found, skipping."
fi

# Restore SSL certificates
echo ""
echo "Restoring SSL certificates..."
if [ -f "${EXTRACTED_DIR}/ssl.tar.gz" ]; then
    tar -xzf "${EXTRACTED_DIR}/ssl.tar.gz" -C "${PROJECT_DIR}/data/"
    echo "SSL certificates restored."
else
    echo "No SSL backup found, skipping."
fi

# Cleanup
rm -rf "$RESTORE_DIR"

# Start services
echo ""
echo "Starting services..."
docker compose -f "${PROJECT_DIR}/docker-compose.yml" start iredmail

echo ""
echo "=============================================="
echo "Restore Complete!"
echo "=============================================="
echo ""
echo "Please verify that all services are running:"
echo "  docker compose ps"
echo ""
