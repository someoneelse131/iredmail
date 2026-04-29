#!/bin/bash
# =============================================================================
# iRedMail Borg Restore (interactive)
# =============================================================================
# Restores from a Borg archive in /opt/iredmail/data/borg-repo (default) or a
# repo passed as the first argument.
#
# Modes:
#   1) List files in an archive
#   2) Extract a single path to /tmp
#   3) Full restore: stop container -> overwrite data dirs -> re-import DB -> start
#
# Required: BORG_PASSPHRASE in .env, MYSQL_ROOT_PASSWORD in .env, borg installed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BORG_REPO_DEFAULT="${PROJECT_DIR}/data/borg-repo"
BORG_REPO="${1:-$BORG_REPO_DEFAULT}"

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
    echo "ERROR: BORG_PASSPHRASE not set in .env." >&2
    exit 1
fi
if ! command -v borg >/dev/null 2>&1; then
    echo "ERROR: borg not installed. Run: apt-get install borgbackup" >&2
    exit 1
fi
if [ ! -d "${BORG_REPO}/data" ]; then
    echo "ERROR: Borg repo not found at ${BORG_REPO}" >&2
    echo "Pass a different path as argument: $0 /path/to/borg-repo" >&2
    exit 1
fi

export BORG_REPO BORG_PASSPHRASE

echo "=============================================="
echo "iRedMail Borg Restore"
echo "Repo: ${BORG_REPO}"
echo "=============================================="
echo ""

# List archives, save to a temp file so the user-facing numbering matches what
# we re-read for selection.
ARCHIVE_LIST=$(mktemp)
trap 'rm -f "${ARCHIVE_LIST}"' EXIT
borg list "${BORG_REPO}" > "${ARCHIVE_LIST}"

if [ ! -s "${ARCHIVE_LIST}" ]; then
    echo "Repo contains no archives." >&2
    exit 1
fi

echo "Available archives:"
nl -ba "${ARCHIVE_LIST}"
echo ""

read -rp "Enter archive number (or full archive name): " choice
if [[ "${choice}" =~ ^[0-9]+$ ]]; then
    ARCHIVE_NAME="$(sed -n "${choice}p" "${ARCHIVE_LIST}" | awk '{print $1}')"
else
    ARCHIVE_NAME="${choice}"
fi
if [ -z "${ARCHIVE_NAME}" ]; then
    echo "Invalid selection" >&2
    exit 1
fi

echo "Selected: ${ARCHIVE_NAME}"
echo ""
echo "Restore mode:"
echo "  1) List files in this archive"
echo "  2) Extract a specific path to /tmp"
echo "  3) Full restore (stops container, replaces data, re-imports DB, restarts)"
echo "  4) Cancel"
read -rp "Choice [1-4]: " mode

case "${mode}" in
    1)
        borg list "${BORG_REPO}::${ARCHIVE_NAME}"
        ;;
    2)
        read -rp "Path inside archive (e.g. opt/iredmail/data/vmail/<dom>/...): " path
        path="${path#/}"
        target="/tmp/borg-restore-$$"
        mkdir -p "${target}"
        cd "${target}"
        borg extract --list "${BORG_REPO}::${ARCHIVE_NAME}" "${path}"
        echo ""
        echo "Extracted to: ${target}/${path}"
        ;;
    3)
        echo ""
        echo "WARNING: Full restore will:"
        echo "  - Stop the iredmail-core container"
        echo "  - Replace ${PROJECT_DIR}/data/{vmail,dkim,ssl,sogo,mlmmj,mlmmj-archive,"
        echo "                                  iredmail-state,imapsieve_copy,spamassassin}"
        echo "  - Re-import the database from the archive's dump"
        echo "  - Restart iredmail-core"
        echo ""
        read -rp "Type EXACTLY 'yes-replace-everything' to proceed: " confirm
        if [ "${confirm}" != "yes-replace-everything" ]; then
            echo "Cancelled."
            exit 0
        fi

        target="/tmp/borg-restore-$$"
        mkdir -p "${target}"

        echo ""
        echo "[1/5] Extracting archive to ${target}..."
        cd "${target}"
        borg extract --list "${BORG_REPO}::${ARCHIVE_NAME}"

        echo ""
        echo "[2/5] Stopping iredmail container..."
        docker compose -f "${PROJECT_DIR}/docker-compose.yml" stop iredmail

        echo ""
        echo "[3/5] Restoring data directories..."
        for d in vmail dkim ssl sogo mlmmj mlmmj-archive iredmail-state imapsieve_copy spamassassin; do
            if [ -d "${target}/opt/iredmail/data/${d}" ]; then
                mkdir -p "${PROJECT_DIR}/data/${d}"
                rsync -a --delete "${target}/opt/iredmail/data/${d}/" "${PROJECT_DIR}/data/${d}/"
                echo "  ${d}: restored"
            fi
        done

        echo ""
        echo "[4/5] Re-importing database..."
        DB_DUMP="${target}/opt/iredmail/data/db-dumps/all_databases.sql"
        if [ -f "${DB_DUMP}" ]; then
            docker exec -i iredmail-db mysql -u root -p"${MYSQL_ROOT_PASSWORD}" < "${DB_DUMP}"
            echo "Database imported."
        else
            echo "WARNING: no DB dump in archive at expected path; skipped"
        fi

        echo ""
        echo "[5/5] Starting iredmail container..."
        docker compose -f "${PROJECT_DIR}/docker-compose.yml" start iredmail

        echo ""
        echo "Cleanup ${target}..."
        rm -rf "${target}"

        echo ""
        echo "=============================================="
        echo "Full restore complete."
        echo "Verify: docker compose ps"
        echo "        docker compose logs -f iredmail"
        echo "=============================================="
        ;;
    4)
        echo "Cancelled."
        ;;
    *)
        echo "Invalid mode" >&2
        exit 1
        ;;
esac
