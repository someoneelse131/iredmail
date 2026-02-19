#!/bin/bash
# =============================================================================
# iRedMail Single Mailbox Restore Script
# =============================================================================
#
# Restores a single mailbox from a backup archive without affecting
# other mailboxes or services.
#
# Usage: restore-mailbox.sh <backup_file.tar.gz> <email@domain.com>
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESTORE_DIR="/tmp/iredmail_restore_mailbox_$$"
VMAIL_DIR="${PROJECT_DIR}/data/vmail"

BACKUP_FILE="$1"
EMAIL="$2"

if [ -z "$BACKUP_FILE" ] || [ -z "$EMAIL" ]; then
    echo "Usage: $0 <backup_file.tar.gz> <email@domain.com>"
    echo ""
    echo "Examples:"
    echo "  $0 /opt/iredmail/data/backup/iredmail_backup_20260219.tar.gz flo@chiaruzzi.ch"
    echo ""
    echo "Available backups:"
    ls -lh "${PROJECT_DIR}/data/backup/"iredmail_backup_*.tar.gz 2>/dev/null || echo "  No backups found."
    exit 1
fi

if [ ! -f "$BACKUP_FILE" ]; then
    echo "ERROR: Backup file not found: $BACKUP_FILE"
    exit 1
fi

# Parse email
USER_PART="${EMAIL%%@*}"
DOMAIN="${EMAIL##*@}"

if [ -z "$USER_PART" ] || [ -z "$DOMAIN" ] || [ "$USER_PART" = "$EMAIL" ]; then
    echo "ERROR: Invalid email address: $EMAIL"
    exit 1
fi

# Build Maildir path components (first 3 chars of username)
C1="${USER_PART:0:1}"
C2="${USER_PART:1:1}"
C3="${USER_PART:2:1}"
MAILDIR_PATTERN="${DOMAIN}/${C1}/${C2}/${C3}/${USER_PART}-*"

echo "=============================================="
echo "iRedMail Mailbox Restore"
echo "Date: $(date)"
echo "Backup: $BACKUP_FILE"
echo "Mailbox: $EMAIL"
echo "=============================================="

# Extract backup
echo ""
echo "Extracting backup..."
mkdir -p "$RESTORE_DIR"
tar -xzf "$BACKUP_FILE" -C "$RESTORE_DIR"

EXTRACTED_DIR=$(ls -d "${RESTORE_DIR}"/*/ | head -1)

if [ ! -f "${EXTRACTED_DIR}/vmail.tar.gz" ]; then
    echo "ERROR: No vmail archive found in backup."
    rm -rf "$RESTORE_DIR"
    exit 1
fi

# Extract vmail and find the mailbox
echo "Extracting mail storage..."
tar -xzf "${EXTRACTED_DIR}/vmail.tar.gz" -C "$RESTORE_DIR"

# Find the mailbox directory
MAILBOX_DIR=$(ls -d "${RESTORE_DIR}/vmail/vmail1/${MAILDIR_PATTERN}" 2>/dev/null | head -1)

if [ -z "$MAILBOX_DIR" ]; then
    echo "ERROR: Mailbox for $EMAIL not found in backup."
    echo ""
    echo "Available mailboxes in this backup:"
    find "${RESTORE_DIR}/vmail/vmail1/" -mindepth 4 -maxdepth 4 -type d 2>/dev/null | \
        sed "s|${RESTORE_DIR}/vmail/vmail1/||" | sort
    rm -rf "$RESTORE_DIR"
    exit 1
fi

MAILBOX_NAME=$(basename "$MAILBOX_DIR")
MAILBOX_SIZE=$(du -sh "$MAILBOX_DIR" | cut -f1)

echo ""
echo "Found mailbox: $MAILBOX_NAME"
echo "Size: $MAILBOX_SIZE"
echo ""

# Check if mailbox exists on target
TARGET_DIR=$(ls -d "${VMAIL_DIR}/vmail1/${MAILDIR_PATTERN}" 2>/dev/null | head -1)

if [ -n "$TARGET_DIR" ]; then
    echo "WARNING: Mailbox already exists at $TARGET_DIR"
    echo "This will OVERWRITE the existing mailbox data!"
else
    echo "Mailbox does not exist yet, will create it."
    TARGET_DIR="${VMAIL_DIR}/vmail1/${DOMAIN}/${C1}/${C2}/${C3}/${MAILBOX_NAME}"
fi

read -p "Continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Restore cancelled."
    rm -rf "$RESTORE_DIR"
    exit 0
fi

# Restore mailbox
echo ""
echo "Restoring mailbox..."
mkdir -p "$(dirname "$TARGET_DIR")"
cp -a "$MAILBOX_DIR" "$TARGET_DIR"

# Fix ownership (vmail user, UID 2000)
echo "Fixing permissions..."
docker exec iredmail-core chown -R vmail:vmail "/var/vmail/vmail1/${DOMAIN}/${C1}/${C2}/${C3}/"

# Cleanup
rm -rf "$RESTORE_DIR"

echo ""
echo "=============================================="
echo "Mailbox Restore Complete!"
echo "=============================================="
echo "Restored: $EMAIL"
echo "Location: $TARGET_DIR"
echo ""
echo "Note: If the mailbox user does not exist in the database,"
echo "you need to recreate it via iRedAdmin or manually:"
echo "  See Joplin note '04 – Mailbox manuell hinzufügen'"
echo ""
