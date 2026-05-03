# P1-B Phase 2 — Learning Spam Filter (Bayes feedback loop)

**Status:** design approved 2026-05-03, awaiting user review of written spec before plan.
**Scope:** add user-driven Bayes training so SpamAssassin's score gets sharper over time, and persist the existing Bayes DB which is currently ephemeral inside the container.
**Out of scope:** Bayes auto_learn (passive, score-threshold based) — left off; can be added later via single config switch.

## Why

amavis already runs SpamAssassin with Bayes (`bayes_seen` + `bayes_toks` exist under `/var/lib/amavis/.spamassassin/`), but:

1. **The DB is ephemeral.** That path is *inside* the container's writable layer; the only `data/spamassassin` bind mount points to `/var/lib/spamassassin` (a different path that amavis doesn't use). Next `docker compose build` wipes ~6 days of accumulated tokens.
2. **No feedback loop.** Bayes self-learns nothing without user signal — `bayes_auto_learn` is commented out in `local.cf`. With auto_learn off and no manual training path, the DB only ever grows from amavis's own internal heuristics, which doesn't improve scoring of mail the user actually considers spam vs. ham.

This spec adds: persistent Bayes DB + a single learning path triggered by IMAP folder moves (Roundcube button, Thunderbird drag, mobile mail app — all funnel through the same hook).

## Architecture

**One trigger model: imap_sieve.** Dovecot's `imap_sieve` plugin observes IMAP COPY/APPEND events on the `Junk` folder. Two Sieve scripts react:

- `learn-spam.sieve` — fires on copy/append *into* `Junk` (regardless of source). Pipes the message into `sa-learn-pipe.sh spam`.
- `learn-ham.sieve` — fires on copy *out of* `Junk` to any other folder. Pipes the message into `sa-learn-pipe.sh ham`.

`sa-learn-pipe.sh` is a thin Bash wrapper. It runs as `vmail` (uid 2000, the user IMAP processes execute as) and uses `sudo -u amavis` to call `/usr/bin/sa-learn`, so updates land in the same Bayes DB amavis reads at scoring time. A tightly-scoped `/etc/sudoers.d/sa-learn` allows exactly two argument lists, no wildcards.

Roundcube's `markasjunk` plugin gets enabled with `markasjunk_learning_driver = null` — meaning the plugin contributes only the toolbar button + IMAP move, no direct sa-learn invocation. Single code path, no race between webmail-side and IMAP-side training.

```
Roundcube button ─┐
Thunderbird drag ─┼─→ IMAP COPY/APPEND ─→ Dovecot imap_sieve ─→ sa-learn-pipe.sh ─→ sudo sa-learn ─→ Bayes DB
Mobile client    ─┘                                                                                    ↑
                                                                                                       │
amavis (inbound scoring) ──────────────────────────────────────────────────────────────────────────────┘
```

## Components

### 1. Bind mount + Bayes migration

- `docker-compose.yml`: add mount under `iredmail-core`:
  ```yaml
  - ./data/amavis-spamassassin:/var/lib/amavis/.spamassassin
  ```
- Bootstrap step (in `init.sh` or container entrypoint, idempotent):
  ```sh
  install -d -o amavis -g amavis -m 0700 /var/lib/amavis/.spamassassin
  ```
- **One-time migration** (executed manually on the live server before first deploy of this change, otherwise the bind mount will shadow the existing DB with an empty dir):
  ```sh
  docker cp iredmail-core:/var/lib/amavis/.spamassassin/. ./data/amavis-spamassassin/
  chown -R 111:115 ./data/amavis-spamassassin/   # uid 111 / gid 115 = amavis
  chmod 700 ./data/amavis-spamassassin
  chmod 600 ./data/amavis-spamassassin/bayes_*
  ```
- `borg-backup.sh` source list: include `data/amavis-spamassassin/`. (Verify present in current source list — if not, add.)

### 2. Dovecot imap_sieve plugin + Sieve scripts

`rootfs/etc/dovecot/conf.d/91-iredmail-sieve.conf` — extend existing file:

```
protocol imap {
  mail_plugins = $mail_plugins imap_sieve
}

plugin {
  sieve_plugins = sieve_imapsieve sieve_extprograms

  imapsieve_mailbox1_name = Junk
  imapsieve_mailbox1_causes = COPY APPEND
  imapsieve_mailbox1_before = file:/var/lib/dovecot/sieve/imap/learn-spam.sieve

  imapsieve_mailbox2_name = *
  imapsieve_mailbox2_from = Junk
  imapsieve_mailbox2_causes = COPY
  imapsieve_mailbox2_before = file:/var/lib/dovecot/sieve/imap/learn-ham.sieve

  sieve_pipe_bin_dir = /usr/local/bin
  sieve_global_extensions = +vnd.dovecot.pipe +vnd.dovecot.environment
}
```

`rootfs/var/lib/dovecot/sieve/imap/learn-spam.sieve`:
```
require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables"];

if environment :matches "imap.user" "*" {
  set "username" "${1}";
}

pipe :copy "sa-learn-pipe.sh" ["spam", "${username}"];
```

`rootfs/var/lib/dovecot/sieve/imap/learn-ham.sieve`: identical except `"ham"`.

Build step: both `.sieve` files compiled with `sievec` so Dovecot loads `.svbin` directly. Either at container-build time (Dockerfile RUN) or on first start in `init.sh`.

### 3. sa-learn-pipe.sh wrapper + sudo policy

`rootfs/usr/local/bin/sa-learn-pipe.sh` (mode 0755, root:root):
```bash
#!/bin/bash
# Sieve pipe target: train SpamAssassin Bayes from user IMAP move events.
# args: $1 = "spam" | "ham"  $2 = username (logging only)
set -uo pipefail

mode="${1:?missing mode}"
user="${2:-unknown}"

if [[ "$mode" != "spam" && "$mode" != "ham" ]]; then
  logger -t sa-learn-pipe -p mail.warning "rejecting mode=$mode user=$user"
  exit 0
fi

if /usr/bin/sudo -n -u amavis /usr/bin/sa-learn --no-sync --"$mode" \
     --username=amavis --siteconfigpath=/etc/spamassassin >/dev/null 2>&1; then
  logger -t sa-learn-pipe -p mail.info "trained mode=$mode user=$user"
else
  logger -t sa-learn-pipe -p mail.warning "sa-learn FAILED mode=$mode user=$user"
fi

exit 0   # never block the IMAP move on training failure
```

`rootfs/etc/sudoers.d/sa-learn` (mode 0440, root:root):
```
vmail ALL=(amavis) NOPASSWD: /usr/bin/sa-learn --no-sync --spam --username=amavis --siteconfigpath=/etc/spamassassin
vmail ALL=(amavis) NOPASSWD: /usr/bin/sa-learn --no-sync --ham --username=amavis --siteconfigpath=/etc/spamassassin
```

No wildcards, no shell metachars in allowed args. The mode token in the wrapper script is whitelisted to `spam|ham` before reaching sudo, so even argument injection via Sieve `pipe` arglist would fall through to mode-rejection.

### 4. Roundcube markasjunk activation

In Roundcube's `config.inc.php` (path inside container: `/var/www/roundcube/config/config.inc.php`; on host: bind-mount or `data/roundcube/...` — verify during planning):

```php
$config['plugins'] = array_merge($config['plugins'] ?? [], ['markasjunk']);
$config['markasjunk_learning_driver'] = null;
$config['markasjunk_spam_mbox']       = 'Junk';
$config['markasjunk_ham_mbox']        = 'INBOX';
```

`learning_driver = null` is load-bearing — it limits the plugin to IMAP move only, which our imap_sieve catches. With a non-null driver the plugin would also call sa-learn directly (double-training).

### 5. Bayes sync cron

`rootfs/etc/cron.d/sa-learn-sync` (mode 0644):
```
*/15 * * * * amavis /usr/bin/sa-learn --sync --siteconfigpath=/etc/spamassassin >/dev/null 2>&1
```

`--no-sync` in the wrapper writes to a fast journal file; this cron flushes journal → `bayes_toks`/`bayes_seen` every 15 min. The user-visible behaviour of training is unchanged (bayes_seen still prevents double-training of the same Message-ID); the cron just batches I/O.

### 6. Logging routes

- `sudo` writes to `auth.*` syslog facility. Verify the existing rsyslog config in `rootfs/etc/rsyslog.d/` routes `auth.*` somewhere readable; if not, add a route to `/var/log/iredmail/sa-learn-sudo.log`.
- The wrapper itself uses `logger -t sa-learn-pipe -p mail.info` so train events appear in the existing `/var/log/iredmail/maillog`. No new log file needed for the success path.

## Error handling

| Failure | Outcome | Recovery |
|---|---|---|
| `sudo` denial (e.g., sudoers file dropped) | Wrapper logs `sa-learn FAILED`, IMAP move proceeds | Fix sudoers, no message lost |
| `sa-learn` crash (corrupt journal, etc.) | Same as above | `sa-learn --clear; sa-learn --rebuild` from cron-synced state |
| Bayes journal grows huge (cron not running) | sa-learn slows down on each call but still works | Manual `sa-learn --sync` |
| User mass-moves 50 mails in/out of Junk | Each gets trained (or de-duped via bayes_seen Message-ID tracking) | None needed; bayes_seen prevents re-training |
| Bind mount missing on first boot | amavis writes to ephemeral container layer (regression) | Pre-deploy migration step + container-startup `install -d` ensures dir always exists with right ownership |

## Testing

**Pre-deploy snapshot:**
```sh
docker exec iredmail-core sudo -u amavis sa-learn --dump magic | tee /tmp/bayes-pre.txt
```
Note `nspam`/`nham` counters.

**Spam-learn E2E:**
1. Send a non-GTUBE test mail to the test mailbox so it lands in INBOX naturally.
2. From Roundcube: select → "Mark as junk" button. Verify mail moves to Junk folder.
3. Wait ≤15 min (or run `sa-learn --sync` manually).
4. `sa-learn --dump magic` → `nspam` should be +1.
5. Repeat with Thunderbird drag-to-Junk on a different mail. `nspam` +1 again.

**Ham-learn E2E:**
1. Drag a message from Junk back to INBOX.
2. `sa-learn --dump magic` → `nham` +1.

**No-double-train:**
1. Drag the same mail Junk → INBOX → Junk → INBOX (4 moves on 1 message).
2. Counters should rise by exactly 1 each direction (Bayes-seen Message-ID dedup).

**Sudo policy test:**
```sh
docker exec -u vmail iredmail-core sudo -n -u amavis /usr/bin/sa-learn --foo
# expect: "Sorry, user vmail is not allowed to execute …"
```
The exact two whitelisted argument lists must succeed; any deviation must fail.

**Persistence test:**
1. Note `sa-learn --dump magic` counters.
2. `docker compose down && docker compose up -d`.
3. `sa-learn --dump magic` → counters identical = bind mount works.

**Borg inclusion test:**
1. After the persistence test, manually run `/opt/iredmail/scripts/borg-backup.sh`.
2. `borg list ::latest | grep amavis-spamassassin` — should show `bayes_seen` and `bayes_toks`.

## Migration steps (pre-deploy)

1. Dump current bayes counters for later compare.
2. `docker cp iredmail-core:/var/lib/amavis/.spamassassin/. /opt/iredmail/data/amavis-spamassassin/`
3. `chown -R 111:115 /opt/iredmail/data/amavis-spamassassin/`, `chmod 700` dir, `chmod 600` files.
4. Apply the rest of the changes (compose, dovecot conf, scripts, sudoers, cron, roundcube config), `docker compose build && up -d`.
5. Verify: `docker exec iredmail-core sudo -u amavis sa-learn --dump magic` matches pre-migration counters.

## Rollback

If anything goes wrong after deploy:
1. Revert the docker-compose mount + dovecot conf change, redeploy.
2. amavis returns to using container-internal `.spamassassin/` — but that's now empty in the new container layer. Restore via `docker cp ./data/amavis-spamassassin/. iredmail-core:/var/lib/amavis/.spamassassin/`.
3. Bayes is back to pre-feature state, learning is gone but spam scoring continues.

No data loss possible if the migration step ran first.

## Open items / nice-to-have (not blocking)

- Healthcheck cron: `sa-learn --dump magic` ratio sanity-check, alert via hc.io if `nspam` or `nham` haven't grown in 30 days.
- Document in README-DISASTER-RECOVERY.md that `data/amavis-spamassassin/` is part of restore-critical state.
- Consider auto_learn re-enable later with conservative thresholds (spam>15, ham<-2) once the DB has a robust user-trained baseline.
