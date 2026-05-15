# MTA-STS + TLS-RPT rollout

**Status:** rev1 2026-05-15 — design ready for review.
**Scope:** Deploy RFC 8461 (SMTP MTA Strict Transport Security) policy + RFC 8460 (SMTP TLS Reporting) for all 4 currently hosted domains. Initial mode `testing`, migrate to `enforce` after 2 weeks of clean TLS-RPT reports. Existing idempotency + "git pull && docker compose up" property MUST be preserved; `scripts/add-domain.sh` MUST keep working for future domains without manual MTA-STS steps.
**Out of scope:** automatic DNS record provisioning (Ionos has no usable DNS API, Infomaniak has one but it's not worth the complexity for 12 records every few years). DNS records continue to be printed by `add-domain.sh` for manual entry, same as today.

## Why

Currently the mail server enforces TLS opportunistically (`smtpd_tls_security_level = may`). A network-level attacker can downgrade SMTP between two MTAs by stripping `STARTTLS` from the EHLO response. MTA-STS lets a domain publish, via HTTPS, a policy that says "MTAs delivering to me MUST use TLS to one of these MX hosts". TLS-RPT gives the domain owner aggregate reports about TLS failures observed by sending MTAs — useful both for detecting actual attacks and for catching local TLS misconfiguration before it affects deliverability.

Both standards are deployed by ~70% of large providers (Gmail, Outlook, Yahoo enforce). Without them, our 4 hosted domains accept downgrade attacks invisibly today.

## Architecture

**Single source of truth: `/var/lib/dkim/*.pem`** — same pattern amavis already uses for `@local_domains_acl` and `dkim_key()`. Whatever domains have a DKIM key get the full MTA-STS treatment. `add-domain.sh` already generates a DKIM key as part of its idempotent flow, so future domain adds extend MTA-STS automatically.

```
┌──────────────────────┐    ┌────────────────────────────────────┐
│ /var/lib/dkim/*.pem  │───▶│ init.sh configure_mta_sts()        │
│  (DKIM key per dom)  │    │  builds server_name list from glob │
└──────────────────────┘    │  writes nginx vhost mta-sts        │
         │                  └──────────────────────┬─────────────┘
         │                                         │
         │                                         ▼
         │                  ┌──────────────────────────────────┐
         │                  │ /etc/nginx/sites-enabled/mta-sts │
         │                  │  server_name mta-sts.chiaruzzi… │
         │                  │              mta-sts.kirby…     │
         │                  │              mta-sts.maisonsoa… │
         │                  │              mta-sts.purfacted… │
         │                  │  ssl_certificate (shared LE)    │
         │                  │  location = /.well-known/…/.txt │
         │                  │    → /var/www/mta-sts/.well-… │
         │                  └──────────────────────────────────┘
         │
         ▼
┌──────────────────────────────────┐
│ obtain-cert.sh                   │
│  reads CERT_EXTRA_DOMAINS+= 4×   │
│  mta-sts.<domain>, DNS-validates │
│  each, certbot --expand          │
└──────────────────────────────────┘
```

**Container-internal flow:**
1. nginx vhost listens on `:443` with a single `server_name` line containing all `mta-sts.<dom>` hostnames.
2. Cert is the same `mail.kirby.rocks` LE cert, expanded with 4 SANs (`mta-sts.<each-domain>`). Single cert = single renewal.
3. Static policy file `rootfs/var/www/mta-sts/.well-known/mta-sts.txt` is identical for all domains (same MX, same mode). Shipped in the image via `COPY rootfs/ /`.
4. All other paths on the mta-sts hostnames return 404 (no leakage of other webmail or iRedAdmin).

**External flow (per domain):**
- Sender resolves `_mta-sts.<dom>` TXT → finds `v=STSv1; id=<ts>;` → fetches `https://mta-sts.<dom>/.well-known/mta-sts.txt` → caches by `id` for `max_age` seconds.
- Sender resolves `_smtp._tls.<dom>` TXT → finds `v=TLSRPTv1; rua=mailto:tlsrpt@kirby.rocks` → daily aggregate report by email.

**TLS-RPT receiver:** alias `tlsrpt@kirby.rocks` forwarding to `${FIRST_MAIL_DOMAIN_ADMIN}` (postmaster@kirby.rocks). Created by an idempotent bootstrap block in `init.sh` that runs after the admin-create step.

## Files touched

### New files (committed)
- `rootfs/var/www/mta-sts/.well-known/mta-sts.txt` — static policy file (4 lines).
- `rootfs/etc/nginx/sites-available/mta-sts.tmpl` — nginx server block with placeholder `__MTA_STS_SERVER_NAMES__` for substitution at container start.
- `rootfs/usr/local/sbin/regen-mta-sts.sh` — standalone idempotent script. Reads `/var/lib/dkim/*.pem`, substitutes server_names into the template, writes `/etc/nginx/sites-available/mta-sts`, manages the `sites-enabled` symlink. Exits 0 with no-op when DKIM glob is empty. Called by BOTH `init.sh configure_nginx()` (at container start) AND `scripts/add-domain.sh` (via `docker exec` after DKIM gen). Single code path = no drift.

### Modified files
- `rootfs/etc/s6-overlay/scripts/init.sh`
  - `configure_nginx()` gains one line: `/usr/local/sbin/regen-mta-sts.sh` after the existing autoconfig/autodiscover handling.
  - New function `bootstrap_tls_rpt_alias()` called from `setup_first_admin()` after the admin INSERT. Idempotent SQL (see Idempotency contract).
- `scripts/add-domain.sh`
  - Add `mta-sts.${NEW_DOMAIN}` to `CERT_EXTRA_DOMAINS` alongside the existing autoconfig/autodiscover block (same idempotent `grep -q || sed -i` pattern).
  - In the "Required DNS records" output, add a section 6 with `mta-sts CNAME ${HOSTNAME}`, `_mta-sts TXT "v=STSv1; id=${YYYYMMDDTHHMMSSZ}"`, `_smtp._tls TXT "v=TLSRPTv1; rua=mailto:tlsrpt@kirby.rocks"`.
  - After DKIM key generation, run `docker exec iredmail-core /usr/local/sbin/regen-mta-sts.sh && docker exec iredmail-core nginx -t && docker exec iredmail-core nginx -s reload`. New MTA-STS vhost becomes live without container restart.
- `progress.md` — update status table, add "MTA-STS" row.

### No changes needed
- `docker-compose.yml`, `Dockerfile`, `obtain-cert.sh`. The cert script already handles `CERT_EXTRA_DOMAINS` correctly and DNS-validates each entry — skipped if DNS not yet propagated, picked up next run.

## Idempotency contract

| Component | Re-run safe? | Behaviour |
|---|---|---|
| `regen-mta-sts.sh` (called from init.sh and add-domain.sh) | yes | Regenerates vhost from current `/var/lib/dkim/*.pem`. If glob expands empty, removes any existing `sites-enabled/mta-sts` symlink and exits 0. |
| `init.sh bootstrap_tls_rpt_alias()` | yes | `INSERT IGNORE INTO forwardings (address, forwarding, domain, dest_domain, is_alias, active) VALUES ('tlsrpt@${FIRST_MAIL_DOMAIN}', 'postmaster@${FIRST_MAIL_DOMAIN}', ${FIRST_MAIL_DOMAIN}, ${FIRST_MAIL_DOMAIN}, 1, 1)` — UNIQUE KEY (address, forwarding) makes IGNORE the idempotency guarantee. |
| `add-domain.sh` (with patches) | yes | `mta-sts.X in CERT_EXTRA_DOMAINS?` grep before sed; same pattern as today's autoconfig block. |
| `obtain-cert.sh` | yes | Existing behaviour: skips unresolved domains, uses `--expand` only when SAN set changed. |
| `git clone + cp .env.example .env + docker compose up -d --build` on empty server | yes | 0 DKIM keys at first start → no mta-sts vhost generated → no nginx error. `add-domain.sh` for first domain triggers DKIM-gen + nginx-reload → mta-sts vhost appears with that domain. |

## DNS records (printed by add-domain.sh; user enters manually)

Per added domain `<D>`:

```
6. MTA-STS Records
   Type:  CNAME    Name: mta-sts            Value: mail.kirby.rocks
   Type:  TXT      Name: _mta-sts           Value: "v=STSv1; id=20260515T120000Z;"
   Type:  TXT      Name: _smtp._tls         Value: "v=TLSRPTv1; rua=mailto:tlsrpt@kirby.rocks"
```

For the 4 existing domains, I generate one combined Ionos block (3 domains: kirby.rocks, maisonsoave.ch, purfacted.com) and one Infomaniak block (chiaruzzi.ch). User pastes into each provider's DNS UI.

## Rollout sequence

1. **Code commit + push** (laptop): all repo changes above. `mode: testing`, `max_age: 86400`.
2. **DNS Phase 1** (user, all 4 domains): add `mta-sts.<dom>` CNAME → `mail.kirby.rocks`. Wait for propagation (Ionos: ~5-30 min; Infomaniak: similar; `dig mta-sts.<dom>` confirms).
3. **Server-side .env edit + cert expand** (ssh mail): add `mta-sts.<all-four>` to `CERT_EXTRA_DOMAINS`, run `./scripts/obtain-cert.sh`. Verify cert has 4 new SANs.
4. **Container rebuild** (ssh mail): `docker compose up -d --build iredmail`. init.sh sees 4 DKIM keys → generates mta-sts vhost. Verify `curl https://mta-sts.<each-dom>/.well-known/mta-sts.txt` returns the policy.
5. **DNS Phase 2** (user): add 4 × `_mta-sts` TXT + 4 × `_smtp._tls` TXT records. Verify with `dig +short TXT _mta-sts.<dom>`.
6. **External validation:** internet.nl or hardenize.com against each of the 4 domains. Expect "MTA-STS configured (testing)" green.
7. **2-week observation:** TLS-RPT reports trickle in (typically 1/day from Gmail, Outlook). Triage anything other than `result=success`.
8. **Enforce switch** (separate small commit): change `mode: testing` → `mode: enforce`, `max_age: 86400` → `max_age: 604800`, bump `id` in each of the 4 `_mta-sts` TXT records (user updates DNS manually).

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| `mta-sts.<dom>` DNS not propagated → certbot HTTP-01 fails for that SAN | `obtain-cert.sh` already DNS-validates pre-flight + skips unresolved. Other 3 SANs still get added. Re-run after propagation. |
| nginx vhost generation breaks on zero DKIM keys (fresh install) | `configure_mta_sts()` returns early if glob expands to zero matches. Tested with `shopt -s nullglob` semantics. |
| `id` field caching: sender uses stale policy after we change `mode` | RFC requires `id` change to invalidate cache. We document the `id` bump as a mandatory step in the enforce-switch commit. |
| TLS-RPT mailbox missing → mail loops or NDR | Alias bootstrap is idempotent in init.sh. Receiver mailbox is `postmaster@${FIRST_MAIL_DOMAIN}` which is already validated to exist by the existing admin-create flow. |
| Mail downtime during cert expand or container rebuild | Same as P1-D deploy: ~30-60s container restart. Cert expand itself does not restart anything until we explicitly `docker compose up -d --build`. |
| Forgotten future domain leaves MTA-STS gap | `add-domain.sh` integration ensures any new domain gets the full treatment automatically. Verified by the idempotency contract above. |

## Testing

### Pre-deploy (laptop, no server impact)
- `bash -n` syntax check on init.sh + add-domain.sh.
- `nginx -t` against the generated vhost template (substituted with a sample 4-server-name string).

### Post-deploy verification (per domain)
- `curl -fsSL https://mta-sts.<dom>/.well-known/mta-sts.txt` returns 200 + expected policy body.
- `dig +short TXT _mta-sts.<dom>` returns the `v=STSv1; id=…;` line.
- `dig +short TXT _smtp._tls.<dom>` returns the `v=TLSRPTv1; rua=…;` line.
- `openssl s_client -connect mta-sts.<dom>:443 -servername mta-sts.<dom> </dev/null | openssl x509 -noout -ext subjectAltName` shows the SAN.
- External: `https://internet.nl/mail/<dom>/` shows MTA-STS green; `https://aykevl.nl/apps/mta-sts/` policy parser returns 200.

### Idempotency
- Re-run `add-domain.sh` for an existing domain → no changes, all checks output `[OK]`.
- Two consecutive `docker compose up -d --build iredmail` → second one is no-op for mta-sts vhost (file is byte-identical).

### Add-domain regression
- Add a synthetic 5th domain `test-mta-sts.local` (no real DNS): `add-domain.sh` succeeds, prints all 6 record sections including MTA-STS, nginx reloads, but `obtain-cert.sh` correctly skips `mta-sts.test-mta-sts.local`. Remove via DB cleanup.

## Open follow-ups (out of scope, captured for later)

- `mode: enforce` switch with `id` bump — separate commit + DNS update after 2 weeks observation.
- Automatic TLS-RPT report parsing → dashboard or alerts (low value while domain volume is small; revisit if reports get noisy).
- DANE/TLSA records (`_25._tcp.mail.kirby.rocks`) — complementary to MTA-STS but needs DNSSEC, which neither Ionos nor Infomaniak fully support today. Park.
