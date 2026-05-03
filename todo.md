# TODO

Open work items. Pull from `progress.md` "Open / pending order" first; this file is for ideas, questions, and lower-priority cleanup.

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

- Retire `scripts/backup.sh` 2026-05-13 (after 2 weeks of borg stability). Or shorten retention to 7d.
- `restore-borg.sh:135` hardcoded 9-dir list → replace with deny-list iteration over actual borg archive contents (so new data dirs are restored automatically).
- `mysqldump -p"$VAR"` in `borg-backup.sh` puts password on argv (briefly visible in `ps` inside `iredmail-db`). Switch to `--defaults-extra-file=` or `MYSQL_PWD` env.
- `data/postfix-queue` currently EXCLUDED from borg. In-flight queued mail at backup time is unrecoverable. Decide: include or document.
- Remove `/opt/iredmail/data/rescue-2026-04-29-*` snapshots (mode 755, no longer needed).
- **Reconcile server `/opt/iredmail/` git tree** with `origin/main`. Server HEAD has been on an old commit for months while content gets scp'd in directly — works functionally, but `git pull` on server would conflict. Either: (a) commit + push the server-side state, then sync laptop, or (b) treat server as deploy-target only, never run `git pull` there, and update via laptop-push + scp. Pre-existing pattern, not urgent, surfaced 2026-05-02 by 2 verification agents.
- **iRedAdmin jail external-IP ban verification**: in-session test only confirmed self-IP ban via hairpin NAT (which bypasses DOCKER-USER). Recidive's external-IP ban WAS verified (REJECT rule appeared mid-test). Parity argument says iRedAdmin works the same way — but a single external curl from kirby's laptop would settle it. Do once next session.
- **Push the 3 commits** from 2026-05-02 → 2026-05-03 session: `4e33a8f` (iredadmin jail), `cab330c` (recidive jail), `f4a954c` (rsyslog dedup). Local is ahead of origin/main by 3.
