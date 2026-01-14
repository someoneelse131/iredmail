#!/bin/bash
# Certificate reload watcher
# Checks for certificate changes every 6 hours and reloads services

CERT_FILE="/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem"
LAST_HASH=""

echo "Watching certificate: $CERT_FILE"

while true; do
    sleep 21600  # 6 hours

    if [ -f "$CERT_FILE" ]; then
        CURRENT_HASH=$(md5sum "$CERT_FILE" 2>/dev/null | cut -d" " -f1)

        if [ -n "$LAST_HASH" ] && [ "$CURRENT_HASH" != "$LAST_HASH" ]; then
            echo "Certificate changed, reloading services..."
            nginx -s reload 2>/dev/null || true
            postfix reload 2>/dev/null || true
            doveadm reload 2>/dev/null || true
            echo "Services reloaded with new certificate."
        fi

        LAST_HASH="$CURRENT_HASH"
    fi
done
