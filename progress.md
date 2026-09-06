# iRedMail server — progress

Active log. Pre-2026-05-01 history is in `progress-archive.md` (562-line incident timeline + 4-agent audit findings + full P3 backlog).

## Status — 2026-05-26

| Area | State |
|---|---|
| MTA-STS + TLS-RPT | **Testing-mode live 2026-06-17** for all 4 domains (chiaruzzi.ch, kirby.rocks, maisonsoave.ch, purfacted.com). Policy `mode: testing, max_age: 86400, mx: mail.kirby.rocks` served from `https://mta-sts.<dom>/.well-known/mta-sts.txt` (valid cert, 11-SAN incl. 4 `mta-sts.*`, expires 2026-09-15). `_mta-sts` + `_smtp._tls` TXT live in all 4 zones; TLS-RPT receiver `tlsrpt@kirby.rocks → postmaster@kirby.rocks` (init.sh bootstrap, e2e-verified). nginx vhost auto-regenerated from `/var/lib/dkim/*.pem` via `/usr/local/sbin/regen-mta-sts.sh` (called by init.sh + add-domain.sh; add-domain regression-tested + cleaned up 2026-06-17). **ACME gotcha fixed (`67fbb4d`):** the port-80 vhost redirect caught `/.well-known/acme-challenge/` → cert issuance for `mta-sts.*` failed; added a `^~` acme location served from the webroot before the redirect. **Switch to enforce after ~2026-07-01** if TLS-RPT reports clean: bump `mode: enforce`, `max_age: 604800`, and the `id` in each `_mta-sts` TXT (file ships via `COPY rootfs/ /` → needs a rebuild to bake in). |
| Postfix hardening | **P1-D live 2026-05-15** (commit `628a0ea`, image rebuilt + container recreated). Port 25 enforces TLSv1.2+, AUTH gated on TLS, HELO mandatory, VRFY off, FQDN sender/recipient checks, 5xx `reject_unauth_destination`. Submission 587 / SMTPS 465 unchanged (already strict via per-service `-o`). policyd-spf intentionally NOT wired (not installed in image; SPF enforced at amavis Mail::SPF). End-to-end smoke test passed: 127.0.0.1:25 → amavis `Passed CLEAN` → LMTP `Saved`. |
| Mounts | **P1-E live 2026-05-15** (same commit). `./data/ssl:/etc/letsencrypt:ro` on iredmail container; certbot container keeps rw on line 133 for renewal. DKIM stays rw because `scripts/add-domain.sh:146` writes new `.pem` via `docker exec`. Verified via `docker inspect`. |
| Mail persistence | Storage-path bug fixed 2026-04-29. Container recreate no longer loses data. 1083+ msgs restored from TB cache, all subfolders subscribed. |
| Backup — local | Borg 4h, encrypted (`repokey-blake2`), dedup ~250×, repo ~140 MB at `/opt/iredmail/data/borg-repo`. Cron `15 */4 * * *` verified firing. Old `backup.sh` daily 02:00 still running as safety net (retire ~2026-05-13). **2026-05-26 (`6d041df`):** `borg create/prune/compact` wrapped in `run_borg()` helper so `rc=1` (warning, e.g. "file changed while we backed it up") is treated as success. Without it, transient warnings on `data/amavis-spamassassin/bayes_toks` killed the script via `set -e`, skipped the rclone offsite step, and flapped both Healthchecks DOWN/UP every few cycles. Also: `data/amavis-spamassassin/` excluded from archives — Bayes is regenerable, SDBM hashdbs are unsafe to copy live. Verified post-fix: clean borg run, `[Offsite] OK` fired, 3 amavis paths gone from new archive vs prior (dir + `bayes_toks` + `bayes_seen`). |
| Backup — alerting | Two independent Healthchecks.io checks. Local borg: `HEALTHCHECKS_URL=…/140a8ccf-…` (existed). Offsite: `HEALTHCHECKS_OFFSITE_URL=…/5e26d866-…` (added 2026-05-02). Each gets `/start` + success + `/fail` pings, so a silent HiDrive outage alerts independently from a successful local borg. **Gotcha (2026-05-02):** Schedule-Time-Zone auf hc.io muss `Europe/Zurich` sein (nicht `UTC`), sonst feuert die Cron-Expression `15 */4 * * *` 2h verschoben gegen die Server-CEST-Pings → konstante 30min-Grace-DOWN-Alerts. Beide Checks auf `Europe/Zurich` gesetzt. |
| Backup — offsite | **ACTIVE** (C6 done 2026-05-01, paths reorganised + alerting dedicated 2026-05-02). rclone WebDAV → Ionos HiDrive 100 GB (1.36 €/mo). Sub-user `hidrive-kirby-backup`, locked to `/backup/` (HiDrive returns 403 on writes outside it — verified). Layout: `hidrive:/backup/iredmail/data/` (borg repo) + `hidrive:/backup/iredmail/.trash/<ts>/` (versioned trash from `--backup-dir`). Mirrors after every borg run. `--backup-dir` keeps replaced/deleted segments → ransomware-from-server can't wipe history. Restore: `rclone copy hidrive:/backup/iredmail/data /opt/iredmail/data/borg-repo`. |
| Borg key | In 1Password + paper. Server `/root/borg-key-export.txt` shredded 2026-05-01. |
| SA ruleset | **FIXED 2026-08-07 (`239a81b`)** — spam scoring was dead: 723 `Passed CLEAN` vs 2 `Passed SPAM`. Root cause was NOT Bayes/sieve, it was the ruleset. Ubuntu's `spamassassin` 3.4.6 queries the decommissioned Validity (ex-Return Path/Habeas) DNSBLs via `check_rbl_txt()` with no return-code filter; those zones now answer EVERY query with `A 127.255.255.255` + TXT `"Excessive Number of Queries"` (verified: even `127.0.0.1` and `8.8.8.8` "hit" the certification whitelist). Standing effect per message: `CERTIFIED -3.0` + `SAFE -2.0` + `RPBL +1.284` = **−3.716 floor on everything**, vs `tag2=5.0`. Upstream fixed it long ago (return-code filter `'^127\.0\.0\.'` + dedicated `*_BLOCKED` rules scored 0); we never pulled it because **`sa-update` had never run** (`/var/lib/spamassassin` was empty). Fix: `init.sh` now runs `sa-update` at container start (non-fatal, rc=1 = "already current" ≠ failure) + `scripts/sa-update.sh` weekly cron (restarts amavisd only when the ruleset changed AND passes `--lint`) + static safety net `rootfs/etc/spamassassin/99_local_overrides.cf` scoring the 3 Validity rules 0. **Gotcha:** must be runtime, NOT a Dockerfile `RUN` — `docker-compose.yml:83` bind-mounts `./data/spamassassin` over `/var/lib/spamassassin` and would mask anything baked into the image (same mount is why the ruleset now survives recreates). Verified: real spam re-scored **−1.046 → 5.2 `Yes`**; GTUBE e2e `Passed SPAM` Hits 999.001 → filed to Junk, not INBOX. |
| Spam stack | amavis 10024 (inbound) + 10025 (re-injection) + 10026 (ORIGINATING, signs DKIM outbound). SA scoring `tag2=5.0 kill=9.0`, `D_PASS`. ClamAV runs — **signature updates via the `freshclam` s6 service since 2026-08-07**; before that nothing updated them and they sat 7 months stale (see "Spam-Stack-Sanierung" below). Sieve `before.d/spam-to-junk.sieve` files `X-Spam-Flag:YES` → Junk. **Bayes-learning (P1-B Phase 2) live 2026-05-04:** Dovecot imap_sieve fires on user IMAP COPY/MOVE/APPEND in/out of Junk → `sa-learn-pipe.sh` wrapper (PATH-pinned, mode-whitelist, sudo-gated to `vmail→amavis`) → `sa-learn`. Bayes DB persisted via bind mount `data/amavis-spamassassin/` (was in writable layer pre-migration → wiped on rebuild). Roundcube `markasjunk` plugin enabled (IMAP-move only, `learning_driver=null` so the sieve is the single training path). Host cron `*/15 * * * *` runs `sa-learn --sync` to flush journal. DKIM signing for all 4 domains; verifier.port25.com confirms `dkim=pass spf=pass iprev=pass` for kirby.rocks (final domain verified 2026-05-01 16:50 after DNS update). |
| fail2ban (container) | **6 jails active** (recidive added 2026-05-02): dovecot (`findtime=3600 maxretry=3` for distributed brute-force), postfix-sasl (8500+ bans), roundcube-auth, sogo-auth, iredadmin, recidive (`bantime=1w findtime=1d maxretry=3`, `iptables-allports` on DOCKER-USER, watches own `fail2ban.log`). **Brute-force surface fully closed.** Note: `F2B_LOG_TARGET=/var/log/fail2ban/fail2ban.log` and persistent volume `data/fail2ban-logs` are required prerequisites — if either is missing the recidive jail aborts container startup with "Have not found any log file". On fresh deploys: `mkdir -p data/fail2ban-logs && touch data/fail2ban-logs/fail2ban.log` before first `docker compose up`. |
| fail2ban (host) | sshd jail. 1428+ bans. |
| SSH | Password auth disabled (cloud-init drop-in renamed to `.disabled`). |
| Permissions | `.env` 600. `data/backup/*.tar.gz` 600. All `privkey*.pem` 600. UID alignment vmail 2000:2000 host↔container. |
| TLS | Cert valid until 2026-07-19, ECDSA, certbot renewal cron OK. |

## Deployments — 2026-06-17 (component version bumps)

All built + recreated on `mail` via repo→pull→`docker compose build iredmail`→`up -d iredmail`. Container `healthy` after each, all core ports listening (25/143/443/465/587/993 + 7777 iRedAPD + 11211 memcached). Rollback image tags kept on server: `iredmail-custom:{pre-2.8.1,pre-iredapd61,pre-rc1616}`.

- **iRedAdmin 2.7 → 2.8.1** (`bac922d` + `3497063`). 2.8 security fix (password hash accepted as plaintext) + `crypt`→`passlib`. **Gotcha:** 2.8 needs the `passlib` pip package, which wasn't in our pip block → bumping the version alone gave **502** on `/iredadmin/login` (uWSGI app crash). Fixed by adding `'passlib'` to the `pip3 install` block (`3497063`). Verified: login page 200, `iredpwd` round-trip OK for SSHA512 + SSHA (our schemes). fail2ban sed-patch on `controllers/sql/basic.py` still applies cleanly (target lines 8 + 74 unchanged in 2.8.1).
- **iRedAPD 5.6.0 → 6.1** (`98711a5`). 6.0 adds SQLAlchemy 1.4+2.0 support; SPF/notify fixes. No new mandatory deps for the daemon (`multipart` only used by the upgrade tool we don't run; web.py is embedded). Verified: `__version__=6.1`, daemon listening on `127.0.0.1:7777`, test policy request → `action=DUNNO` (correct pass-through incl. DB lookup).
- **Roundcube 1.6.15 → 1.6.16** (`890b5bd`). Security batch (pre-auth SQLi in `virtuser_query`, stored XSS, SSRF/remote-image bypasses, pre-auth file-delete, LDAP code-injection). Same 1.6 LTS line, drop-in (no DB schema change). Verified: `RCMAIL_VERSION=1.6.16`, `/mail/` 200, error log clean. Stayed on 1.6 LTS — **not** 1.7.x (feature series; container PHP is 8.1.2).
- **Dropped dead `IREDMAIL_VERSION` ARG** (`1017d86`). Was never referenced in the build — purely nominal. iRedMail "core" components (postfix/dovecot/amavis/clamav) come from Ubuntu `apt`, not a versioned iRedMail package, so there is no "core 1.8.x" to install here.
- **Deploy gotcha:** `git pull` on `/opt/iredmail` died once on root-owned `.git/objects` (leftover from a past root git op). Fixed via `sudo chown -R masteradmin:masteradmin /opt/iredmail/.git` (passwordless sudo works on `mail`). `.git` metadata only — not the data tree.
- Also deployed in passing (was committed `67fbb4d` between bumps): MTA-STS vhost now serves ACME http-01 on port 80 instead of redirecting to HTTPS.
- Cleanup: removed stale `iredmail-buildtest:latest` image (1.5 GB) from `mail`.

## Open — pick next

In risk × effort order. Pull from top. **P1-C done in `98c05c6` (Roundcube 1.6.15). P1-D + P1-E deployed + verified 2026-05-15 (`628a0ea`). GH issue #1 closeable. MTA-STS + TLS-RPT testing-mode live 2026-06-17 (Tasks 0-15 done) — only the enforce switch remains.**

1. **MTA-STS enforce switch (~2026-07-01)** — after ~2 weeks of clean TLS-RPT reports at `tlsrpt@kirby.rocks`. Edit `rootfs/var/www/mta-sts/.well-known/mta-sts.txt`: `mode: enforce`, `max_age: 604800`. Bump the `id` in all 4 `_mta-sts.<dom>` TXT records (user pflegt im Registrar: Infomaniak chiaruzzi.ch, Ionos for the other 3). Single commit + container rebuild (file ships via `COPY rootfs/ /`, so a rebuild is needed to bake it into the image). Plan ref: `docs/superpowers/plans/2026-05-15-mta-sts-rollout.md` Task 16.
2. **Gruppe A — HSTS + H5 healthcheck + BCRYPT (NEXT SESSION, low risk, one rebuild).** All three are repo-code, deployable in a single `docker compose build iredmail && up -d iredmail` (~30-40s mail blip on recreate, like the component bumps). Turnkey, paths verified 2026-06-17:
   - **HSTS** → `rootfs/etc/nginx/sites-available/default`, 443 server block (next to the existing `add_header … always;` lines ~40-43). Add `add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;`. **Durable** — init.sh only `sed`s HOSTNAME (line 549), does NOT regenerate this file. Optional same-pass: drop the deprecated `X-XSS-Protection` header (line 42).
   - **H5 real mailflow healthcheck** → `rootfs/usr/local/bin/health-check.sh` (currently only process/port checks: postfix status, doveadm who, nginx -t, pgrep php-fpm, nc 25/143/443, mysql SELECT 1). Add a final stage: `doveadm save` a tiny test mail → assert it lands under `/var/vmail/vmail1/…` → expunge. **Caveat:** healthcheck fires every ~30s — keep the probe cheap and ALWAYS clean up the test mail, or it pollutes a mailbox / floods logs. Consider gating it to run only every Nth invocation.
   - **BCRYPT** → **NOT a static overlay** — `settings.py` is generated by init.sh (`create_iredadmin_settings()`, heredoc at `rootfs/etc/s6-overlay/scripts/init.sh:905`). Add `default_password_scheme = 'BCRYPT'` inside that heredoc. **Caveats:** (a) existing hashes stay SSHA512/SSHA, only new/changed passwords become BCRYPT (fine, mixed schemes coexist); (b) verify Dovecot has `BLF-CRYPT` in its password schemes before deploy, else auth for BCRYPT'd users breaks — check `doveadm pw -l` in the container.
3. **Gruppe B — container hardening (NEXT SESSION, MEDIUM risk, same rebuild, TEST AFTER RECREATE).** `docker-compose.yml` iredmail-core service (cap_add at line ~93). Add `security_opt: ["no-new-privileges:true"]` and review `cap_drop`. **Real risk flagged:** `no-new-privileges` blocks setuid/setgid escalation — iRedMail's postfix ships setgid `postdrop`/`maildrop`; local sendmail submission could break (inbound SMTP likely unaffected). The container is supervisor-as-root (s6), so full `cap_drop: [ALL]` + minimal re-add is fragile (postfix/dovecot/clamav need CHOWN/SETUID/SETGID/DAC_OVERRIDE/KILL). Minimum viable = just `no-new-privileges:true`, then smoke-test e2e (inbound :25 → INBOX, webmail send, SOGo) before declaring done. Keep a rollback image tag.
4. **P3 backlog (remainder)** — see `progress-archive.md` "P3" sections. Highlights: SOGo memcached broken (floods sogo.log) DONE 2026-06-15, H1 amavis bind-mount (DONE 2026-05-04 as part of P1-B Phase 2), ~~H2 docker log driver + `live-restore`~~ + ~~H3 logrotate iRedMail logs~~ (both done 2026-06-17, see "Host config / logrotate" below), ~~H6/H7 borg-backup.sh resilience patches~~ (H7 done 2026-05-26 via `run_borg` wrapper + amavis-spamassassin exclude), ~~kernel reboot pending~~ (N/A — server already runs latest installed kernel `6.8.0-124`, no `reboot-required` flag, only 3 trivial pending updates as of 2026-06-17). (H5 healthcheck, HSTS, BCRYPT, container `no-new-privileges`/caps promoted to items 2-3 above. MTA-STS + TLS-RPT promoted to item 1 above.)

## Roundcube-Versand repariert 2026-08-25 — abgeschlossen

Gemeldet als "SOGo, SMTP error, Authentication failed" beim Senden als
`contact@maisonsoave.ch`. Es war **nicht SOGo, sondern Roundcube.**

**Ursache.** `create_roundcube_config()` erzeugte `$config['smtp_host'] = 'localhost:25'`.
Auf Port 25 wirbt Postfix AUTH erst nach STARTTLS (`smtpd_tls_auth_only = yes`,
`smtpd_tls_security_level = may`), und Roundcube schickt bei einem Host ohne
Schema kein STARTTLS. Es sieht deshalb gar keine AUTH-Fähigkeit und bricht ab,
**bevor ein Passwort das Kabel sieht**. Genau deshalb stand im `maillog` keine
einzige fehlgeschlagene Anmeldung: der Versuch kam nie bis zur Prüfung, und die
Suche nach dem Fehler an der falschen Stelle (Konto, Passwort, fail2ban) wäre
ergebnislos geblieben.

**Regression, nicht Ursprungszustand.** `smtpd_tls_auth_only = yes` kam am
2026-05-15 mit `628a0ea` ("P1-D Postfix hardening") dazu und legte Roundcube
**und** SOGo gleichzeitig lahm. Am 2026-06-09 hat `e0870b9` SOGo auf
`smtps://${HOSTNAME}:465` umgestellt, **Roundcube wurde dabei übersehen**.
Zeitachse aus den Logs: letzter erfolgreicher Roundcube-Versand 2026-03-13
(`sendmail.log`), erster `SMTP server does not support authentication`
2026-06-15 (`errors.log`), also beim ersten Sendeversuch nach dem Hardening.

**Fix.** `$config['smtp_host'] = 'ssl://${HOSTNAME}:465';` an zwei Stellen:
- `config/roundcube/config.inc.php` — das Custom-Include wird am Ende des
  generierten Config eingebunden, gewinnt also und wirkt **sofort ohne Rebuild
  und ohne Neustart** (Bind-Mount, PHP liest bei jedem Aufruf).
- `rootfs/etc/s6-overlay/scripts/init.sh` — damit ein Neuaufbau nicht wieder
  kaputt geboren wird. **Wirkt erst nach `docker compose build` + `up -d`**, bis
  dahin trägt allein das Custom-Include den Fix. Solange gilt "Repo == server"
  für `init.sh` nicht mehr, siehe "What's SOLID".

**Hostname muss `${HOSTNAME}` sein, nicht `localhost`.** PHP prüft bei `ssl://`
per Default den Namen im Zertifikat (`verify_peer`/`verify_peer_name`), dessen
CN ist `mail.kirby.rocks`. Im Container löst der Name auf die eigene
Container-IP auf, die Verbindung verlässt den Host also nicht. Gleiche
Begründung wie bei `SOGoSMTPServer`.

**Gemessen, EHLO je Weg:** Port 25 ohne STARTTLS wirbt **kein** AUTH; Port 25
nach STARTTLS, 587 nach STARTTLS und 465 direkt werben `AUTH PLAIN`. Die
Fähigkeitsliste ohne AUTH ist Zeichen für Zeichen die, die Roundcube in
`errors.log` protokolliert hatte.

**Verifiziert, Ende zu Ende** (20:58 Uhr, echter Versand durch den Anwender):
`postfix/smtps/smtpd: sasl_method=plain, sasl_username=contact@maisonsoave.ch`
→ amavis `Passed CLEAN {RelayedOutbound}, ORIGINATING`, `dkim_new=dkim:maisonsoave.ch`
→ `relay=mail.dormiente.com[91.132.146.119]:25, status=sent (250 2.0.0 Ok)`.
Der Empfängerserver hat die Nachricht angenommen, nicht nur die eigene Queue.

**Nebenbefunde, nicht behoben, kein Handlungsdruck:**
- `sendmail.log` hat den erfolgreichen Versand **nicht** protokolliert
  (letzter Eintrag weiter 2026-03-13), obwohl `smtp_log` in 1.6 per Default an
  ist. Kosmetisch, der Versand selbst steht im `maillog`.
- Der `roundcube-auth`-Jail zählt diese Fehlerklasse nicht mit (0 Treffer bei 5
  Fehlschlägen). Sein Filter greift nur IMAP-Login-Fehler. Hier war das ein
  Glück, sonst hätte sich der Anwender beim Wiederholen selbst ausgesperrt.
- Auf `dev` gibt es keinen Ersatz-Sendeweg, SOGo bleibt der einzige zweite.
  SOGos Strecke ist geprüft (Zertifikat gültig, `250-AUTH PLAIN`), aber in den
  vierzehn Tagen Log steht **kein einziger echter Versand über SOGo**. Der Weg
  ist gemessen, nicht im Betrieb belegt.

## Spam landet endlich im Junk 2026-09-06 — abgeschlossen

Gemeldet als "Spam wird richtig erkannt, landet aber nicht im Spam-Ordner, und
nicht als gelesen". Die Meldung stimmte im Ergebnis, aber nicht in der Ursache.

**Was NICHT kaputt war.** Die Sieve-Kette. `before.d/spam-to-junk.sieve` hat
jede Mail mit `X-Spam-Flag: YES` korrekt nach Junk gelegt und dabei `\Seen`
gesetzt, nachweisbar in `/var/log/iredmail/dovecot.log` (**nicht** in
`maillog`, `info_log_path` zeigt woanders hin — genau daran scheitert die
Suche zuerst, weil `grep "stored mail into mailbox"` im maillog nichts findet).

**Ursache 1: Bayes war seit der Installation wirkungslos.** SpamAssassin
verlangt per Default `bayes_min_spam_num`/`bayes_min_ham_num` = 200, bevor die
BAYES_*-Regeln überhaupt punkten. Die DB stand bei nspam=36 / nham=194, also
vier Monate unter der Schwelle. Ohne Bayes fehlten den Mails genau die Punkte,
die den **Inhalt** bewerten: dieselbe Kampagne kam auf 8.1 wenn Spamhaus die
sendende IP schon kannte, und auf 3.9 wenn nicht. Bei einem Tag-Level von 5.0
blieb die zweite Hälfte im Posteingang liegen.

**Ursache 2: was der Anwender sah, war Thunderbird, nicht der Server.** Die 8
Mails im Posteingang trugen alle `X-Spam-Flag: NO` (Scores 0.874 bis 4.432),
aber das IMAP-Keyword `Junk`. `dovecot-keywords` enthält
`NonJunk / Junk / $Junk / $Filtered`, die TB-Signatur. TBs eigener Filter hat
markiert, ohne zu verschieben, weil "Move new junk messages to" im Konto nicht
gesetzt war. **Merke: eine Junk-Markierung in TB ohne Verschieben trainiert den
Server nicht** — `imapsieve_mailbox1_causes = COPY APPEND` hängt am
Junk-Ordner, ein Keyword auf INBOX ist ein FLAG-Event und trifft keine Regel.

**Ursache 3, beim Testen gefunden, potenziell schlimmer als die Meldung.**
10 von 12 Postfächern hatten **gar keinen Junk-Ordner**. `15-mailboxes.conf`
definiert `mailbox Junk` nur mit `special_use`, ohne `auto`, und
`lda_mailbox_autocreate` steht auf no. Ohne Zielordner läuft `fileinto "Junk"`
ins Leere, Sieve fällt auf implicit keep zurück, und der Spam landet **ohne
eine einzige Fehlermeldung** im Posteingang. Betraf u. a. acc@maisonsoave.ch
und postmaster@kirby.rocks.

**Behoben (`ba613ef`, `41f0cc0`, deployt mit dem Rebuild 2026-09-06 17:43):**
- Einmaliges Bulk-Training über den Bestand: 76 Spam (Junk + Posteingang von
  contact@), 343 Ham (die handsortierten `INBOX.*`-Ordner, **kein** Trash,
  **kein** Sent). Ergebnis nspam=112 / nham=536. Bayes-DB vorher gesichert nach
  `data/backup/bayes/bayes_{toks,seen}.20260906-165312`.
- `bayes_min_*` auf 100 in `rootfs/etc/spamassassin/99_local_overrides.cf`.
  Nicht tiefer: unter rund hundert Stichproben je Klasse wird die
  Tokenstatistik unzuverlässig.
- `auto = subscribe` für `mailbox Junk` in `config/dovecot/custom.conf`. Der
  benannte `namespace inbox`-Block wird von Dovecot mit dem aus
  15-mailboxes.conf **zusammengeführt**, nicht überschrieben, mit `doveconf -n`
  gegengeprüft (Drafts, Sent, "Sent Messages", Trash unverändert).
- 90-Tage-Junk-Cleanup in `scripts/backup-cron`. Durch lazy_expunge wandern die
  Mails erst nach `.EXPUNGED`, echte Aufbewahrung also 90 + 30 Tage.

**Abgenommen.** Eine Mail, die vorher 3.873 erreichte, kommt jetzt auf 5.2
(BAYES_99 +3.5, BAYES_999 +0.2). Gegenrichtung mit 34 echten Mails aus 17
handsortierten Ordnern geprüft: durchweg BAYES_00, Bereich −4.2 bis +0.3, kein
Fehlalarm. Ende-zu-Ende nach dem Rebuild mit einer GTUBE-Mail an
**acc@maisonsoave.ch**, dem Postfach ohne Junk-Ordner: amavis `Passed SPAM`
999.998, Betreff `[SPAM] …`, gelandet in Junk mit `\Seen`, INBOX unverändert
bei 37. Ausfall beim Container-Tausch **22 Sekunden** (17:43:35 bis 17:43:57).

**Offen, nicht dringend:**
- `/var/lib/amavis/virusmails` und `/var/lib/amavis/db` sind **nicht gemountet**
  und verlieren bei jedem Recreate ihren Inhalt (Quarantäne-Kopien, interne
  Zähler-DBs). Gleiche Fehlerklasse wie der Storage-Vorfall vom 2026-04-28,
  aber ohne Verlust echter Nutzerpost. Nachziehen, falls die Quarantäne je für
  Auswertungen gebraucht wird.
- Der Anwender muss in Thunderbird "Junk verschieben nach" und "als gelesen
  markieren" setzen, sonst bleibt die clientseitige Markierung wirkungslos und
  trainiert weiterhin nichts.
- `warning: not owned by root: /var/spool/postfix/etc` bei jedem Postfix-Start.
  Kosmetisch, im persistenten `maillog` bis mindestens 2026-08-27 zurück
  belegt, also **keine** Regression des Rebuilds.

## Spam-Stack-Sanierung 2026-08-07 — abgeschlossen

Ausgelöst durch "Spam landet nicht in Junk" bei `contact@maisonsoave.ch`. Drei sich überlagernde Defekte, alle behoben und verifiziert. Commits `239a81b`, `26a7d40`, `f78c028`, `f12e4a6`.

**1. Validity-DNSBLs = −3.72 auf jeder Mail (Hauptursache).** Siehe Zeile "SA ruleset" oben. Behoben via `sa-update` zur Laufzeit + statischem Safety-Net.

**2. `URIBL_BLOCKED` auf jeder Mail.** Der Host nutzte die geteilten IONOS-Resolver (`212.227.123.16/17`), URIBL weist geteilte Resolver ab: `"Query Refused ... [Your DNS IP: 212.227.222.195]"`. Damit waren sämtliche URI-Blocklisten tot, ausgerechnet das stärkste Signal gegen den Link-Spam, den dieser Server tatsächlich bekommt.
- Fix: **`unbound` auf dem Host**, volle Rekursion (**keine Forwarder** — Forwarding auf Quad9/Cloudflare/Google würde das Problem nur mit anderem Upstream reproduzieren), loopback-only, DNSSEC-validierend. `systemd-resolved` zeigt per Drop-in darauf.
- **`Domains=~.` ist tragend, keine Deko:** netplan fährt den Link per DHCP, ens6 trägt also weiter die Provider-Resolver, und Link-DNS schlägt normalerweise globales DNS. Erst der globale Catch-all-Routing-Domain zieht alle Queries auf unbound.
- **Kein Fallback auf die Provider-Resolver, bewusst.** Ein Fallback hielte die Mail am Laufen, wenn unbound stirbt, aber um den Preis einer stillen Rückkehr auf einen geteilten Resolver, das Spamfilter würde also wieder leise degradieren. Genau diese Klasse Fehler hat hier Monate gebraucht, bis sie auffiel. unbound läuft als `Restart=on-failure`, boot-enabled.
- **NICHT über `dns:` in `docker-compose.yml`:** der Core-Container löst `db` über Dockers embedded DNS (127.0.0.11) auf, ein Override bricht die DB-Verbindung. Über den Host-Resolver wirkt es automatisch (`ExtServers: [host(127.0.0.53)]`).
- Verifiziert: URIBL-Testpunkt `127.0.0.14` + TXT `"permanent testpoint"` vom Host **und** aus dem Container; `getent hosts db` weiter ok; MX-Lookups NOERROR für alle 4 eigenen Domains plus 15 Grossanbieter (DNSSEC bricht nichts); Mailfluss weiter `Passed CLEAN`. Drei echte Spams neu bewertet, `URIBL_BLOCKED` weg: **−1.046 → 5.2**, **−1.149 → 6.3**, **2.307 → 11.6**, alle jetzt `Yes`.
- **Canary:** taucht `URIBL_BLOCKED` wieder im `X-Spam-Status` auf, ist die Resolver-Konfiguration zurückgefallen. Header prüfen, nicht die Config.

**3. ClamAV-Signaturen wurden nie aktualisiert.** Es gab **gar keinen** freshclam-Dienst. Das clamav-Run-Skript lädt Signaturen nur, wenn die DB komplett fehlt (`[ ! -f main.cvd ]`), das ist ein Bootstrap, kein Update-Pfad. Die Signaturen standen seit dem ersten Image-Build (2026-01-18, DB 27884), also 7 Monate. Fatal wurde es, als der Rebuild für `239a81b` per apt **ClamAV 1.4.4 → 1.5.3** hob: 1.5.3 lehnt CVDs ohne detached `.sign`-Datei ab (`Can't verify database integrity`), clamd ist crash-geloopt.
- Fix: neuer s6-Longrun-Dienst `freshclam` (`freshclam -d`, stündlich per `Checks 24`), plus `EnableReloadCommand true` in `clamd.conf` (Ubuntu liefert `false`), damit neue Signaturen ohne clamd-Neustart aktiv werden. Verifiziert: `RELOAD` → clamd antwortet `RELOADING` und liest die DBs neu.
- **Zwei Fallstricke beim Deploy aufgetaucht** (in `f12e4a6` behoben):
  - `init.sh` hat **zwei Pfade**: Erst-Init fährt den vollen `configure_*`-Satz, ein bereits initialisierter Container (`STATE_FILE` vorhanden, Zeile ~1274) nur einen **reduzierten** — und `configure_clamav` fehlte darin. Das sed für `EnableReloadCommand` lief deshalb bei keinem normalen Neustart. Generell: neue Konfigurationsschritte **in beide Zweige** eintragen.
  - Das alte `while pgrep -x freshclam` im clamav-Run-Skript war unbegrenzt und hätte mit einem Dauer-Daemon clamd bei jedem Neustart **für immer** blockiert. Ersetzt durch einen echten Bootstrap-Check (nur warten, wenn gar keine DB da ist, max. 300 s). Ausserdem prüft er jetzt `main.cvd` **oder** `main.cld` — freshclam wandelt `.cvd` nach einem inkrementellen Update in `.cld` um, die alte Prüfung hätte danach immer wieder alles neu geladen.

**Bayes zurückgesetzt.** Vorher `nspam=17, nham=1285`: inert (SA braucht **200** Spam **und** 200 Ham) und vergiftet, weil der −3.72-Boden den Spam unter die Autolearn-Ham-Schwelle (0.1) drückte und er automatisch als Ham gelernt wurde. 0 von 6 gespeicherten Mails hatte je eine `BAYES_*`-Regel. `sa-learn --clear`, Backup unter `data/amavis-spamassassin.bak-20260807`. Die 22 Junk-Mails per `doveadm move` (umgeht `imap_sieve`, sonst hätte Regel 2 sie als **Ham** angelernt — verifiziert: kein einziger `sa-learn-pipe`-Aufruf dabei) zurück in die INBOX, Keywords `$Junk`/`Junk`/`NonJunk` entfernt. **Erwartung: 22 Mails bringen Bayes nicht über die 200er-Schwelle**, das läuft sich über Wochen ein. Schwelle absenken wäre möglich, bei dünnem Korpus aber fehleranfällig — erst mal laufen lassen, das Scoring trägt jetzt selbst.

**Aufräumen.** Docker auf `mail`: Build-Cache 74 → 7 GB, Images 11 → 5 (Fremd-Images `joplin/server`, `postgres:15`, `certbot:latest` entfernt; Rollback-Tags aus Juni weg, `iredmail-custom:pre-saupdate` von heute bleibt), verwaiste Volumes 64 → 1. **Disk 91 G → 21 G (20 % → 5 %).**

## Host config / logrotate — staged 2026-06-17 (H2 + H3)

State-check found Gruppe C ("daemon.json + logrotate + kernel reboot") was far less disruptive than the stale 2026-04-29 archive notes implied:
- **Kernel reboot: N/A.** Running `6.8.0-124` (= newest installed), no `/var/run/reboot-required`, only 3 cached pending apt updates, none in the docker/libc/kernel security set. The old "6.8.0-90 running, 58 updates" note is obsolete.
- **H2 daemon.json: low-value but staged.** Docker's per-container json logs are tiny (444K/136K/88K/24K) — no runaway. So NO disruptive `systemctl restart docker` window is justified; the file is just installed dormant and its `log-opts` (50m×5) apply at the next `docker compose up -d` recreate we do anyway; `live-restore` at the next docker restart.
- **H3 logrotate: genuinely needed.** `maillog` was 202M, `dovecot.log` 55M, `nginx-error.log` 49M — never rotated. The archive's "maillog double-line bug" is gone (tail shows clean single lines).

Versioned host files added to repo at `host/etc/docker/daemon.json` + `host/etc/logrotate.d/iredmail` (these live on the HOST, not in the container image / `rootfs/`). DR install steps documented in `README-DISASTER-RECOVERY.md` → "Host-level config".

**INSTALLED + VERIFIED on server 2026-06-17** (via `ssh mail`, non-disruptive — no container restart, no reboot):
- `/etc/logrotate.d/iredmail` installed; `logrotate -d` parsed clean; forced first rotation reclaimed ~306M (`maillog` 202M→0, `dovecot.log` 55M→0, `nginx-error.log` 49M→0, data preserved in `.1`). **copytruncate verified safe with iRedMail's rsyslog**: after truncate, a port-25 probe produced fresh `maillog` lines, `du`≈`ls` (750 B / 4K) → NOT sparse, rsyslog resumed at offset 0 cleanly. Daily rotation auto-runs from now.
- `/etc/docker/daemon.json` installed; `dockerd --validate` → `configuration OK`. `log-opts` (50m×5) apply at next container recreate; `live-restore` at next docker restart. No restart forced (json logs were tiny: 444K/136K/88K/24K — nothing to reclaim).
- apt: `ca-certificates` + `libjcat1` upgraded (security/dep), `fwupd` held back by phased-update (irrelevant on a VPS). No reboot-required. Old kernel `6.8.0-90` retained intentionally as Ubuntu fallback.
- Note: `masteradmin` is in the `docker` group on `mail`, so `docker`/`docker compose` run without sudo there (only `/etc` writes + `apt` need sudo).

## P1-B residual user tests — ALL DONE 2026-05-04

These needed a real IMAP client (Roundcube + Thunderbird) — `doveadm move` bypasses `imap_sieve` per Pigeonhole docs, so they couldn't be automated.

**Bug found + fixed during verification 2026-05-04:** spec rev4 + plan + 5 reviewers all let `imapsieve_mailboxN_causes = COPY MOVE APPEND` slip through. `MOVE` is NOT a valid Pigeonhole event cause (only APPEND/COPY/FLAG are). Dovecot logged `Warning: imapsieve: Static mailbox rule [N] has invalid event cause 'MOVE' (skipped)` on every IMAP login and silently skipped both rules — i.e. the feature looked installed but trained nothing. Fixed in commit `ba7624d` (`COPY MOVE APPEND` → `COPY APPEND`, `COPY MOVE` → `COPY`); IMAP MOVE is COPY+EXPUNGE under the hood so `COPY` already catches drag-and-drop.

- [x] **Step 3+4 — Spam-learn (TB drag, equivalent to RC "Mark as junk"):** verified 21:30 with a synthetic test mail to contact@maisonsoave.ch, dragged INBOX→Junk in TB. `sa-learn-pipe: trained mode=spam` logged once; `nspam 0→1`, `ntokens +84`.
- [x] **Step 5 — Ham-learn (drag back):** verified 21:38 by dragging the same synthetic mail Junk→INBOX. `sa-learn-pipe: trained mode=ham` logged twice in 0.6s (TB's IDLE/sync re-fires the COPY hook; harmless — sa-learn is idempotent for same-direction repeats and re-classifies for opposite). Counter delta: `nspam 1→0` (auto-unlearn-on-reclass), `nham 15→18`.
- [x] **Step 6 — Re-classification:** spec misconception. sa-learn does NOT refuse opposite-direction re-train; it re-classifies (unlearn old direction, learn new). Observed inline in Step 5 (`nspam 1→0`). What sa-learn DOES refuse is repeat-training the SAME direction ("Skipped already-learned"). No bug, just a doc detail.
- [x] **Real-spam train 2026-05-04 22:04:** user manually cycled the actual DHL phishing mail (originally moved into Junk during the bug window — was not trained then) Junk→INBOX→Junk. `mode=ham` × 2 then `mode=spam` × 1 logged. Counters now `nspam=1, nham=20, ntokens=5909` — phishing mail correctly classified as spam, +121 real-spam tokens in the bayes db.
- [ ] **Step 9 — Pipe size DoS guard runtime:** static check passes (sieve has `if size :over 10M { stop; }`, sievec compiled clean). Programmatic test would need a real IMAP APPEND >10 MB into Junk. Low priority — skip.

## P1-D values — concrete diff for `init.sh` postfix gen block

- `smtpd_tls_auth_only = yes`           (eliminates cleartext AUTH on 25)
- `smtpd_tls_protocols = >=TLSv1.2`
- `smtpd_tls_mandatory_protocols = >=TLSv1.2`
- `smtp_tls_protocols = >=TLSv1.2`        (outbound)
- `smtp_tls_mandatory_protocols = >=TLSv1.2`
- `smtpd_tls_ciphers = high`
- `smtpd_tls_mandatory_ciphers = high`
- `tls_preempt_cipherlist = yes`
- `smtpd_tls_eecdh_grade = ultra`
- `smtpd_helo_required = yes`
- `disable_vrfy_command = yes`
- `smtpd_helo_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname`
- `smtpd_sender_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_non_fqdn_sender, reject_unknown_sender_domain`
- `smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_non_fqdn_recipient, reject_unknown_recipient_domain, reject_unauth_destination, check_policy_service unix:private/policyd-spf`
- `smtpd_data_restrictions = reject_unauth_pipelining`
- `smtpd_relay_restrictions`: switch final action `defer_unauth_destination` → `reject_unauth_destination` (5xx instead of 4xx)
- `smtpd_sasl_authenticated_header = yes`
- `smtpd_tls_received_header = yes`
- `smtpd_tls_loglevel = 1`, `smtp_tls_loglevel = 1`

## What's SOLID — DON'T re-investigate

- Storage-path fix durable: inodes identical host↔container, `init.sh` regenerates correct paths from scratch on every container start, all 10 DB rows consistent (`storagebasedirectory='/var/vmail', storagenode='vmail1'`).
- Borg pipeline: `borg check --repository-only` clean, atomic `.tmp` rename for DB dump, restore-drill bit-identical.
- Repo == server: `sha256sum init.sh + docker-compose.yml` identical.
  **Ausnahme seit 2026-08-25:** `init.sh` trägt den Roundcube-`smtp_host`-Fix,
  das laufende Image noch nicht. Gilt bis zum nächsten
  `docker compose build iredmail && up -d iredmail`. Der Fix wirkt derweil
  über `config/roundcube/config.inc.php`, siehe Abschnitt oben.
- Open-relay closed (`smtpd_relay_restrictions` correct).
- Docker socket NOT mounted into any container.
- AppArmor enforcing (`docker-default`).
- E2E tested via python smtplib → :25:
  - clean (score 3.5) → INBOX, `X-Spam-Flag: NO`
  - GTUBE (score 1003) → Junk via sieve, `[SPAM]` subject prefix
  - EICAR → `Blocked INFECTED (Eicar-Signature) {DiscardedInbound,Quarantined}`
  - inbound DKIM verify works (real simplelogin.co mail came with `dkim_sd=`).
- Verifier.port25.com confirms outbound: `kirby.rocks dkim=pass spf=pass iprev=pass header.d=kirby.rocks`. (Other 3 domains verified earlier in same session.)
- iRedAdmin fail2ban jail (closed 2026-05-02): SQL backend's `controllers/sql/basic.py` patched in Dockerfile to emit `logger.warning` (LDAP backend already does), rsyslog routes facility `local5` → `/var/log/iredmail/iredadmin.log`, fail2ban filter+jail bind-mounted RO. End-to-end verified: 6 fail-POSTs → ban triggered, iptables `f2b-iredadmin` chain in DOCKER-USER, unban clean. Persistent across container rebuild (Dockerfile sed has `grep -q` + `py_compile` guards that fail the build if upstream renames the patched lines). Independently re-verified by 2 agents.
- recidive jail (closed 2026-05-02): docker-compose `F2B_LOG_TARGET` → `/var/log/fail2ban/fail2ban.log` + persistent volume `data/fail2ban-logs`, jail watches own log with `bantime=1w findtime=1d maxretry=3` and `iptables-allports[chain=DOCKER-USER]`. End-to-end verified: 3 manual bans for TEST-NET IP `198.51.100.99` from iredadmin/postfix-sasl/dovecot triggered the recidive ban exactly at the 3rd hit (`NOTICE [recidive] Ban 198.51.100.99` in fail2ban.log), unbanned clean across all 4 jails.
- **Bayes-learning live (P1-B Phase 2 done 2026-05-04):**
  - 8 commits a3d57ff…8b89c5e (Dockerfile sudo + visudo build-gate, sudoers `vmail→amavis spam|ham only`, `sa-learn-pipe.sh` wrapper, two `imap_sieve` sieves, dovecot conf merge, `init.sh` bayes-bootstrap + sievec loop, compose bind mount `data/amavis-spamassassin`, Roundcube `markasjunk` plugin). Each implemented + reviewed (spec + quality) by isolated subagents.
  - Server migration ~38s mailflow downtime: pre-built image while old container running, then stop → `docker cp` Bayes DB to host bind mount (uid 111:115, dir 0700, files 0600) → `docker compose up -d` (no `--build`) → all ports 25/143/10024/10025/10026 live.
  - Verification matrix 10/11 PASS (programmatic 1, 2, 7, 8, 10, 11 + user-UI 3, 4, 5, 6 via TB drag — see "P1-B residual user tests"). Step 9 (pipe size DoS) static-PASS only (sieve has `if size :over 10M { stop; }`, sievec compiled clean; runtime test would need IMAP APPEND >10 MB, low value).
  - Bug caught + fixed inline (commit `ba7624d`): `imapsieve_mailbox*_causes` listed `MOVE` which is not a valid Pigeonhole event cause — dovecot logged `Warning: imapsieve: Static mailbox rule [N] has invalid event cause 'MOVE' (skipped)` and silently skipped both rules. IMAP MOVE is COPY+EXPUNGE under the hood, so `COPY` already catches drag-and-drop. Lesson saved to memory `feedback_imap_sieve_no_move_cause.md`.
  - Real-spam train confirmed: user dragged actual DHL-phishing mail Junk→INBOX→Junk; `nspam=1, nham=20, ntokens=5909` after sync (684 unique journal entries flushed).
  - Host cron `*/15 * * * *` (`/etc/cron.d/sa-learn-sync`) flushes Bayes journal via `docker exec --user amavis sa-learn --sync`. Manual one-shot returned OK.
  - Pre-migration baseline `/tmp/bayes-pre.txt` (laptop) + `/tmp/iredmail-pre-spamlearn-snapshot/` (server) preserve the 5 originals (Dockerfile, docker-compose.yml, 91-iredmail-sieve.conf, init.sh, roundcube/config.inc.php) for rollback. Delete after ~24h of stable usage:
    - `ssh mail 'sudo rm -rf /tmp/iredmail-pre-spamlearn-snapshot'`
    - laptop: `rm -f /tmp/bayes-pre.txt`

## How to resume

1. Read this file. For pre-2026-05-01 history (incident timeline, audit details, full P3 list) → `progress-archive.md`.
2. State-check (expect **6 jails**, amavis ports listening, Bayes bind-mount populated, sa-learn cron present):
   ```
   ssh mail 'sudo docker exec iredmail-fail2ban fail2ban-client status; \
     sudo docker exec iredmail-core ss -ltn | grep -E "10024|10025|10026"; \
     sudo ls -la /opt/iredmail/data/amavis-spamassassin/; \
     sudo cat /etc/cron.d/sa-learn-sync; \
     sudo docker exec --user amavis iredmail-core sa-learn --dump magic | grep -E "nspam|nham|ntokens"; \
     sudo grep -E "^HEALTHCHECKS" /opt/iredmail/.env'
   ```
3. **Rollback artefacts** (delete if state-check above is clean and no spam-learning regressions reported):
   - `ssh mail 'sudo rm -rf /tmp/iredmail-pre-spamlearn-snapshot'`
   - laptop: `rm -f /tmp/bayes-pre.txt`
4. **Server `/opt/iredmail/` git tree** still months out-of-sync with `origin/main`. Files are now even more divergent after the 2026-05-04 deploy (we scp'd 9 files in directly per Task 10 plan + the `ba7624d` hot-fix). `git pull` on server would conflict heavily. Reconcile via either: (a) `cd /opt/iredmail && sudo git fetch && sudo git reset --hard origin/main` once we trust the deploy is stable, or (b) keep the deploy-via-scp pattern and never touch git on the server. See todo.md "Cleanup ideas".
5. **hc.io schedule TZ** (carry-over): verify after a few 4h cron cycles that no DOWN alerts repeat. Was wrong UTC → set to Europe/Zurich 2026-05-02.
6. Pick from "Open — pick next" — top is **MTA-STS + TLS-RPT rollout** (spec `936ea95`, plan `1b75b15`; both committed, execute via subagent-driven-development).

## Open questions

See `todo.md`.
