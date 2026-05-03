# P1-B Phase 2 — Learning Spam Filter (Bayes feedback loop)

**Status:** rev4 2026-05-03 — three review rounds (5 agents total) exhausted: rev1→rev2 closed 6 HIGH + 8 MED + 8 LOW (round 1, 2 agents); rev2→rev3 closed 1 HIGH + 4 MED + 4 LOW (round 2, 1 agent); rev3→rev4 closed 1 HIGH + 4 MED + 2 LOW (round 3, 2 agents — security-clear, reviewer found `vnd.dovecot.environment` require-name fix). All HIGH findings resolved; plan-ready.
**Scope:** add user-driven Bayes training so SpamAssassin's score gets sharper over time, and persist the existing Bayes DB which is currently ephemeral inside the container.
**Out of scope:** Bayes auto_learn (passive, score-threshold based) — left off; can be added later via single config switch.

## Why

amavis already runs SpamAssassin with Bayes (`bayes_seen` + `bayes_toks` exist under `/var/lib/amavis/.spamassassin/`), but:

1. **The DB is ephemeral.** That path is *inside* the container's writable layer; the only `data/spamassassin` bind mount points to `/var/lib/spamassassin` (a different path that amavis doesn't use). Next `docker compose build` wipes ~6 days of accumulated tokens.
2. **No feedback loop.** Bayes self-learns nothing without user signal — `bayes_auto_learn` is commented out in `local.cf`. With auto_learn off and no manual training path, the DB only ever grows from amavis's own internal heuristics, which doesn't improve scoring of mail the user actually considers spam vs. ham.

This spec adds: persistent Bayes DB + a single learning path triggered by IMAP folder moves (Roundcube button, Thunderbird drag, mobile mail app — all funnel through the same hook).

## Architecture

**One trigger model: imap_sieve.** Dovecot's `imap_sieve` plugin observes IMAP COPY/MOVE/APPEND events on the `Junk` folder. Two Sieve scripts react:

- `learn-spam.sieve` — fires on copy/move/append *into* `Junk` (regardless of source). Pipes the message into `sa-learn-pipe.sh spam`.
- `learn-ham.sieve` — fires on copy/move *out of* `Junk` to any other folder. Pipes the message into `sa-learn-pipe.sh ham`.

`sa-learn-pipe.sh` is a thin Bash wrapper. It runs as `vmail` (uid 2000, the user IMAP processes execute as) and uses `sudo -u amavis` to call `/usr/bin/sa-learn`, so updates land in the same Bayes DB amavis reads at scoring time. A tightly-scoped `/etc/sudoers.d/sa-learn` allows exactly two argument lists, no wildcards, with explicit `env_reset` + `secure_path`.

Roundcube's `markasjunk` plugin gets enabled with `markasjunk_learning_driver = null` — meaning the plugin contributes only the toolbar button + IMAP move, no direct sa-learn invocation. Single code path, no race between webmail-side and IMAP-side training.

**Critical safety property — server-side filing does NOT trigger learning.** `imap_sieve` is scoped to `protocol imap { ... }`. The existing `before.d/spam-to-junk.sieve` runs in `protocol lmtp { ... }` (LMTP delivery), a separate Dovecot subsystem. Inbound mail filed into Junk by amavis-flagged sieve filtering does NOT fire `imap_sieve` — only user-driven IMAP COPY/MOVE/APPEND does. This is enforced by Dovecot's protocol-block scoping; we make it explicit by documenting in the conf and adding a delivery-test step to verify (see Testing).

```
Roundcube button ─┐
Thunderbird drag ─┼─→ IMAP COPY/MOVE/APPEND ─→ Dovecot imap_sieve ─→ sa-learn-pipe.sh ─→ sudo sa-learn ─→ Bayes DB
Mobile client    ─┘                                                                                          ↑
                                                                                                             │
amavis (inbound scoring) ────────────────────────────────────────────────────────────────────────────────────┘

Inbound mail → LMTP → before.d/spam-to-junk.sieve fileinto Junk    [does NOT trigger imap_sieve — different protocol]
```

## Components

### 1. Bind mount + Bayes migration

- `docker-compose.yml`: add mount under `iredmail-core`:
  ```yaml
  - ./data/amavis-spamassassin:/var/lib/amavis/.spamassassin
  ```
- Bootstrap step in `init.sh` (idempotent, runs every container start):
  ```sh
  install -d -o amavis -g amavis -m 0700 /var/lib/amavis/.spamassassin
  ```
  This is correct as-is per existing iRedAdmin pattern (no recursive chown — only the dir, since contents migrate from existing DB with right uid/gid already). amavis must resolve to uid 111/gid 115 inside the container; verify in plan with `docker exec iredmail-core id amavis`.

- **One-time migration** (must stop container before cp to avoid losing tokens written between cp and deploy):
  ```sh
  docker compose stop iredmail-core
  docker cp iredmail-core:/var/lib/amavis/.spamassassin/. /opt/iredmail/data/amavis-spamassassin/
  chown -R 111:115 /opt/iredmail/data/amavis-spamassassin/
  chmod 700 /opt/iredmail/data/amavis-spamassassin
  chmod 600 /opt/iredmail/data/amavis-spamassassin/*    # globs ALL files (bayes_seen, bayes_toks, bayes_journal, bayes.lock if present)
  ```
  After migration the `docker compose up -d --build` in step 4 below brings the container back with the bind mount active and the migrated DB visible.

- **Borg backup inclusion verified, no script change required.** `scripts/borg-backup.sh` lines 142-157 source `data/` recursively with an explicit exclude list; `data/amavis-spamassassin/` is not in the excludes, so it picks up automatically once the dir exists. Verification step: `borg list ::latest | grep amavis-spamassassin` after the first scheduled backup post-deploy.

### 2. Dovecot imap_sieve plugin + Sieve scripts

`rootfs/etc/dovecot/conf.d/91-iredmail-sieve.conf` — extend existing file:

```
# imap_sieve fires only inside `protocol imap`. The existing LMTP-side
# before.d/spam-to-junk.sieve uses fileinto from `protocol lmtp` and does
# NOT trigger learning — that's the desired behaviour (we don't want amavis
# auto-filing inbound spam to feed back into Bayes).
protocol imap {
  mail_plugins = $mail_plugins imap_sieve
}

plugin {
  sieve_plugins = sieve_imapsieve sieve_extprograms

  # Spam direction: anything copied/moved/appended INTO Junk by a user.
  imapsieve_mailbox1_name = Junk
  imapsieve_mailbox1_causes = COPY MOVE APPEND
  imapsieve_mailbox1_after = file:/var/lib/dovecot/sieve/imap/learn-spam.sieve

  # Ham direction: anything copied/moved OUT of Junk to any other folder.
  imapsieve_mailbox2_name = *
  imapsieve_mailbox2_from = Junk
  imapsieve_mailbox2_causes = COPY MOVE
  imapsieve_mailbox2_after = file:/var/lib/dovecot/sieve/imap/learn-ham.sieve

  # Dedicated dir — only sa-learn-pipe.sh lives here. Don't grant
  # personal sieves access to all of /usr/local/bin.
  sieve_pipe_bin_dir = /usr/local/lib/dovecot/sieve-pipe
  sieve_global_extensions = +vnd.dovecot.pipe +vnd.dovecot.environment
}
```

Two design choices spelled out:

- **`_causes` includes `MOVE`** — RFC-6851 IMAP MOVE (used by Thunderbird default, Apple Mail, Gmail web) does NOT decompose to COPY+EXPUNGE; without `MOVE` in the cause list, drag-to-Junk in those clients trains nothing. `APPEND` covers IMAP-uploaded messages (rare for Junk, common for direct-to-folder filing).
- **`_after` instead of `_before`** — training fires only after the IMAP action succeeded. Fixes the case where COPY-into-Junk fails (e.g., quota) but Bayes still learned the rejected mail.

`rootfs/var/lib/dovecot/sieve/imap/learn-spam.sieve`:
```
# imap_sieve _after script — IMAP COPY/MOVE/APPEND already happened.
# Both `environment` (RFC 5183) and `vnd.dovecot.environment` are required:
# the standard ext enables the `environment` keyword, the vendor ext adds
# the `imap.user` item we read below.
# `pipe :copy` follows the documented Pigeonhole imap_sieve antispam
# example. `:copy` is a no-op for `pipe` in `_after` context (no implicit
# message disposal to suppress) but matches the canonical pattern; the
# `copy` capability stays in the require list for the same reason.
require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "vnd.dovecot.environment", "variables"];

# Cap pipe payload at 10 MB. Massive attachments piped synchronously
# into sa-learn would hold up the imap process and balloon the journal.
if size :over 10M { stop; }

if environment :matches "imap.user" "*" {
  set "username" "${1}";
}

pipe :copy "sa-learn-pipe.sh" ["spam", "${username}"];
```

`learn-ham.sieve`: identical except `"ham"`.

Build step: in `init.sh`, mirror the existing `before.d/*.sieve` compilation loop (init.sh:666-677) for `/var/lib/dovecot/sieve/imap/*.sieve` — runs every container start, idempotent and cheap; ensures bind-mount edits also recompile.

### 3. sa-learn-pipe.sh wrapper + sudo policy

`rootfs/usr/local/lib/dovecot/sieve-pipe/sa-learn-pipe.sh` (mode 0755, root:root):
```bash
#!/bin/bash
# Sieve pipe target: train SpamAssassin Bayes from user IMAP move events.
# args: $1 = "spam" | "ham"  $2 = username (logging only)
# Pin PATH so `logger` resolves regardless of Dovecot's pipe environment.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
set -uo pipefail

mode="${1:-}"
user="${2:-unknown}"

# Whitelist mode: only spam|ham is allowed past the gate.
case "$mode" in
  spam|ham) ;;
  *)
    cat >/dev/null   # drain stdin so Pigeonhole's writer doesn't see SIGPIPE
    logger -t sa-learn-pipe -p mail.warning "rejecting mode=$(printf %q "$mode")"
    exit 0
    ;;
esac

# Whitelist username chars; anything outside the regex falls back to "invalid"
# so log entries can't be smuggled with newlines / control chars / shell metas.
if [[ ! "$user" =~ ^[A-Za-z0-9._@+-]+$ ]]; then
  user=invalid
fi

# Capture sudo+sa-learn stderr so a sudoers-drift / missing-binary failure
# leaves an actionable diagnostic in the mail log instead of silent void.
err=$(/usr/bin/sudo -n -u amavis /usr/bin/sa-learn --no-sync --"$mode" \
        --username=amavis --siteconfigpath=/etc/spamassassin 2>&1 >/dev/null) \
  && logger -t sa-learn-pipe -p mail.info  "trained mode=$mode user=$user" \
  || logger -t sa-learn-pipe -p mail.warning "sa-learn FAILED mode=$mode user=$user err=$err"

exit 0   # never block the IMAP move on training failure
```

`rootfs/etc/sudoers.d/sa-learn` (mode 0440, root:root):
```
# env_reset is sudo's default, but we make it explicit and additionally pin
# secure_path so vmail-controlled PERL5LIB / SPAMASSASSIN_HOME / HOME can't
# influence sa-learn's plugin loading or DB path resolution.
Defaults!/usr/bin/sa-learn env_reset, secure_path="/usr/sbin:/usr/bin:/sbin:/bin"

vmail ALL=(amavis) NOPASSWD: /usr/bin/sa-learn --no-sync --spam --username=amavis --siteconfigpath=/etc/spamassassin
vmail ALL=(amavis) NOPASSWD: /usr/bin/sa-learn --no-sync --ham --username=amavis --siteconfigpath=/etc/spamassassin
```

Defense-in-depth layers:
1. **Sieve `pipe` arglist is exec-style, not shell-style** — Dovecot passes argv elements as separate strings to the syscall, never as a shell command line. A username like `"; rm -rf /"` arrives as `argv[2]="; rm -rf /"`, not as a shell tokenization. Even before sanitization, the wrapper sees one string in `$2`; metas would only matter if we later `eval`'d or string-built another shell command from it.
2. **Wrapper mode whitelist** — only `spam|ham` reaches the sudo invocation.
3. **Wrapper username regex** — log lines and any future arg-use are sanitized.
4. **Sudo argv match** — argv must equal one of the two whitelisted strings exactly; any drift (extra arg, different option spelling) is denied.
5. **Sudo env reset + secure_path** — `PERL5LIB`, `HOME`, `SPAMASSASSIN_HOME` etc. cannot influence sa-learn's behaviour. Debian's stock `/etc/sudoers` already sets a global `Defaults env_reset`; our `Defaults!/usr/bin/sa-learn` line additionally pins `secure_path` for this command and re-asserts `env_reset` for clarity (the per-cmd line cannot override stricter global behaviour, only narrow it).
6. **Dockerfile validation** — `RUN visudo -cf /etc/sudoers.d/sa-learn && chmod 0440 /etc/sudoers.d/sa-learn` fails the build if syntax is wrong AND locks the mode regardless of git's exec-bit tracking. Requires `sudo` package installed first (see Components inventory).

### 4. Roundcube markasjunk activation

Critical: `init.sh` (lines 906-974) **regenerates** `/var/www/roundcube/config/config.inc.php` from scratch on every container start, then `include`s `/opt/iredmail/custom/roundcube/config.inc.php`. The custom file is the **bind-mounted** `./config/roundcube/config.inc.php` from the repo. Anything written into the in-container generated file is lost on next start.

Edit the **bind-mounted** custom file: `config/roundcube/config.inc.php`:

```php
// markasjunk activation. learning_driver=null means plugin only does IMAP
// move — our Dovecot imap_sieve catches that. Avoids double-training.
$config['plugins'] = array_merge(isset($config['plugins']) ? $config['plugins'] : [], ['markasjunk']);
$config['markasjunk_learning_driver'] = null;
$config['markasjunk_spam_mbox']       = 'Junk';
$config['markasjunk_ham_mbox']        = 'INBOX';
```

Note the explicit `isset()` guard — `??` PHP-7-syntax is fine for current Roundcube but `isset` is broader-compat and matches the style of existing entries in `config/roundcube/config.inc.php`. The init.sh template defines `$config['plugins'] = array('archive', 'zipdownload', 'managesieve');` and `include`s the custom file *after*, so `array_merge` adds markasjunk to the existing list.

`markasjunk_ham_mbox = 'INBOX'` defines only where the Roundcube "Mark as not junk" button moves a message. Once it lands there, our `imapsieve_mailbox2_name = *` catches it as ham. The user could equally drag from Junk to any other folder via plain IMAP — `imapsieve_mailbox2_name = *` covers that too. The `_ham_mbox` setting governs the button's destination, not what counts as "ham" for learning.

### 5. Bayes journal sync

The `--no-sync` in the wrapper writes to a fast journal file; a periodic flush merges journal → `bayes_toks`/`bayes_seen`. Without it, sa-learn slows down on each call and inbound scoring sees stale tokens.

`iredmail-core` does NOT run a cron daemon — `cron` is apt-installed in the image but not registered as an s6-overlay service (`rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/` lists 12 services, cron not among them). Putting a file in `/etc/cron.d/` is silently a no-op.

**Fix:** host-side cron, mirroring the existing `borg-backup` pattern (host crontab → `docker exec` into container). The host runs as root, so `docker exec` can set the in-container user directly with `--user amavis` — no sudoers expansion needed (the existing two lines stay scoped to `vmail`-as-source-user only).

New entry in host's `/etc/cron.d/sa-learn-sync` (root cron):

```
*/15 * * * * root /usr/bin/timeout 60 /usr/bin/docker exec --user amavis iredmail-core /usr/bin/sa-learn --sync --siteconfigpath=/etc/spamassassin >/dev/null 2>&1
```

`timeout 60` prevents stacked invocations if dockerd ever stalls — without it, a hung daemon would queue a new sync every 15 min.

Rationale for not reusing sudoers: `--sync` is not in the two whitelisted argv strings (deliberately — the `vmail`→`amavis` path is *only* for spam/ham training, never sync). `docker exec --user amavis` from host-root sets the container uid directly without a sudo intermediary, keeping the wrapper's privilege model minimal.

### 6. Logging routes

- The wrapper uses `logger -t sa-learn-pipe -p mail.info` / `mail.warning`, so train events and failures appear in the existing `/var/log/iredmail/maillog` route. No new log file.
- `sudo` writes denials to `auth.warning`. Verify `rootfs/etc/rsyslog.d/50-iredmail.conf` (or wherever the iRedMail rsyslog config lives) routes auth somewhere readable; if not, add `auth.warning -/var/log/iredmail/sa-learn-sudo.log`. Most failure paths surface in the wrapper's own `err=$err` log line anyway, so this is secondary diagnostic.

## Error handling

| Failure | Outcome | Recovery |
|---|---|---|
| `sudo` denial (sudoers file dropped/corrupt) | Wrapper logs `sa-learn FAILED ... err=<sudo error>`, IMAP move proceeds | Fix sudoers, no message lost |
| `sa-learn` crash (corrupt journal, etc.) | Same as above with sa-learn error captured | `sa-learn --clear; sa-learn --rebuild` from cron-synced state |
| Bayes journal grows huge (host cron not running) | sa-learn slows on each call but still works | Run `docker exec --user amavis iredmail-core sa-learn --sync` manually |
| User mass-moves 50 mails into Junk | Each gets trained (or no-op via bayes_seen Message-ID dedup, same direction) | None needed |
| Bind mount missing on first boot | amavis writes to ephemeral container layer | Bootstrap `install -d` in init.sh ensures dir exists; migration step ensures content |
| Stdin > 10 MB | sieve `if size :over 10M { stop; }` returns early — pipe never invoked | None; not learned, not blocked |
| Username with control chars / shell metas | Wrapper regex falls back to `user=invalid`, training proceeds normally | None; logs are clean |

## Known limitations

**Re-classification of an already-learned message is not automatic.** SpamAssassin's `bayes_seen` records each Message-ID with its trained direction. `sa-learn --spam` on a Message-ID already learned as `spam` is a no-op (correct). But `sa-learn --ham` on a Message-ID already learned as `spam` is treated as an error condition — sa-learn refuses by default and would need an explicit `sa-learn --forget` followed by re-learn. Our wrapper redirects sa-learn's stderr into the `err=` log, exits 0, and the IMAP move proceeds — but the Bayes DB does NOT flip its classification.

User-visible effect: if you accidentally drag spam into Junk and then move it back to INBOX, the system stays trained as spam, and the second move just logs `sa-learn FAILED ... err=Sorry, opposite class already learned`. To force a re-classification, manual admin action: `docker exec --user amavis iredmail-core sa-learn --forget --message-id=<id>` then re-train. Documented as a known caveat; not worth automating for our single-user volume.

## Testing

**Pre-deploy snapshot:**
```sh
docker exec iredmail-core sudo -u amavis sa-learn --dump magic | tee /tmp/bayes-pre.txt
```
Note `nspam`/`nham` counters.

**Namespace verification (HIGH — blocks deploy if wrong):**
```sh
# Confirm amavis daemon_user resolves to "amavis" — our hardcoded --username=amavis
# trains into the same namespace amavis reads at scoring time.
docker exec iredmail-core grep -E '^\$daemon_user' /etc/amavis/conf.d/01-debian /etc/amavis/conf.d/15-content_filter_mode 2>/dev/null
docker exec iredmail-core sudo -u amavis perl -e 'use Mail::SpamAssassin; my $sa = Mail::SpamAssassin->new(); print $sa->{username},"\n"' 2>/dev/null
# Expect: "amavis" (or fall back to: invoke sa-learn -D once and grep "username=amavis" in trace)
```

**Spam-learn E2E (Roundcube):**
1. Send a non-GTUBE test mail to a test mailbox so it lands in INBOX naturally.
2. From Roundcube: select → "Mark as junk" button. Verify mail moves to Junk.
3. `docker exec --user amavis iredmail-core sa-learn --sync` (force flush — don't wait for cron).
4. `sa-learn --dump magic` → `nspam` should be +1.
5. Re-score the same mail through amavis (`amavis-services -t < /path/to/saved/raw`); should now contain a `BAYES_*` header reflecting the new classification — confirms training reached the namespace amavis reads.

**Spam-learn E2E (Thunderbird):** repeat with drag-to-Junk on a different mail. `nspam` +1 again.

**Ham-learn E2E:**
1. Drag a clean message from Junk back to INBOX.
2. Sync, check `sa-learn --dump magic` → `nham` +1.

**LMTP-no-trigger guarantee:**
1. Note `nspam` counter.
2. Send a GTUBE-tagged mail from outside (gets routed to Junk by `before.d/spam-to-junk.sieve`).
3. Sync, check `sa-learn --dump magic` → `nspam` should be **unchanged** (LMTP filing must NOT fire imap_sieve).

**Re-classification refusal (validates Known Limitations row):**
1. Train a message as spam (move to Junk, sync, verify `nspam` +1).
2. Move the same message back to INBOX (ham direction).
3. `tail /var/log/iredmail/maillog | grep sa-learn-pipe` — expect `sa-learn FAILED ... err=Sorry, ... opposite class already learned`.
4. `nham` should be **unchanged** in `--dump magic`.

**Sudo policy positive:** the two whitelisted argument lists succeed when invoked as vmail. (Run from `docker exec -u vmail` with the exact argv from sudoers; expect exit 0 and a sa-learn write to the journal.)

**Sudo policy negative — argv whitelist:**
```sh
docker exec -u vmail iredmail-core /usr/bin/sudo -n -u amavis /usr/bin/sa-learn --foo
# expect: "Sorry, user vmail is not allowed to execute …"  (argv mismatch)
```

**Sudo policy negative — env_reset enforcement (uses a whitelisted argv so the denial is attributable to `-E`, not argv):**
```sh
docker exec -u vmail iredmail-core /usr/bin/sudo -n -E -u amavis /usr/bin/sa-learn \
  --no-sync --spam --username=amavis --siteconfigpath=/etc/spamassassin
# expect: "sudo: a password is required" or "sorry, you are not allowed to set the following environment variables"
# (argv is whitelisted, so denial proves -E is rejected by env_reset)
```

**Pipe size DoS guard:**
```sh
# Append a 20 MB mail to Junk via doveadm and verify learn-spam.sieve `stop`s
# without invoking the wrapper.
docker exec iredmail-core dd if=/dev/urandom bs=1M count=20 | doveadm save -u testuser@kirby.rocks Junk
tail /var/log/iredmail/maillog | grep sa-learn-pipe   # expect: NO new "trained mode=spam" line
```

**Persistence test:**
1. Note `sa-learn --dump magic` counters.
2. `docker compose down && docker compose up -d`.
3. `sa-learn --dump magic` → counters identical = bind mount works.

**Borg inclusion test:**
1. Manually run `/opt/iredmail/scripts/borg-backup.sh`.
2. `borg list ::latest | grep amavis-spamassassin` — should show `bayes_seen` and `bayes_toks`.

## Migration steps (pre-deploy)

1. **Verify amavis uid/gid first** (abort if mismatch): `docker exec iredmail-core id amavis` MUST return `uid=111 gid=115`. If not, the hardcoded `chown 111:115` and `--username=amavis` paths are wrong and the entire deploy needs replanning. Don't proceed past this step on mismatch.
2. Dump current Bayes counters: `docker exec iredmail-core sudo -u amavis sa-learn --dump magic > /tmp/bayes-pre.txt`.
3. **Stop container first** to freeze amavis writes: `docker compose stop iredmail-core`.
4. Copy bayes files to host bind-mount target: `docker cp iredmail-core:/var/lib/amavis/.spamassassin/. /opt/iredmail/data/amavis-spamassassin/`.
5. Apply ownership and permissions: `chown -R 111:115 /opt/iredmail/data/amavis-spamassassin/`, `chmod 700 /opt/iredmail/data/amavis-spamassassin`, `chmod 600 /opt/iredmail/data/amavis-spamassassin/*`.
6. Apply the rest of the changes (compose mount, dovecot conf, sieve scripts, sa-learn-pipe.sh, sudoers, roundcube config, init.sh tweaks, host crontab entry).
7. `docker compose up -d --build`.
8. Verify counters match: `docker exec iredmail-core sudo -u amavis sa-learn --dump magic` should equal `/tmp/bayes-pre.txt`.
9. Run namespace verification + smoke test from Testing section above.

## Rollback

If anything goes wrong after deploy:
1. **Stop container first:** `docker compose stop iredmail-core` (don't `docker cp` while amavis is writing — corrupts Bayes).
2. Revert the docker-compose mount + dovecot conf change in git.
3. `docker cp /opt/iredmail/data/amavis-spamassassin/. iredmail-core:/var/lib/amavis/.spamassassin/` — restore tokens into the new (mount-less) container layer.
4. `docker compose up -d --build`.
5. Bayes is back to pre-feature state, learning is gone but spam scoring continues.

No data loss possible if step 1 of Migration ran first (i.e., we have the pre-deploy snapshot).

## Future tightening (LOW — track in todo.md after merge)

- **Healthcheck cron:** `sa-learn --dump magic` ratio sanity-check, alert via hc.io if `nspam`/`nham` haven't grown in 30 days, or if `nspam:nham` ratio drifts > 10:1 (poisoning indicator).
- **Bayes snapshots in borg:** confirmed via `data/amavis-spamassassin/` inclusion. Restore-drill once: extract a single archive's `bayes_*`, `sa-learn --restore` into a test instance.
- **README-DISASTER-RECOVERY.md:** call out `data/amavis-spamassassin/` as restore-critical state.
- **auto_learn re-enable later** with conservative thresholds (spam>15, ham<-2) once user-trained baseline is robust (~1k+ trained messages).
- **Junk folder locale:** Dovecot, SOGo, Roundcube all default to "Junk" in iRedMail; verify cross-checked but don't add code complexity for non-default localized client setups unless we hit one.
- **host-uid 111 mapping:** the bind-mount files are owned by host-uid 111 (whatever that resolves to in `/etc/passwd` of the host). On this Fedora 43 system that's currently unallocated (systemd-coredump is 998); on a future host or Debian/Ubuntu base the mapping may differ. Mode 0700 limits exposure regardless. Document if userns-remap or rootless docker is ever pursued.
- **Group-share alternative considered and rejected:** SpamAssassin docs propose `bayes_file_mode 0660` + shared group as the multi-user pattern. Rejected here because (a) it widens write surface to anyone in the group whether they should learn or not, (b) sudo gives explicit auditable invocation logs vs. silent file writes, (c) doesn't compose well with `--no-sync` journal handling. Documented for posterity; revisit only if sudo proves to add measurable latency (unlikely at our volume).
- **iRedAdmin username regex (defense-in-depth):** verify `sysadmin/user.py` regex on iRedAdmin restricts new accounts to chars matching the wrapper's `^[A-Za-z0-9._@+-]+$` whitelist, so `imap.user` is doubly-validated.
- **Sudoers drop-in audit (build-time):** add a Dockerfile assertion `RUN ! grep -RE '!env_reset' /etc/sudoers /etc/sudoers.d/` so any drop-in that weakens env_reset fails the build. Defense in depth against future packages installing sudoers files.
- **Shared-folders edge case:** `imap.user` reflects the *authenticated* user, not the mailbox owner. iRedMail default has no shared mailboxes, so this never matters today. If shared folders are ever enabled, training would be attributed to the acting user — review whether that's the desired audit behaviour.

## Components inventory (for plan)

Files added or modified:
- **MOD** `docker-compose.yml` — one mount line.
- **NEW** `data/amavis-spamassassin/` (host dir, populated by migration).
- **NEW** `rootfs/var/lib/dovecot/sieve/imap/learn-spam.sieve`
- **NEW** `rootfs/var/lib/dovecot/sieve/imap/learn-ham.sieve`
- **MOD** `rootfs/etc/dovecot/conf.d/91-iredmail-sieve.conf` — extend with imap_sieve plugin block.
- **NEW** `rootfs/usr/local/lib/dovecot/sieve-pipe/sa-learn-pipe.sh` (mode 0755).
- **NEW** `rootfs/etc/sudoers.d/sa-learn` (mode 0440).
- **MOD** `rootfs/etc/s6-overlay/scripts/init.sh` — bootstrap `install -d` for bayes dir; sieve compile loop for imap/*.sieve mirroring before.d pattern.
- **MOD** `Dockerfile` — (a) add `sudo` to the apt-install block (the existing block installs `dovecot-sieve cron supervisor` etc. but not `sudo`; without it, both the runtime wrapper and the build-time `visudo` step fail), (b) `RUN visudo -cf /etc/sudoers.d/sa-learn && chmod 0440 /etc/sudoers.d/sa-learn` (defensive build-time validation, must run AFTER `COPY rootfs/ /` so the file is in place).
- **MOD** `config/roundcube/config.inc.php` — markasjunk plugin + 3 config vars.
- **NEW** host `/etc/cron.d/sa-learn-sync` (root) for `*/15 * * * * docker exec --user amavis iredmail-core sa-learn --sync …`.
- **POSSIBLE-MOD** `rootfs/etc/rsyslog.d/50-iredmail.conf` if auth.warning isn't already routed.

Total: ~3 NEW source files, ~4 MOD source files, 1 Dockerfile change, 1 host crontab change, 1 host bind-mount dir.
