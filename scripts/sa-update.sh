#!/bin/bash
# =============================================================================
# Weekly SpamAssassin ruleset refresh
# =============================================================================
# Runs on the HOST (see scripts/sa-update-cron), driving sa-update inside the
# iredmail-core container.
#
# Why this exists: the Ubuntu `spamassassin` package ships a frozen ruleset. Left
# unupdated it silently disabled spam filtering entirely — the stock 3.4.6 rules
# query the decommissioned Validity DNSBLs without a return-code filter, and
# those zones now answer EVERY query with 127.255.255.255, handing each message
# CERTIFIED (-3) + SAFE (-2) + RPBL (+1.284) = a standing -3.72. Upstream fixed
# it years ago; we simply never pulled the update.
#
# init.sh also runs sa-update at container start, so this cron only covers the
# gap between restarts (the container typically runs for months).
#
# The ruleset persists across container recreates via the ./data/spamassassin
# bind mount (docker-compose.yml). That is also why sa-update must NOT be baked
# into the image at build time: the bind mount would mask it.
# =============================================================================

set -uo pipefail

CONTAINER="iredmail-core"
SERVICE_DIR="/run/service/amavisd"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) [sa-update] $*"; }

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    log "container ${CONTAINER} is not running — skipping."
    exit 0
fi

docker exec "$CONTAINER" sa-update
rc=$?

case "$rc" in
    1)
        log "ruleset already current — nothing to do."
        exit 0
        ;;
    0)
        log "new ruleset installed."
        ;;
    *)
        log "ERROR: sa-update failed (rc=${rc}); ruleset on disk left untouched."
        exit "$rc"
        ;;
esac

# Amavis parses the ruleset once at startup, so a fresh ruleset only takes
# effect after a restart. Lint FIRST: a ruleset that fails to parse would crash
# amavisd on restart and stall every message in the queue. Staying on the old
# (working) ruleset is strictly better than that.
if ! docker exec "$CONTAINER" spamassassin --lint; then
    log "ERROR: new ruleset fails --lint; NOT restarting amavisd."
    log "       amavis keeps running on the previously loaded ruleset."
    exit 1
fi

# s6 supervises amavisd in foreground mode; SIGTERM makes the supervisor bring
# it straight back up. Postfix queues and retries during the few seconds of
# downtime, so no mail is lost.
if docker exec "$CONTAINER" s6-svc -t "$SERVICE_DIR"; then
    log "amavisd restarted — new ruleset active."
else
    log "WARNING: could not restart amavisd; new rules apply at next restart."
    exit 1
fi
