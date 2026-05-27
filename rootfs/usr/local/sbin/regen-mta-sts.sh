#!/bin/bash
# =============================================================================
# Regenerate the MTA-STS nginx vhost from the current set of DKIM keys.
# Idempotent: writing the same content twice produces byte-identical output.
# Zero DKIM keys → remove any prior vhost link and exit 0 (fresh bootstrap).
# Called by:
#   - init.sh configure_nginx()  (every container start)
#   - scripts/add-domain.sh      (after DKIM key generation, hot path)
# =============================================================================

set -eu

DKIM_DIR="/var/lib/dkim"
TMPL="/etc/nginx/sites-available/mta-sts.tmpl"
OUT="/etc/nginx/sites-available/mta-sts"
LINK="/etc/nginx/sites-enabled/mta-sts"

# Collect mta-sts.<dom> for every DKIM key file. Bash 4+ nullglob avoids
# the literal "*.pem" pattern leaking through when the dir is empty.
shopt -s nullglob
names=()
for keyfile in "$DKIM_DIR"/*.pem; do
    dom=$(basename "$keyfile" .pem)
    names+=("mta-sts.${dom}")
done

if [ "${#names[@]}" -eq 0 ]; then
    echo "regen-mta-sts: no DKIM keys, removing vhost link if present"
    rm -f "$LINK" "$OUT"
    exit 0
fi

if [ ! -f "$TMPL" ]; then
    echo "regen-mta-sts: template missing at $TMPL — abort" >&2
    exit 1
fi

server_names="${names[*]}"

# Substitute and write atomically (write tmp, rename) so a partial write
# can never be picked up by an nginx reload mid-flight.
tmpfile=$(mktemp "${OUT}.XXXXXX")
sed "s|__MTA_STS_SERVER_NAMES__|${server_names}|g" "$TMPL" > "$tmpfile"
chmod 644 "$tmpfile"
mv "$tmpfile" "$OUT"

ln -sf "$OUT" "$LINK"

echo "regen-mta-sts: vhost regenerated for ${#names[@]} domain(s): ${server_names}"
