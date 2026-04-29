#!/bin/bash
# =============================================================================
# iRedMail Borg Backup
# =============================================================================
# Deduplicating, encrypted backup with BorgBackup.
# Designed to run every 4 hours via /etc/cron.d/iredmail-borg-backup.
#
# Repo location: data/borg-repo/ (local). For offsite, run `borg sync` to a
# remote repo separately.
#
# One-time setup (run as root on the server):
#   1) apt-get install -y borgbackup
#   2) Add to /opt/iredmail/.env:
#        BORG_PASSPHRASE=<output of: openssl rand -hex 32>
#   3) Init the repo:
#        export BORG_PASSPHRASE=...   # same value
#        borg init --encryption=repokey-blake2 /opt/iredmail/data/borg-repo
#   4) Run this script once manually to verify:
#        /opt/iredmail/scripts/borg-backup.sh
#   5) Drop the cron file in /etc/cron.d/ (see scripts/borg-backup-cron).
#
# Restore (any archive):
#   borg list /opt/iredmail/data/borg-repo
#   borg extract /opt/iredmail/data/borg-repo::<archive-name> path/to/file
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BORG_REPO="${PROJECT_DIR}/data/borg-repo"
DB_DUMP_DIR="${PROJECT_DIR}/data/db-dumps"
DB_DUMP_FILE="${DB_DUMP_DIR}/all_databases.sql"
ARCHIVE_NAME="mail-$(date +%Y-%m-%d_%H%M%S)"

# Read BORG_PASSPHRASE and MYSQL_ROOT_PASSWORD from .env without `source`
# (avoids shell-quoting surprises with random secrets).
if [ ! -f "${PROJECT_DIR}/.env" ]; then
    echo "ERROR: ${PROJECT_DIR}/.env not found" >&2
    exit 1
fi

get_env() {
    local key="$1"
    grep -E "^${key}=" "${PROJECT_DIR}/.env" | head -n1 | cut -d= -f2-
}

BORG_PASSPHRASE="$(get_env BORG_PASSPHRASE)"
MYSQL_ROOT_PASSWORD="$(get_env MYSQL_ROOT_PASSWORD)"

if [ -z "${BORG_PASSPHRASE}" ]; then
    echo "ERROR: BORG_PASSPHRASE not set in .env. See header of this script." >&2
    exit 1
fi
if [ -z "${MYSQL_ROOT_PASSWORD}" ]; then
    echo "ERROR: MYSQL_ROOT_PASSWORD not set in .env" >&2
    exit 1
fi

export BORG_REPO BORG_PASSPHRASE

echo "=============================================="
echo "iRedMail Borg Backup"
echo "Date:    $(date)"
echo "Archive: ${ARCHIVE_NAME}"
echo "Repo:    ${BORG_REPO}"
echo "=============================================="

# 1) MariaDB dump (single-transaction is consistent for InnoDB).
echo ""
echo "[1/3] Dumping MariaDB..."
mkdir -p "${DB_DUMP_DIR}"
chmod 700 "${DB_DUMP_DIR}"
docker exec iredmail-db mysqldump \
    -u root \
    -p"${MYSQL_ROOT_PASSWORD}" \
    --all-databases \
    --single-transaction \
    --quick \
    --routines \
    --events \
    > "${DB_DUMP_FILE}"
chmod 600 "${DB_DUMP_FILE}"
echo "DB dump: $(du -h "${DB_DUMP_FILE}" | cut -f1)"

# 2) Borg create — dedup + zstd compression + encryption (via repokey).
# The repo lives under data/, so we exclude it to avoid recursion.
echo ""
echo "[2/3] Creating Borg archive..."
borg create \
    --verbose \
    --stats \
    --compression zstd,3 \
    --exclude-caches \
    --lock-wait 60 \
    --exclude "${PROJECT_DIR}/data/backup" \
    --exclude "${PROJECT_DIR}/data/borg-repo" \
    --exclude "${PROJECT_DIR}/data/logs" \
    --exclude "${PROJECT_DIR}/data/mysql" \
    --exclude "${PROJECT_DIR}/data/clamav" \
    --exclude "${PROJECT_DIR}/data/postfix-queue" \
    --exclude "${PROJECT_DIR}/data/certbot-www" \
    --exclude "${PROJECT_DIR}/data/rescue-*" \
    "::${ARCHIVE_NAME}" \
    "${PROJECT_DIR}/data" \
    "${PROJECT_DIR}/config" \
    "${PROJECT_DIR}/rootfs" \
    "${PROJECT_DIR}/scripts" \
    "${PROJECT_DIR}/docker-compose.yml" \
    "${PROJECT_DIR}/Dockerfile" \
    "${PROJECT_DIR}/.env"

# 3) Retention policy. Borg "keeps the most recent archive in each bucket".
# With a 4-hour cadence: 6 archives/day. The hourly bucket retains the most
# recent backup per distinct hour, so 6 of those covers ~24 h of granularity.
echo ""
echo "[3/3] Pruning old archives..."
borg prune \
    --verbose \
    --list \
    --keep-hourly 6 \
    --keep-daily 14 \
    --keep-weekly 8 \
    --keep-monthly 12

# Compaction is expensive (rewrites segments). Run weekly only.
if [ "$(date +%u)" = "7" ] && [ "$(date +%H)" = "00" ]; then
    echo ""
    echo "[Sunday 00:xx] Compacting repository..."
    borg compact --verbose
fi

echo ""
echo "=============================================="
echo "Borg Backup Complete"
echo "Repo size: $(du -sh "${BORG_REPO}" | cut -f1)"
echo "=============================================="
