# MTA-STS + TLS-RPT Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy RFC 8461 (MTA-STS) and RFC 8460 (TLS-RPT) policy publishing for all 4 currently hosted domains in `testing` mode, with full idempotency of `git pull && docker compose up` and zero-touch coverage of future domains via `add-domain.sh`.

**Architecture:** Single source of truth `/var/lib/dkim/*.pem` drives a generated nginx vhost (`mta-sts` server block) serving a static policy file. A shared helper `/usr/local/sbin/regen-mta-sts.sh` is called both at container start (via `init.sh configure_nginx()`) and after each domain add (via `add-domain.sh`) so new domains go live without a container restart. TLS-RPT receiver alias bootstrapped idempotently in `init.sh`.

**Tech Stack:** Bash, nginx, MariaDB (forwardings table), docker compose, certbot --expand, Let's Encrypt HTTP-01.

**Spec:** `docs/superpowers/specs/2026-05-15-mta-sts-rollout-design.md` (rev1, approved).

**Working dir:** `/home/kirby/projects/github/iredadmin/` (laptop). Server commands run via `ssh mail` (production).

**Pre-existing facts** (verified during spec writing, do not re-verify):
- `HOSTNAME=mail.kirby.rocks`, `FIRST_MAIL_DOMAIN=kirby.rocks`
- 4 hosted domains (DKIM pem files present): `chiaruzzi.ch`, `kirby.rocks`, `maisonsoave.ch`, `purfacted.com`
- Cert SANs already include autoconfig/autodiscover for 3 of 4 domains; primary = `mail.kirby.rocks`
- nginx default vhost has `server_name _;` on `:443` — our explicit list will out-prioritize via longest-match
- `forwardings` table: `(address, forwarding, domain, dest_domain, is_alias, is_mailbox, active)`. UNIQUE KEY on `(address, forwarding)` enables `INSERT IGNORE` for idempotency.
- DNS providers: Infomaniak (chiaruzzi.ch), Ionos (kirby.rocks, maisonsoave.ch, purfacted.com). All manual.

---

## Task 0 — Pre-flight: confirm clean repo + server state

Avoid starting a multi-file change against a dirty tree or a server that's mid-restart.

**Files:** none (read-only)

- [ ] **Step 1: Local git tree clean**

```sh
cd /home/kirby/projects/github/iredadmin && git status --short && git rev-parse --abbrev-ref HEAD
```

Expected: empty output, branch `main`.

- [ ] **Step 2: Local in sync with origin**

```sh
git fetch origin && git rev-list --left-right --count origin/main...HEAD
```

Expected: `0\t0`.

- [ ] **Step 3: Server git tree clean and in sync**

```sh
ssh mail 'cd /opt/iredmail && git status -uno --short && git rev-parse HEAD'
```

Expected: empty `git status`. HEAD matches local `git rev-parse HEAD`.

- [ ] **Step 4: Server container healthy**

```sh
ssh mail 'docker ps --filter name=iredmail-core --format "{{.Status}}"'
```

Expected: `Up ... (healthy)`.

If any check fails: STOP, investigate, do not proceed.

---

## Task 1 — Create the static MTA-STS policy file

The file content is identical across all 4 hosted domains (same MX, same mode). Shipped in the image via the existing `COPY rootfs/ /` step in `Dockerfile:236`.

**Files:**
- Create: `rootfs/var/www/mta-sts/.well-known/mta-sts.txt`

- [ ] **Step 1: Create parent directories**

```sh
mkdir -p /home/kirby/projects/github/iredadmin/rootfs/var/www/mta-sts/.well-known
```

- [ ] **Step 2: Write the policy file**

Content of `rootfs/var/www/mta-sts/.well-known/mta-sts.txt`:

```
version: STSv1
mode: testing
mx: mail.kirby.rocks
max_age: 86400
```

Use the Write tool (no trailing whitespace, LF line endings, final newline).

- [ ] **Step 3: Verify contents byte-exactly**

```sh
cat -A /home/kirby/projects/github/iredadmin/rootfs/var/www/mta-sts/.well-known/mta-sts.txt
```

Expected: 4 lines each ending in `$`, file ends with single `$`.

- [ ] **Step 4: Commit (single-file commit for review-friendliness)**

```sh
cd /home/kirby/projects/github/iredadmin
git add rootfs/var/www/mta-sts/.well-known/mta-sts.txt
git commit -m "mta-sts: static policy file (testing mode, 24h max_age)"
```

---

## Task 2 — Create the nginx vhost template

The template has a placeholder `__MTA_STS_SERVER_NAMES__` that `regen-mta-sts.sh` substitutes at runtime. The template itself is committed; the generated file lives only inside the running container.

**Files:**
- Create: `rootfs/etc/nginx/sites-available/mta-sts.tmpl`

- [ ] **Step 1: Write the template**

Content of `rootfs/etc/nginx/sites-available/mta-sts.tmpl`:

```nginx
# =============================================================================
# MTA-STS Policy vhost (auto-generated from /var/lib/dkim/*.pem)
# Source of truth: /usr/local/sbin/regen-mta-sts.sh
# DO NOT edit /etc/nginx/sites-available/mta-sts directly — regenerate.
# =============================================================================

# Redirect HTTP → HTTPS (ACME challenge stays on the default vhost)
server {
    listen 80;
    listen [::]:80;
    server_name __MTA_STS_SERVER_NAMES__;

    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS policy server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name __MTA_STS_SERVER_NAMES__;

    ssl_certificate /etc/letsencrypt/live/HOSTNAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/HOSTNAME/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;

    access_log /var/log/nginx/mta-sts-access.log;
    error_log /var/log/iredmail/mta-sts-error.log;

    root /var/www/mta-sts;
    index index.html;

    location = /.well-known/mta-sts.txt {
        default_type text/plain;
        add_header Cache-Control "public, max-age=3600" always;
    }

    # Everything else 404 — no webmail/iRedAdmin leakage on these hostnames
    location / {
        return 404;
    }
}
```

Notes:
- `HOSTNAME` placeholder is replaced by existing `configure_nginx()` sed at `init.sh:525`. Keep the literal `HOSTNAME` so the existing substitution still works.
- `__MTA_STS_SERVER_NAMES__` is replaced by `regen-mta-sts.sh` (Task 3).

- [ ] **Step 2: Verify file present and readable**

```sh
ls -la /home/kirby/projects/github/iredadmin/rootfs/etc/nginx/sites-available/mta-sts.tmpl
```

Expected: file exists, ~1.5 KB.

- [ ] **Step 3: Commit**

```sh
cd /home/kirby/projects/github/iredadmin
git add rootfs/etc/nginx/sites-available/mta-sts.tmpl
git commit -m "mta-sts: nginx vhost template (HTTPS-only, 404 fallback)"
```

---

## Task 3 — Create the regen-mta-sts.sh helper

Single source of vhost generation, called from both `init.sh` (Task 4) and `add-domain.sh` (Task 6). Idempotent. Handles the zero-domain edge case (fresh bootstrap).

**Files:**
- Create: `rootfs/usr/local/sbin/regen-mta-sts.sh`

- [ ] **Step 1: Create parent directory**

```sh
mkdir -p /home/kirby/projects/github/iredadmin/rootfs/usr/local/sbin
```

- [ ] **Step 2: Write the script**

Content of `rootfs/usr/local/sbin/regen-mta-sts.sh`:

```bash
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
```

- [ ] **Step 3: Set executable bit in git index**

```sh
cd /home/kirby/projects/github/iredadmin
chmod +x rootfs/usr/local/sbin/regen-mta-sts.sh
git update-index --chmod=+x rootfs/usr/local/sbin/regen-mta-sts.sh 2>/dev/null || true
```

- [ ] **Step 4: Syntax check**

```sh
bash -n /home/kirby/projects/github/iredadmin/rootfs/usr/local/sbin/regen-mta-sts.sh && echo "OK"
```

Expected: `OK`.

- [ ] **Step 5: Static test against a sample DKIM dir (no container needed)**

```sh
cd /tmp && mkdir -p mta-sts-test/dkim mta-sts-test/nginx/sites-available mta-sts-test/nginx/sites-enabled
cp /home/kirby/projects/github/iredadmin/rootfs/etc/nginx/sites-available/mta-sts.tmpl mta-sts-test/nginx/sites-available/mta-sts.tmpl
touch mta-sts-test/dkim/{chiaruzzi.ch,kirby.rocks}.pem
DKIM_DIR=$PWD/mta-sts-test/dkim \
TMPL=$PWD/mta-sts-test/nginx/sites-available/mta-sts.tmpl \
OUT=$PWD/mta-sts-test/nginx/sites-available/mta-sts \
LINK=$PWD/mta-sts-test/nginx/sites-enabled/mta-sts \
bash -c 'set -eu; shopt -s nullglob; names=(); for k in "$DKIM_DIR"/*.pem; do dom=$(basename "$k" .pem); names+=("mta-sts.${dom}"); done; sn="${names[*]}"; sed "s|__MTA_STS_SERVER_NAMES__|${sn}|g" "$TMPL" > "$OUT"; ln -sf "$OUT" "$LINK"; cat "$OUT" | grep server_name'
```

Expected: two `server_name mta-sts.chiaruzzi.ch mta-sts.kirby.rocks;` lines (HTTP redirect + HTTPS block).

- [ ] **Step 6: Zero-domain edge-case test**

```sh
rm -f /tmp/mta-sts-test/dkim/*.pem
DKIM_DIR=/tmp/mta-sts-test/dkim \
TMPL=/tmp/mta-sts-test/nginx/sites-available/mta-sts.tmpl \
OUT=/tmp/mta-sts-test/nginx/sites-available/mta-sts \
LINK=/tmp/mta-sts-test/nginx/sites-enabled/mta-sts \
bash /home/kirby/projects/github/iredadmin/rootfs/usr/local/sbin/regen-mta-sts.sh
ls /tmp/mta-sts-test/nginx/sites-enabled/
```

Expected: script prints "no DKIM keys, removing vhost link". `sites-enabled/` is empty. Exit code 0.

- [ ] **Step 7: Cleanup**

```sh
rm -rf /tmp/mta-sts-test
```

- [ ] **Step 8: Commit**

```sh
cd /home/kirby/projects/github/iredadmin
git add rootfs/usr/local/sbin/regen-mta-sts.sh
git commit -m "mta-sts: regen-mta-sts.sh — shared idempotent vhost generator"
```

---

## Task 4 — Wire regen-mta-sts.sh into init.sh configure_nginx()

So every container start regenerates the mta-sts vhost from the current `/var/lib/dkim/*.pem`. Existing `configure_nginx()` is at `rootfs/etc/s6-overlay/scripts/init.sh:508-555`.

**Files:**
- Modify: `rootfs/etc/s6-overlay/scripts/init.sh` (after autoconfig handling block ends, before the custom-conf cp)

- [ ] **Step 1: Read the target region**

```sh
sed -n '540,555p' /home/kirby/projects/github/iredadmin/rootfs/etc/s6-overlay/scripts/init.sh
```

Expected current ending of `configure_nginx`:
```
    # Enable the site
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-enabled/default.dpkg-dist 2>/dev/null || true

    # Apply custom configuration
    if [ -f "/opt/iredmail/custom/nginx/custom.conf" ]; then
```

- [ ] **Step 2: Insert regen call after the `ln -sf default` line**

Use the Edit tool to change:

```
    # Enable the site
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-enabled/default.dpkg-dist 2>/dev/null || true

    # Apply custom configuration
```

to:

```
    # Enable the site
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-enabled/default.dpkg-dist 2>/dev/null || true

    # Regenerate MTA-STS vhost from current DKIM keys (idempotent, zero-domain safe)
    if [ -x /usr/local/sbin/regen-mta-sts.sh ]; then
        /usr/local/sbin/regen-mta-sts.sh
    fi

    # Apply custom configuration
```

- [ ] **Step 3: Bash syntax check**

```sh
bash -n /home/kirby/projects/github/iredadmin/rootfs/etc/s6-overlay/scripts/init.sh && echo "OK"
```

Expected: `OK`.

- [ ] **Step 4: Confirm insertion**

```sh
grep -nA2 'regen-mta-sts.sh' /home/kirby/projects/github/iredadmin/rootfs/etc/s6-overlay/scripts/init.sh
```

Expected: exactly one `if [ -x` block in `configure_nginx`. (After Task 5 a second match in `configure_nginx` is not expected — Task 5 touches a different function.)

- [ ] **Step 5: Commit**

```sh
cd /home/kirby/projects/github/iredadmin
git add rootfs/etc/s6-overlay/scripts/init.sh
git commit -m "init.sh: call regen-mta-sts.sh from configure_nginx"
```

---

## Task 5 — Add bootstrap_tls_rpt_alias() function

Creates `tlsrpt@${FIRST_MAIL_DOMAIN}` → `postmaster@${FIRST_MAIL_DOMAIN}` forwarding via idempotent `INSERT IGNORE`. Called on BOTH init.sh paths: first-time init AND state-file re-run. So if the alias gets deleted by accident later, next container restart re-creates it.

**Files:**
- Modify: `rootfs/etc/s6-overlay/scripts/init.sh`

- [ ] **Step 1: Read the current `create_admin_user` function end + the state-file re-run block**

```sh
sed -n '213,220p;1180,1196p' /home/kirby/projects/github/iredadmin/rootfs/etc/s6-overlay/scripts/init.sh
```

Confirms `create_admin_user` ends at line 215 and the state-file re-run block runs `configure_postfix` … `configure_nginx` at 1188-1191.

- [ ] **Step 2: Insert the new function right after `create_admin_user`**

Use Edit. Find:

```
    echo "Admin user created: ${admin_email}"
}

# =============================================================================
# Generate DKIM Keys
```

Replace with:

```
    echo "Admin user created: ${admin_email}"
}

# =============================================================================
# Bootstrap TLS-RPT receiver alias (RFC 8460)
# =============================================================================
# Creates an idempotent forwarding tlsrpt@${FIRST_MAIL_DOMAIN}
# → postmaster@${FIRST_MAIL_DOMAIN}. INSERT IGNORE + UNIQUE KEY (address,
# forwarding) means re-runs are no-ops. Safe on first-init AND re-run paths.
bootstrap_tls_rpt_alias() {
    local domain="${FIRST_MAIL_DOMAIN}"
    local rpt_addr="tlsrpt@${domain}"
    local dest_addr="postmaster@${domain}"

    echo "Bootstrapping TLS-RPT alias: ${rpt_addr} -> ${dest_addr}"

    mysql -h "${DB_HOST}" -u root -p"${MYSQL_ROOT_PASSWORD}" vmail << EOF 2>/dev/null
INSERT IGNORE INTO alias (address, name, domain, active, created, modified)
VALUES ('${rpt_addr}', 'TLS-RPT receiver', '${domain}', 1, NOW(), NOW());

INSERT IGNORE INTO forwardings
    (address, forwarding, domain, dest_domain, is_alias, is_mailbox, active)
VALUES
    ('${rpt_addr}', '${dest_addr}', '${domain}', '${domain}', 1, 0, 1);
EOF
}

# =============================================================================
# Generate DKIM Keys
```

- [ ] **Step 3: Wire the new function into both init paths**

Find the state-file re-run block (around line 1188-1194):

```
        configure_postfix
        configure_dovecot
        configure_amavis
        configure_nginx
        configure_sogo
        create_iredmail_release
        echo "Configuration updates complete!"
        exit 0
    fi
```

Replace with:

```
        configure_postfix
        configure_dovecot
        configure_amavis
        configure_nginx
        configure_sogo
        bootstrap_tls_rpt_alias
        create_iredmail_release
        echo "Configuration updates complete!"
        exit 0
    fi
```

Then find the first-time-init block (around line 1222-1230):

```
    configure_postfix
    configure_dovecot
    configure_nginx
    configure_clamav
    configure_amavis
    configure_sogo

    # Setup logging
    setup_logging
```

Replace with:

```
    configure_postfix
    configure_dovecot
    configure_nginx
    configure_clamav
    configure_amavis
    configure_sogo

    # TLS-RPT alias (idempotent; safe to call on every start)
    bootstrap_tls_rpt_alias

    # Setup logging
    setup_logging
```

- [ ] **Step 4: Bash syntax check**

```sh
bash -n /home/kirby/projects/github/iredadmin/rootfs/etc/s6-overlay/scripts/init.sh && echo "OK"
```

Expected: `OK`.

- [ ] **Step 5: Verify function defined exactly once + called exactly twice**

```sh
grep -nE '^bootstrap_tls_rpt_alias\(\)|^\s+bootstrap_tls_rpt_alias\s*$' /home/kirby/projects/github/iredadmin/rootfs/etc/s6-overlay/scripts/init.sh
```

Expected: 3 lines — 1 definition + 2 call sites.

- [ ] **Step 6: Commit**

```sh
cd /home/kirby/projects/github/iredadmin
git add rootfs/etc/s6-overlay/scripts/init.sh
git commit -m "init.sh: bootstrap_tls_rpt_alias — idempotent receiver alias"
```

---

## Task 6 — Extend add-domain.sh

Three changes, all in the same idempotent style as the existing `AUTOCONFIG_DOMAIN` block:
1. Add `mta-sts.${NEW_DOMAIN}` to `CERT_EXTRA_DOMAINS`.
2. After DKIM key generation, hot-reload nginx with the new vhost (`docker exec` regen + `nginx -s reload`).
3. Print the 3 MTA-STS DNS records in the "Required DNS records" section.

**Files:**
- Modify: `scripts/add-domain.sh`

- [ ] **Step 1: Add `mta-sts.${NEW_DOMAIN}` block alongside autoconfig/autodiscover**

Find at `scripts/add-domain.sh:168-170`:

```
AUTOCONFIG_DOMAIN="autoconfig.${NEW_DOMAIN}"
AUTODISCOVER_DOMAIN="autodiscover.${NEW_DOMAIN}"
CERT_UPDATED=false
```

Replace with:

```
AUTOCONFIG_DOMAIN="autoconfig.${NEW_DOMAIN}"
AUTODISCOVER_DOMAIN="autodiscover.${NEW_DOMAIN}"
MTA_STS_DOMAIN="mta-sts.${NEW_DOMAIN}"
CERT_UPDATED=false
```

Then find the autodiscover block ending at `scripts/add-domain.sh:199`:

```
# Check if autodiscover domain is already included
if echo "$CURRENT_CERT_DOMAINS" | grep -q "$AUTODISCOVER_DOMAIN"; then
    echo "  [OK] ${AUTODISCOVER_DOMAIN} already in certificate"
else
    echo "  [+] Adding ${AUTODISCOVER_DOMAIN} to certificate domains"
    if [ -z "$CURRENT_CERT_DOMAINS" ]; then
        CURRENT_CERT_DOMAINS="$AUTODISCOVER_DOMAIN"
    else
        CURRENT_CERT_DOMAINS="${CURRENT_CERT_DOMAINS},${AUTODISCOVER_DOMAIN}"
    fi
    CERT_UPDATED=true
fi
```

Replace with:

```
# Check if autodiscover domain is already included
if echo "$CURRENT_CERT_DOMAINS" | grep -q "$AUTODISCOVER_DOMAIN"; then
    echo "  [OK] ${AUTODISCOVER_DOMAIN} already in certificate"
else
    echo "  [+] Adding ${AUTODISCOVER_DOMAIN} to certificate domains"
    if [ -z "$CURRENT_CERT_DOMAINS" ]; then
        CURRENT_CERT_DOMAINS="$AUTODISCOVER_DOMAIN"
    else
        CURRENT_CERT_DOMAINS="${CURRENT_CERT_DOMAINS},${AUTODISCOVER_DOMAIN}"
    fi
    CERT_UPDATED=true
fi

# Check if MTA-STS domain is already included
if echo "$CURRENT_CERT_DOMAINS" | grep -q "$MTA_STS_DOMAIN"; then
    echo "  [OK] ${MTA_STS_DOMAIN} already in certificate"
else
    echo "  [+] Adding ${MTA_STS_DOMAIN} to certificate domains"
    if [ -z "$CURRENT_CERT_DOMAINS" ]; then
        CURRENT_CERT_DOMAINS="$MTA_STS_DOMAIN"
    else
        CURRENT_CERT_DOMAINS="${CURRENT_CERT_DOMAINS},${MTA_STS_DOMAIN}"
    fi
    CERT_UPDATED=true
fi
```

- [ ] **Step 2: Hot-reload nginx after DKIM gen**

Find the DKIM generation block at `scripts/add-domain.sh:150-160`:

```
    # Verify
    DKIM_VERIFY=$(docker exec iredmail-core test -f /var/lib/dkim/${NEW_DOMAIN}.pem && echo "yes" || echo "no")
    if [ "$DKIM_VERIFY" == "yes" ]; then
        echo "  [OK] DKIM key generated"
        CHANGES_MADE=true
    else
        echo "  [ERROR] Failed to generate DKIM key!"
        exit 1
    fi
fi
```

Replace with:

```
    # Verify
    DKIM_VERIFY=$(docker exec iredmail-core test -f /var/lib/dkim/${NEW_DOMAIN}.pem && echo "yes" || echo "no")
    if [ "$DKIM_VERIFY" == "yes" ]; then
        echo "  [OK] DKIM key generated"
        CHANGES_MADE=true
    else
        echo "  [ERROR] Failed to generate DKIM key!"
        exit 1
    fi

    # Hot-regen MTA-STS vhost (adds new mta-sts.${NEW_DOMAIN} server_name)
    # and reload nginx. Skipped silently if regen helper is absent (first-run
    # state where rootfs hasn't been baked in yet).
    if docker exec iredmail-core test -x /usr/local/sbin/regen-mta-sts.sh; then
        echo "  [+] Regenerating MTA-STS vhost and reloading nginx..."
        if docker exec iredmail-core /usr/local/sbin/regen-mta-sts.sh \
            && docker exec iredmail-core nginx -t \
            && docker exec iredmail-core nginx -s reload; then
            echo "  [OK] MTA-STS vhost reloaded"
        else
            echo "  [WARN] MTA-STS vhost regen/reload failed — will retake on next container restart"
        fi
    fi
fi
```

- [ ] **Step 3: Add MTA-STS DNS records to the "Required DNS records" output**

Find at `scripts/add-domain.sh:296-300` (the SRV records block ending):

```
echo "   Type:  SRV"
echo "   Name:  _carddavs._tcp"
echo "   Value: 0 1 443 ${HOSTNAME}"
echo ""
echo "=============================================="
```

Replace with:

```
echo "   Type:  SRV"
echo "   Name:  _carddavs._tcp"
echo "   Value: 0 1 443 ${HOSTNAME}"
echo ""
echo "----------------------------------------------"
echo "6. MTA-STS + TLS-RPT Records (RFC 8461 / 8460)"
echo "----------------------------------------------"
echo "   Type:  CNAME"
echo "   Name:  mta-sts"
echo "   Value: ${HOSTNAME}"
echo ""
echo "   Type:  TXT"
echo "   Name:  _mta-sts"
echo "   Value: \"v=STSv1; id=$(date -u +%Y%m%dT%H%M%SZ);\""
echo ""
echo "   Type:  TXT"
echo "   Name:  _smtp._tls"
echo "   Value: \"v=TLSRPTv1; rua=mailto:tlsrpt@${FIRST_MAIL_DOMAIN}\""
echo ""
echo "=============================================="
```

- [ ] **Step 4: Bash syntax check**

```sh
bash -n /home/kirby/projects/github/iredadmin/scripts/add-domain.sh && echo "OK"
```

Expected: `OK`.

- [ ] **Step 5: Help-text dry-run**

```sh
/home/kirby/projects/github/iredadmin/scripts/add-domain.sh --help
```

Expected: original help output unchanged (no syntax errors surfaced).

- [ ] **Step 6: Commit**

```sh
cd /home/kirby/projects/github/iredadmin
git add scripts/add-domain.sh
git commit -m "add-domain: include mta-sts.* in CERT_EXTRA_DOMAINS + emit MTA-STS DNS records + hot-reload nginx"
```

---

## Task 7 — Local nginx-template sanity test

Verify the substituted vhost is syntactically valid nginx, using the laptop's local nginx (or a docker one-shot if no nginx is installed). Catches typos in `mta-sts.tmpl` before they reach the server.

**Files:** none (test only)

- [ ] **Step 1: Check if nginx is available locally**

```sh
which nginx && nginx -v 2>&1
```

If absent, skip to Step 3 (docker fallback).

- [ ] **Step 2 (local nginx path): Build the substituted file and validate**

```sh
cd /tmp && rm -rf mta-sts-syntax && mkdir mta-sts-syntax && cd mta-sts-syntax
mkdir -p etc/nginx/{sites-available,sites-enabled,conf.d}
mkdir -p etc/letsencrypt/live/mail.kirby.rocks
touch etc/letsencrypt/live/mail.kirby.rocks/{fullchain,privkey}.pem
mkdir -p var/log/nginx var/log/iredmail var/www/mta-sts/.well-known
echo "ok" > var/www/mta-sts/.well-known/mta-sts.txt
cp /home/kirby/projects/github/iredadmin/rootfs/etc/nginx/sites-available/mta-sts.tmpl etc/nginx/sites-available/mta-sts.tmpl
sed -e "s|__MTA_STS_SERVER_NAMES__|mta-sts.chiaruzzi.ch mta-sts.kirby.rocks mta-sts.maisonsoave.ch mta-sts.purfacted.com|g" \
    -e "s|/etc/letsencrypt/live/HOSTNAME/|${PWD}/etc/letsencrypt/live/mail.kirby.rocks/|g" \
    etc/nginx/sites-available/mta-sts.tmpl > etc/nginx/sites-available/mta-sts
ln -sf "${PWD}/etc/nginx/sites-available/mta-sts" etc/nginx/sites-enabled/mta-sts
cat > nginx.conf << 'EOF'
events {}
http {
    server_names_hash_bucket_size 128;
    include /tmp/mta-sts-syntax/etc/nginx/sites-enabled/*;
}
EOF
nginx -t -c "${PWD}/nginx.conf"
```

Expected: `nginx: configuration file ... test is successful`.

- [ ] **Step 3 (docker fallback if no local nginx): Use a nginx one-shot container**

Not applicable on this laptop (no docker installed). Skip with note: validation will repeat on server in Task 11.

- [ ] **Step 4: Cleanup**

```sh
rm -rf /tmp/mta-sts-syntax
```

(No commit — this is a test step.)

---

## Task 8 — Push and pull all repo changes onto the server

All laptop-side code is in. Push and pull, but DO NOT rebuild the container yet (server-side .env update + DNS phase 1 must happen first).

**Files:** none (git only)

- [ ] **Step 1: Push laptop commits to origin**

```sh
cd /home/kirby/projects/github/iredadmin
git push origin main
```

Expected: 5-6 new commits pushed (Tasks 1-6).

- [ ] **Step 2: Pull on server**

```sh
ssh mail 'cd /opt/iredmail && git pull --ff-only origin main 2>&1 | tail -5'
```

Expected: `Fast-forward ...` listing the new files. NO container rebuild yet.

- [ ] **Step 3: Confirm files reached the server**

```sh
ssh mail 'ls -la /opt/iredmail/rootfs/usr/local/sbin/regen-mta-sts.sh /opt/iredmail/rootfs/etc/nginx/sites-available/mta-sts.tmpl /opt/iredmail/rootfs/var/www/mta-sts/.well-known/mta-sts.txt'
```

Expected: all three files exist; `regen-mta-sts.sh` has `x` bit.

---

## Task 9 — DNS Phase 1: add `mta-sts.<dom>` CNAMEs (USER)

Blocking on user. Cert expansion in Task 10 will fail for any domain whose `mta-sts.<dom>` doesn't yet resolve to the server's public IP.

- [ ] **Step 1: Capture the server's public IP for the user**

```sh
ssh mail 'curl -fsS https://api.ipify.org'
```

Note this IP. The CNAME alternative is `mta-sts.<dom> CNAME mail.kirby.rocks` (recommended); a direct A record to the IP also works.

- [ ] **Step 2: User adds 4 CNAMEs**

User adds at their providers (one record per domain):

| Provider | Record |
|---|---|
| Infomaniak (chiaruzzi.ch) | `mta-sts CNAME mail.kirby.rocks` |
| Ionos (kirby.rocks) | `mta-sts CNAME mail.kirby.rocks` |
| Ionos (maisonsoave.ch) | `mta-sts CNAME mail.kirby.rocks` |
| Ionos (purfacted.com) | `mta-sts CNAME mail.kirby.rocks` |

- [ ] **Step 3: Wait for propagation and verify all 4 resolve**

```sh
for d in chiaruzzi.ch kirby.rocks maisonsoave.ch purfacted.com; do
    echo "=== mta-sts.$d ==="
    dig +short A mta-sts.$d @1.1.1.1
done
```

Expected: each returns the server's public IP (possibly after a CNAME indirection). If a domain returns empty, wait 5-10 min and re-check. Do not proceed until all 4 resolve.

---

## Task 10 — Server-side: update CERT_EXTRA_DOMAINS and expand cert

`obtain-cert.sh` is already idempotent and DNS-validates each entry. It will:
1. Read the updated `CERT_EXTRA_DOMAINS` from `.env`
2. Skip any unresolved hostname (shouldn't happen after Task 9)
3. Detect the SAN diff vs the current cert
4. Run `certbot --expand`

**Files:**
- Modify: server-side `/opt/iredmail/.env` (NOT in repo — `.env` is gitignored)

- [ ] **Step 1: Show current `.env` value**

```sh
ssh mail 'grep ^CERT_EXTRA_DOMAINS= /opt/iredmail/.env'
```

Note the current value. Expected: comma-separated list of `autoconfig.<dom>,autodiscover.<dom>` for the 3 non-kirby.rocks domains plus autoconfig/autodiscover for kirby.rocks itself (varies by what's there today).

- [ ] **Step 2: Append the 4 new mta-sts hosts**

```sh
ssh mail 'cd /opt/iredmail && cp .env .env.bak.$(date -u +%Y%m%dT%H%M%SZ) && \
    current=$(grep ^CERT_EXTRA_DOMAINS= .env | cut -d= -f2-) && \
    new="${current},mta-sts.chiaruzzi.ch,mta-sts.kirby.rocks,mta-sts.maisonsoave.ch,mta-sts.purfacted.com" && \
    sed -i "s|^CERT_EXTRA_DOMAINS=.*|CERT_EXTRA_DOMAINS=${new}|" .env && \
    grep ^CERT_EXTRA_DOMAINS= .env'
```

Expected: new line containing the original entries + the 4 mta-sts ones. A `.env.bak.<ts>` is created in case rollback is needed.

- [ ] **Step 3: Run obtain-cert.sh**

```sh
ssh mail 'cd /opt/iredmail && ./scripts/obtain-cert.sh 2>&1 | tail -40'
```

Expected: pre-flight DNS validates all 4 `mta-sts.<dom>` to the server IP, certbot runs with `--expand`, success message + `reload_services` log. Total runtime ~30-60s.

- [ ] **Step 4: Verify new SANs are in the cert**

```sh
ssh mail 'docker exec iredmail-core openssl x509 -in /etc/letsencrypt/live/mail.kirby.rocks/fullchain.pem -noout -ext subjectAltName' | grep -o 'mta-sts\.[^,]*' | sort -u
```

Expected: 4 lines:
```
mta-sts.chiaruzzi.ch
mta-sts.kirby.rocks
mta-sts.maisonsoave.ch
mta-sts.purfacted.com
```

If any are missing, check `obtain-cert.sh` output for which got skipped (DNS issue) and re-run after fixing.

---

## Task 11 — Server rebuild iredmail container

Same workflow as the P1-D deploy (commit `628a0ea`): build, recreate, verify health. New things to verify: mta-sts vhost present, mta-sts.txt served, tlsrpt alias bootstrapped.

**Files:** none

- [ ] **Step 1: Pre-rebuild snapshot**

```sh
ssh mail 'docker exec iredmail-core ls /etc/nginx/sites-enabled/ && echo "---ALIAS PRE---" && docker exec iredmail-db mysql -uroot -p"$(grep ^MYSQL_ROOT_PASSWORD= /opt/iredmail/.env | cut -d= -f2)" vmail -Nse "SELECT address,forwarding FROM forwardings WHERE address LIKE \"tlsrpt@%\";" 2>/dev/null'
```

Expected: sites-enabled contains `default` only. forwardings query returns empty (no tlsrpt yet).

- [ ] **Step 2: Build + recreate**

```sh
ssh mail 'cd /opt/iredmail && docker compose up -d --build iredmail 2>&1 | tail -25'
```

Expected: build succeeds, container recreated, `Container iredmail-core Started`. ~30-60s rebuild.

- [ ] **Step 3: Wait healthy**

```sh
ssh mail 'for i in 1 2 3 4 5 6 7 8 9 10; do sleep 3; s=$(docker inspect iredmail-core --format "{{.State.Health.Status}}"); echo "[$i] $s"; [ "$s" = "healthy" ] && break; done'
```

Expected: healthy within 15-30s.

- [ ] **Step 4: Verify mta-sts vhost exists**

```sh
ssh mail 'docker exec iredmail-core ls -la /etc/nginx/sites-enabled/mta-sts && echo "---SERVER NAMES---" && docker exec iredmail-core grep server_name /etc/nginx/sites-enabled/mta-sts'
```

Expected: file is a symlink to `/etc/nginx/sites-available/mta-sts`. `server_name` lines list 4 `mta-sts.<dom>` entries.

- [ ] **Step 5: Verify policy file is served**

```sh
ssh mail 'for d in chiaruzzi.ch kirby.rocks maisonsoave.ch purfacted.com; do
    echo "=== mta-sts.$d ==="
    curl -fsS "https://mta-sts.$d/.well-known/mta-sts.txt" 2>&1 | head -10
done'
```

Expected for each: 4 lines (`version: STSv1` / `mode: testing` / `mx: mail.kirby.rocks` / `max_age: 86400`).

- [ ] **Step 6: Verify TLS-RPT alias bootstrap**

```sh
ssh mail 'docker exec iredmail-db mysql -uroot -p"$(grep ^MYSQL_ROOT_PASSWORD= /opt/iredmail/.env | cut -d= -f2)" vmail -Nse "SELECT address,forwarding,is_alias,active FROM forwardings WHERE address=\"tlsrpt@kirby.rocks\";"'
```

Expected: one row — `tlsrpt@kirby.rocks  postmaster@kirby.rocks  1  1`.

- [ ] **Step 7: Live e2e test — send mail to tlsrpt@kirby.rocks**

```sh
ssh mail 'docker exec iredmail-core python3 -c "
import smtplib, email.message, time
m = email.message.EmailMessage()
m[\"From\"] = \"postmaster@kirby.rocks\"
m[\"To\"] = \"tlsrpt@kirby.rocks\"
m[\"Subject\"] = \"[mta-sts e2e] alias bootstrap \" + time.strftime(\"%H:%M:%S\")
m.set_content(\"Verifying tlsrpt alias forwards to postmaster\")
s = smtplib.SMTP(\"127.0.0.1\", 25, timeout=10)
s.ehlo(\"mail.kirby.rocks\")
s.send_message(m)
s.quit()
print(\"sent\")
" && sleep 3 && docker exec iredmail-core sh -c "tail -30 /var/log/mail.log" | grep -E "tlsrpt|alias e2e" | tail -5'
```

Expected: `sent`, and the mail.log shows the mail accepted, expanded via the forwarding to `postmaster@kirby.rocks`, and delivered via LMTP `status=sent`.

---

## Task 12 — DNS Phase 2: TXT records (USER)

Once Task 11 is green for all 4 domains, the user adds the 8 TXT records that point senders at the policy and TLS-RPT receiver.

- [ ] **Step 1: User adds 4 × `_mta-sts` TXT records**

For each domain (chiaruzzi.ch, kirby.rocks, maisonsoave.ch, purfacted.com):

| Field | Value |
|---|---|
| Type | TXT |
| Name | `_mta-sts` |
| Value | `"v=STSv1; id=20260515T120000Z;"` |

(The `id` value is arbitrary — must change whenever the policy content changes. Use a single shared timestamp now; bump only when we switch to enforce mode.)

- [ ] **Step 2: User adds 4 × `_smtp._tls` TXT records**

For each domain:

| Field | Value |
|---|---|
| Type | TXT |
| Name | `_smtp._tls` |
| Value | `"v=TLSRPTv1; rua=mailto:tlsrpt@kirby.rocks"` |

- [ ] **Step 3: Verify DNS propagation**

```sh
for d in chiaruzzi.ch kirby.rocks maisonsoave.ch purfacted.com; do
    echo "=== $d ==="
    echo "  _mta-sts:    $(dig +short TXT _mta-sts.$d @1.1.1.1)"
    echo "  _smtp._tls:  $(dig +short TXT _smtp._tls.$d @1.1.1.1)"
done
```

Expected: both TXT values per domain. Wait + re-check if any are empty.

---

## Task 13 — External validation

Confirm the world sees the policy as we intend. Catches anything the internal curl tests missed (e.g. cert chain issues, hostname mismatches).

- [ ] **Step 1: Per-domain MTA-STS validator**

Visit `https://aykevl.nl/apps/mta-sts/` and paste each of the 4 domains in turn. Expected: "Policy parsed: mode=testing, mx=mail.kirby.rocks, max_age=86400". Any error → STOP and debug before moving on.

- [ ] **Step 2: internet.nl mail test**

Visit `https://internet.nl/mail/<dom>/` for each. Expected: MTA-STS section green / passing in testing mode. (TLS-RPT also green if their probe is up.)

- [ ] **Step 3: SAN check via openssl**

```sh
for d in chiaruzzi.ch kirby.rocks maisonsoave.ch purfacted.com; do
    echo "=== mta-sts.$d ==="
    openssl s_client -connect "mta-sts.$d:443" -servername "mta-sts.$d" </dev/null 2>/dev/null \
        | openssl x509 -noout -ext subjectAltName 2>/dev/null \
        | grep -o "mta-sts.$d" || echo "MISSING"
done
```

Expected: each prints its own hostname; no "MISSING".

---

## Task 14 — Add-domain regression test

Verify a future domain add still works end-to-end and picks up MTA-STS automatically. Uses a synthetic 5th domain with no real DNS — `obtain-cert.sh` will correctly skip `mta-sts.test-mta-sts.local`, but `add-domain.sh` and `regen-mta-sts.sh` should complete.

**Files:** none (test only, cleans up after)

- [ ] **Step 1: Run add-domain.sh with the synthetic domain**

```sh
ssh mail 'cd /opt/iredmail && ./scripts/add-domain.sh test-mta-sts.local --yes 2>&1 | tail -80'
```

Expected:
- `[OK] / [+]` lines for domain INSERT, DKIM gen, autoconfig/autodiscover/mta-sts in CERT_EXTRA_DOMAINS
- `[+] Regenerating MTA-STS vhost and reloading nginx... [OK]`
- DNS records section 6 prints the mta-sts CNAME + 2 TXT lines

- [ ] **Step 2: Verify the new server_name landed in nginx**

```sh
ssh mail 'docker exec iredmail-core grep "mta-sts.test-mta-sts.local" /etc/nginx/sites-enabled/mta-sts'
```

Expected: 2 matches (HTTP redirect + HTTPS block).

- [ ] **Step 3: Verify obtain-cert.sh would correctly skip**

```sh
ssh mail 'cd /opt/iredmail && grep ^CERT_EXTRA_DOMAINS= .env | grep "mta-sts.test-mta-sts.local" && echo "in .env: OK"'
```

Expected: `in .env: OK`. (Don't actually run obtain-cert.sh — it would just skip the unresolvable host.)

- [ ] **Step 4: Idempotency test — re-run for the same synthetic domain**

```sh
ssh mail 'cd /opt/iredmail && ./scripts/add-domain.sh test-mta-sts.local --yes 2>&1 | tail -30'
```

Expected: all checks output `[OK]`, no `[+]` lines, no errors. DNS-records section still prints (informational, not state).

- [ ] **Step 5: Cleanup — remove the synthetic domain**

```sh
ssh mail 'cd /opt/iredmail && \
    docker exec iredmail-core rm -f /var/lib/dkim/test-mta-sts.local.pem && \
    docker exec iredmail-db mysql -uroot -p"$(grep ^MYSQL_ROOT_PASSWORD= .env | cut -d= -f2)" vmail -e "DELETE FROM domain WHERE domain=\"test-mta-sts.local\";" && \
    sed -i "s|,mta-sts.test-mta-sts.local||g; s|,autoconfig.test-mta-sts.local||g; s|,autodiscover.test-mta-sts.local||g" .env && \
    docker exec iredmail-core /usr/local/sbin/regen-mta-sts.sh && \
    docker exec iredmail-core nginx -s reload && \
    echo "cleanup OK"'
```

- [ ] **Step 6: Confirm cleanup**

```sh
ssh mail 'docker exec iredmail-core grep -c "test-mta-sts.local" /etc/nginx/sites-enabled/mta-sts; grep -c "test-mta-sts.local" /opt/iredmail/.env'
```

Expected: both `0`.

---

## Task 15 — progress.md update

Document the new live state so the next session has accurate context.

**Files:**
- Modify: `progress.md`

- [ ] **Step 1: Read the current Status section**

```sh
sed -n '1,30p' /home/kirby/projects/github/iredadmin/progress.md
```

- [ ] **Step 2: Add an MTA-STS row to the status table**

Use Edit. Find (the first table row after the heading):

```
## Status — 2026-05-15

| Area | State |
|---|---|
| Postfix hardening | **P1-D live 2026-05-15** (commit `628a0ea`, image rebuilt + container recreated). Port 25 enforces TLSv1.2+, AUTH gated on TLS, HELO mandatory, VRFY off, FQDN sender/recipient checks, 5xx `reject_unauth_destination`. Submission 587 / SMTPS 465 unchanged (already strict via per-service `-o`). policyd-spf intentionally NOT wired (not installed in image; SPF enforced at amavis Mail::SPF). End-to-end smoke test passed: 127.0.0.1:25 → amavis `Passed CLEAN` → LMTP `Saved`. |
```

Replace with:

```
## Status — 2026-05-15

| Area | State |
|---|---|
| MTA-STS + TLS-RPT | **Testing-mode live 2026-05-15** for all 4 domains (chiaruzzi.ch, kirby.rocks, maisonsoave.ch, purfacted.com). Policy `mode: testing, max_age: 86400, mx: mail.kirby.rocks` served from `https://mta-sts.<dom>/.well-known/mta-sts.txt`. TLS-RPT receiver `tlsrpt@kirby.rocks → postmaster@kirby.rocks` bootstrapped via `init.sh`. Cert extended with 4 `mta-sts.*` SANs. nginx vhost auto-regenerated from `/var/lib/dkim/*.pem` via `/usr/local/sbin/regen-mta-sts.sh` (called by init.sh and add-domain.sh). **Switch to enforce mode after 2026-05-29** if TLS-RPT reports are clean — bump `mode: enforce`, `max_age: 604800`, and the `id` field in each `_mta-sts` TXT record. |
| Postfix hardening | **P1-D live 2026-05-15** (commit `628a0ea`, image rebuilt + container recreated). Port 25 enforces TLSv1.2+, AUTH gated on TLS, HELO mandatory, VRFY off, FQDN sender/recipient checks, 5xx `reject_unauth_destination`. Submission 587 / SMTPS 465 unchanged (already strict via per-service `-o`). policyd-spf intentionally NOT wired (not installed in image; SPF enforced at amavis Mail::SPF). End-to-end smoke test passed: 127.0.0.1:25 → amavis `Passed CLEAN` → LMTP `Saved`. |
```

- [ ] **Step 3: Add the enforce-switch reminder to "Open — pick next"**

Find:

```
## Open — pick next

In risk × effort order. Pull from top. **P1-C done in `98c05c6` (Roundcube 1.6.15). P1-D + P1-E deployed + verified 2026-05-15 (`628a0ea`). GH issue #1 closeable.**

1. **P0-3 sudo NOPASSWD** — user job (visudo on server). Procedure:
```

Replace with:

```
## Open — pick next

In risk × effort order. Pull from top. **P1-C done in `98c05c6` (Roundcube 1.6.15). P1-D + P1-E deployed + verified 2026-05-15 (`628a0ea`). MTA-STS + TLS-RPT testing-mode live 2026-05-15. Enforce-switch scheduled for 2026-05-29.**

1. **MTA-STS enforce switch (2026-05-29)** — after 2 weeks observation. Edit `rootfs/var/www/mta-sts/.well-known/mta-sts.txt`: `mode: enforce`, `max_age: 604800`. Bump `id` in all 4 `_mta-sts.<dom>` TXT records (user pflegt im Registrar). Single commit + container rebuild (or just `nginx -s reload` since the file ships via `COPY rootfs/ /` — needs a rebuild to bake into the image).
2. **P0-3 sudo NOPASSWD** — user job (visudo on server). Procedure:
```

Renumber the rest accordingly (P0-3 becomes 2, P3 backlog becomes 3).

- [ ] **Step 4: Commit + push + pull on server**

```sh
cd /home/kirby/projects/github/iredadmin
git add progress.md
git commit -m "progress.md: MTA-STS + TLS-RPT testing-mode live"
git push origin main
ssh mail 'cd /opt/iredmail && git pull --ff-only origin main 2>&1 | tail -3'
```

Expected: fast-forward on server.

---

## Task 16 — Set a calendar reminder for the enforce switch

So we don't forget the 2-week clock. The /schedule skill creates a one-shot remote routine.

- [ ] **Step 1: Schedule a routine for 2026-05-29 09:00 Europe/Zurich**

Use the `/schedule` skill (or invoke the `schedule` Skill tool) to create a `run_once_at`-style routine for 2026-05-29T07:00:00Z (= 09:00 CEST). Prompt should be:

```
Check whether MTA-STS testing-mode has been live for 2 weeks without
trouble. Read progress.md for current state. Then either:
 (a) Inspect tlsrpt@kirby.rocks mailbox via IMAP (or postmaster@kirby.rocks
     since it forwards there) and look at TLS-RPT reports from the past
     2 weeks. If all reports show result=success, open a GH issue titled
     "MTA-STS: switch to enforce mode" with the 4 commands needed:
       1) sed -i 's/mode: testing/mode: enforce/; s/max_age: 86400/max_age: 604800/' rootfs/var/www/mta-sts/.well-known/mta-sts.txt
       2) git commit + push
       3) ssh mail 'cd /opt/iredmail && git pull && docker compose up -d --build iredmail'
       4) User updates _mta-sts TXT id field at registrar for all 4 domains
 (b) If any reports show failure-types, open a GH issue listing the
     observed failures and recommending continued testing-mode until
     they're addressed.

Tools needed: read GitHub repo, no SSH (server-state inferred from
repo + maybe GitHub Actions).
```

Confirm scheduling, note the routine ID.

---

## Self-review checklist

After completing all tasks, verify:

- [ ] **Spec coverage:** every "Files touched" bullet in the spec is implemented by a task. (Specifically: `rootfs/var/www/mta-sts/...` = Task 1; `mta-sts.tmpl` = Task 2; `regen-mta-sts.sh` = Task 3; `init.sh configure_nginx` = Task 4; `init.sh bootstrap_tls_rpt_alias` = Task 5; `add-domain.sh` = Task 6; `progress.md` = Task 15.)
- [ ] **Idempotency contract:** each row of the spec's idempotency table has been live-tested. (Task 14 covers add-domain.sh idempotency + zero-domain edge via Task 3 step 6.)
- [ ] **Rollout sequence:** all 8 steps in the spec map onto Tasks 1-13. (Step 7 "2-week observation" is the calendar reminder Task 16; step 8 "enforce switch" is the future work captured in progress.md.)
- [ ] **No placeholders:** plan has no TBD / TODO / "implement appropriately" / "add validation" gaps.
- [ ] **Type consistency:** `regen-mta-sts.sh` is referenced by the same absolute path (`/usr/local/sbin/regen-mta-sts.sh`) in Task 3, Task 4, and Task 6.
