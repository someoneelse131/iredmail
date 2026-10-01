# TODO

Open work items. Pull from `progress.md` "Open / pending order" first; this file is for ideas, questions, and lower-priority cleanup.

## Geplant, wartet auf ein Wartungsfenster

### Dovecot: Client-Kennung und Verschiebe-Aktionen mitloggen (eingetragen 2026-10-01)

**Warum:** Ein Lieferanten-Mail von dormiente.com an contact@maisonsoave.ch (Message-ID
`c1937b3d80c246f1ac380f6bb6d038d5@dormiente.com`) kam am 2026-09-15 09:34 an, war serverseitig
klar Ham (Score -1.889, `BAYES_00`, `X-Spam-Flag: NO`) und wurde trotzdem **ungelesen** von
irgendeinem Client aus der INBOX nach Junk verschoben (Keywords `Junk $Junk $Classified`).
Der Anwender hat es am 2026-09-27 09:55:17 nach `INBOX.Suppliers.Dormient` zurückgezogen,
das wurde korrekt als Ham gelernt. **Welcher Client verschoben hat, ist nicht mehr
feststellbar**: Dovecot loggt weder die IMAP-ID des Clients noch Verschiebungen, die Logs
rotieren nach rund 14 Tagen, und `data/logs` ist vom Borg-Backup ausgenommen. Das
Thunderbird auf dem Laptop war es nachweislich **nicht** (`moveOnSpam` nie gesetzt).
Verdacht: die Mail-App am Handy (Logins über Swisscom Mobile 178.197.x). Ein zweites Mail
mit derselben Signatur liegt in Junk (2026-09-10 19:10, „Mühelose Reinigungswerkzeuge“,
dort zu Recht).

Rekonstruiert wurde der Weg über die Maildateien in den täglichen Borg-Archiven:
`doveadm fetch guid` liefert den Maildir-Dateinamen, der lässt sich pro Archiv suchen,
und die Kopien unter `Maildir/.EXPUNGED/<Ordner>` (lazy_expunge) zeigen, woher ein Mail
mit welchen Flags weggeschoben wurde.

**Was zu tun ist**, in `config/dovecot/custom.conf`:

```
imap_id_log = name version os os-version vendor
# Verschiebungen protokollieren; notify + mail_log an die bestehende Zeile anhaengen:
protocol imap {
  mail_plugins = $mail_plugins lazy_expunge notify mail_log
}
plugin {
  mail_log_events = copy expunge mailbox_delete mailbox_rename flag_change
  mail_log_fields = uid box msgid from subject flags
}
```

Danach landen in `dovecot.log` Zeilen wie `ID sent: name=…` beim Login und
`copy from INBOX: box=Junk, msgid=…` beim Verschieben.

**Vorgehen und Vorsicht:**
- Kein Rebuild nötig, `custom.conf` ist bind-gemountet und wird von `configure_dovecot`
  in beiden init.sh-Zweigen kopiert. Es braucht aber einen **Neustart des Containers**
  (`docker compose restart iredmail-core`, rund 20 s Ausfall). **Erst wenn der Anwender
  ein Wartungsfenster freigibt**, am 2026-10-01 ausdrücklich zurückgestellt, weil der
  Mailserver gerade nicht ausfallen darf.
- Vorher prüfen: `doveadm config -n | grep mail_plugins` im laufenden Container, damit
  `imap_sieve` in der imap-Zeile erhalten bleibt (steht in `91-iredmail-sieve.conf`,
  `$mail_plugins` muss es mitnehmen). Danach `dovecot.log` auf Fehler prüfen, insbesondere
  `invalid event cause` (siehe Spam-Lernen) und einen Test-Move nach Junk und zurück
  machen: `sa-learn-pipe: trained mode=spam` und `mode=ham` müssen weiter im `maillog`
  erscheinen.
- `flag_change` erzeugt viel Text. Falls `dovecot.log` zu stark wächst, auf
  `copy expunge` beschränken.
- Optional im selben Zug: `maillog` und `dovecot.log` länger aufbewahren oder ins Borg
  aufnehmen, damit solche Fragen nicht an der 14-Tage-Rotation scheitern.

**Offen beim Anwender:** welche Mail-App am Handy für contact@ läuft. Falls sie einen
eigenen Junk-Filter hat, dort ausschalten. Der Server sortiert Spam selbst.

**Schon erledigt am 2026-10-01 (lokal, nicht am Server):** In
`~/.thunderbird/96kspmx7.default-esr/user.js` ist für contact@ (`mail.server.server5`)
der adaptive Junk-Filter aus (`spamLevel 0`, `moveOnSpam false`, `purgeSpam false`).
Erklärt: „Nicht Junk“ heisst, das Mail aus Junk herausziehen, egal mit welchem Client
(SOGo empfohlen). Der Thunderbird-Button „Kein Junk“ allein trainiert serverseitig nichts.

## Open questions

### Q: New server — is `.env` enough to be ready-to-rock?

**Short answer: no.** The `.env` carries every secret the stack needs to *boot* (DB passwords, BORG_PASSPHRASE, MLMMJADMIN token, ROUNDCUBE_DES_KEY, FIRST_MAIL_DOMAIN_ADMIN_PASSWORD, optional HEALTHCHECKS_URL), but a working mail server also needs persistent state that is NOT inside `.env`:

| Lives where | What | Where to recover from |
|---|---|---|
| `.env` | secrets, hostname, primary domain | password manager / paper |
| Borg repo `data/borg-repo/` | vmail, DKIM keys, TLS certs, DB dump, sogo, dovecot indexes, amavis state, .env itself | offsite mirror (C6 — pending) |
| DNS | MX, A, PTR, SPF, DKIM TXT, DMARC | registrar (1&1 / Cloudflare) |
| Borg key+passphrase | BORG_KEY block (in repo + offsite copy) + passphrase (in `.env` + 1Password + paper) | 1Password + paper |

**Restore flow** (already documented in `README-DISASTER-RECOVERY.md`):
1. Fresh VPS + Docker + git + borg.
2. `git clone` repo, `rsync` borg repo into `data/borg-repo/`.
3. `borg extract :: opt/iredmail/.env` — recover `.env` from latest archive.
4. `setup.sh` (idempotent — won't re-init existing repo).
5. `docker compose build && docker compose up -d`.
6. `scripts/restore-borg.sh` — interactive, mode 3 = full restore.
7. DNS: update A/PTR for new IP. MX/DKIM/SPF/DMARC stay (they reference hostname, not IP).
8. Verify mailflow, take a fresh borg backup.

**Documentation gap to close** (own item, low priority): README-DR doesn't currently call out which secrets live in `.env` vs. which live in the borg repo. The "You need" section at the top mostly says "the borg passphrase". Add a one-paragraph explainer that .env recoverable from inside the borg archive (chicken-and-egg-resolved by step 3 above) — paper copy of `.env` is overkill given the passphrase + repo copy is what's actually load-bearing.

### Q: Do we need a paper copy of `.env`?

Probably not. The full `.env` is included in every borg archive, so anyone with the passphrase + repo can extract it. The single thing that genuinely needs a non-disk copy is `BORG_PASSPHRASE` itself — without it nothing decrypts. That one is in 1Password + paper. The BORG_KEY block (`borg key export`) is now ALSO in 1Password + paper as of 2026-05-01 (server-side `/root/borg-key-export.txt` was shredded same day).

## Cleanup ideas (not blocking)

- **P1-B Phase 2 future-tightening (deferred from spec rev4):**
  - Re-enable amavis `auto_learn = yes` later, once we have ≥200 user-trained spam + ≥200 user-trained ham messages. The whole point of user-driven training is to avoid feedback loops; with enough manual signal we can layer auto-learn on top to compound the rate.
  - Add a healthcheck cron that pages if `nspam : nham` ratio drifts >10:1 in either direction (signal of a stuck training source). e.g. `*/30 * * * * root /opt/iredmail/scripts/sa-learn-ratio-check.sh` — write the script.
  - ~~README-DISASTER-RECOVERY.md should mention `data/amavis-spamassassin/` as a restorable bind mount~~ — superseded 2026-05-26: the directory is now EXCLUDED from Borg (Bayes is regenerable, SDBM hashdbs not crash-consistent to copy live). DR README updated to spell out that `init.sh` bayes-bootstrap recreates the dir on first start and Bayes rebuilds from re-training.
- Retire `scripts/backup.sh` 2026-05-13 (after 2 weeks of borg stability). Or shorten retention to 7d.
- `restore-borg.sh:135` hardcoded 9-dir list → replace with deny-list iteration over actual borg archive contents (so new data dirs are restored automatically).
- `mysqldump -p"$VAR"` in `borg-backup.sh` puts password on argv (briefly visible in `ps` inside `iredmail-db`). Switch to `--defaults-extra-file=` or `MYSQL_PWD` env.
- `data/postfix-queue` currently EXCLUDED from borg. In-flight queued mail at backup time is unrecoverable. Decide: include or document.
- Remove `/opt/iredmail/data/rescue-2026-04-29-*` snapshots (mode 755, no longer needed).
- ~~**SOGo memcached not running (P3, root-caused 2026-06-09).**~~ **RESOLVED 2026-06-15 (`dc41535`, deployed via rebuild+recreate).** `memcached` daemon was not installed in the image; SOGo defaults to caching at `127.0.0.1:11211`, so `SOGoCache: SERVER HAS FAILED AND IS DISABLED UNTIL TIMED RETRY` flooded `sogo.log` on every request. **Correction to the old "non-fatal, sending works" note:** it was *not* harmless. SOGo holds the session password (used for SMTP AUTH with `SOGoMailingMechanism=smtp`) in the shared memcached cache; once a worker lost the cached session it could not authenticate to submit, surfacing in webmail as intermittent "smtp could not authenticate" on send (no server-side trace, because SOGo never connected to postfix). Fix: added `memcached` to the Dockerfile SOGo package set + an s6 longrun service (`127.0.0.1:11211`, user `nobody`), with `sogo` ordered after it. Verified: 0 cache failures since boot; authenticated SOGo send + direct submission test both succeed.
- **Reconcile server `/opt/iredmail/` git tree** with `origin/main`. Server HEAD has been on an old commit for months while content gets scp'd in directly — works functionally, but `git pull` on server would conflict. Either: (a) commit + push the server-side state, then sync laptop, or (b) treat server as deploy-target only, never run `git pull` there, and update via laptop-push + scp. Pre-existing pattern, not urgent, surfaced 2026-05-02 by 2 verification agents.
