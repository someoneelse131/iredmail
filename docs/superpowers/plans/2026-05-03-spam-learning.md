# Spam-Learning (P1-B Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add user-driven Bayes feedback training (Junk-folder moves trigger sa-learn) and persist the currently-ephemeral SpamAssassin Bayes DB.

**Architecture:** Dovecot `imap_sieve` plugin watches IMAP COPY/MOVE/APPEND on the `Junk` mailbox; two sieve scripts pipe into a Bash wrapper that sudo's into amavis to run sa-learn. Roundcube `markasjunk` plugin provides the visible "Mark as junk" button (IMAP move only — same code path as Thunderbird/mobile). Bayes DB moved to a new bind mount under `data/amavis-spamassassin/`. Sync via host-side cron through `docker exec --user amavis`.

**Tech Stack:** Dovecot Pigeonhole sieve, SpamAssassin sa-learn, Bash, sudo, Docker Compose, Roundcube PHP plugin.

**Spec:** `docs/superpowers/specs/2026-05-03-spam-learning-design.md` (rev4, plan-ready). Read before starting if context is missing.

**Working dir:** `/home/kirby/projects/github/iredadmin/` (laptop). Server commands run via `ssh mail`.

---

## Task 0 — Pre-flight: verify amavis uid/gid on running server

The spec hardcodes `--username=amavis` in sudoers and `chown 111:115` in migration. If the running container's `amavis` user is on different uid/gid, the entire deploy is misaligned. This is the first abort gate.

**Files:** none (read-only verification)

- [ ] **Step 1: SSH into server and run `id amavis` inside the container**

```sh
ssh mail 'sudo docker exec iredmail-core id amavis'
```

Expected output: `uid=111(amavis) gid=115(amavis) groups=115(amavis)`

- [ ] **Step 2: Snapshot current Bayes counters for later compare**

```sh
ssh mail 'sudo docker exec iredmail-core sudo -u amavis sa-learn --dump magic' | tee /tmp/bayes-pre.txt
```

Note `nspam` and `nham` values. Should be non-zero if amavis has been running with bayes for >1 day.

- [ ] **Step 3: ABORT condition**

If Step 1 returns anything other than uid=111/gid=115, STOP and update the spec to use the actual values, then re-review before continuing. All later tasks assume 111:115.

---

## Task 1 — Add `sudo` package to Dockerfile + sudoers RUN

The wrapper calls `/usr/bin/sudo`, which isn't installed in the base image. Without this, every sieve trigger silently fails with "sudo: command not found".

**Files:**
- Modify: `Dockerfile`

- [ ] **Step 1: Locate the apt-get install block**

```sh
grep -n "apt-get install" /home/kirby/projects/github/iredadmin/Dockerfile | head
```

There's a primary install block around line 75-125. Find the line that lists `cron supervisor` and add `sudo` to the list.

- [ ] **Step 2: Edit Dockerfile — add sudo to apt-install**

Find the existing line that looks like:
```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    ... cron supervisor ... \
    && apt-get clean
```

Add `sudo` to the package list (alphabetical order if the list is sorted, otherwise next to `cron`).

- [ ] **Step 3: Add visudo + chmod RUN AFTER `COPY rootfs/ /`**

Find the line `COPY rootfs/ /` (around line 230 in current Dockerfile). Immediately after it, add:

```dockerfile
# Validate sudoers and lock mode (sudo refuses files with bad perms or syntax)
RUN visudo -cf /etc/sudoers.d/sa-learn && chmod 0440 /etc/sudoers.d/sa-learn
```

Note: this RUN will fail the build if `rootfs/etc/sudoers.d/sa-learn` doesn't exist yet, so we need to create it BEFORE the next docker build. That happens in Task 2.

- [ ] **Step 4: Commit (Dockerfile change only — image won't build until Task 2 lands; that's fine, we'll build at Task 6)**

```sh
cd /home/kirby/projects/github/iredadmin && git add Dockerfile && git commit -m "Dockerfile: install sudo + validate sa-learn sudoers at build

Spam-learning wrapper invokes sudo -u amavis sa-learn; the sudo binary
wasn't pulled in transitively. visudo -cf fails the build if the
sudoers file we ship has syntax errors. chmod 0440 ensures sudo accepts
the file regardless of git's exec-bit tracking."
```

---

## Task 2 — Create the sudoers policy file

**Files:**
- Create: `rootfs/etc/sudoers.d/sa-learn`

- [ ] **Step 1: Write the file**

```sh
mkdir -p /home/kirby/projects/github/iredadmin/rootfs/etc/sudoers.d
```

Then create `rootfs/etc/sudoers.d/sa-learn` with this content:

```
# Allow vmail to run sa-learn as amavis with exactly two argument lists.
# No wildcards, no shell metachars permitted in argv.
# env_reset is sudo's default but we re-assert it for /usr/bin/sa-learn
# and pin secure_path so vmail-controlled PERL5LIB / SPAMASSASSIN_HOME
# can't influence sa-learn's plugin loading or DB path resolution.
Defaults!/usr/bin/sa-learn env_reset, secure_path="/usr/sbin:/usr/bin:/sbin:/bin"

vmail ALL=(amavis) NOPASSWD: /usr/bin/sa-learn --no-sync --spam --username=amavis --siteconfigpath=/etc/spamassassin
vmail ALL=(amavis) NOPASSWD: /usr/bin/sa-learn --no-sync --ham --username=amavis --siteconfigpath=/etc/spamassassin
```

- [ ] **Step 2: Static syntax check (host-side)**

```sh
visudo -cf /home/kirby/projects/github/iredadmin/rootfs/etc/sudoers.d/sa-learn
```

Expected output: `… parsed OK`. If it errors, fix the file before commit.

- [ ] **Step 3: Set restrictive mode in repo (so COPY preserves it)**

```sh
chmod 0440 /home/kirby/projects/github/iredadmin/rootfs/etc/sudoers.d/sa-learn
```

Note: git only tracks the executable bit (0755 vs 0644), not the read-permission bits. The Dockerfile RUN at Task 1 Step 3 re-chmods to 0440 to make this guaranteed.

- [ ] **Step 4: Commit**

```sh
cd /home/kirby/projects/github/iredadmin && git add rootfs/etc/sudoers.d/sa-learn && git commit -m "sudoers: allow vmail to run sa-learn as amavis (spam|ham only)

Two whitelisted argument lists, no wildcards. Defaults!/usr/bin/sa-learn
re-asserts env_reset and pins secure_path. visudo -cf passes.
Mode 0440 in repo; Dockerfile re-chmods at build."
```

---

## Task 3 — Create the wrapper script

**Files:**
- Create: `rootfs/usr/local/lib/dovecot/sieve-pipe/sa-learn-pipe.sh`

- [ ] **Step 1: Make the directory in repo**

```sh
mkdir -p /home/kirby/projects/github/iredadmin/rootfs/usr/local/lib/dovecot/sieve-pipe
```

- [ ] **Step 2: Write the wrapper**

Create `rootfs/usr/local/lib/dovecot/sieve-pipe/sa-learn-pipe.sh` with:

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

- [ ] **Step 3: chmod + bash -n syntax check**

```sh
chmod 0755 /home/kirby/projects/github/iredadmin/rootfs/usr/local/lib/dovecot/sieve-pipe/sa-learn-pipe.sh
bash -n /home/kirby/projects/github/iredadmin/rootfs/usr/local/lib/dovecot/sieve-pipe/sa-learn-pipe.sh
```

Expected: no output (= valid bash syntax).

- [ ] **Step 4: Run wrapper through ShellCheck if available**

```sh
which shellcheck && shellcheck /home/kirby/projects/github/iredadmin/rootfs/usr/local/lib/dovecot/sieve-pipe/sa-learn-pipe.sh
```

If shellcheck isn't installed, skip. Acceptable warnings: SC2086 (no double-quoting in `--"$mode"` — this is intentional and locked by the case statement). Anything HIGH/MED severity should be fixed.

- [ ] **Step 5: Commit**

```sh
cd /home/kirby/projects/github/iredadmin && git add rootfs/usr/local/lib/dovecot/sieve-pipe/sa-learn-pipe.sh && git commit -m "sa-learn-pipe.sh: wrapper for sieve-driven Bayes training

Validates mode (spam|ham case), sanitises username (regex whitelist),
captures sudo+sa-learn stderr into mail.warning on failure, exits 0
unconditionally so a training failure never blocks the IMAP move.
PATH pinned so logger resolves regardless of Dovecot pipe env."
```

---

## Task 4 — Create the two sieve scripts

**Files:**
- Create: `rootfs/var/lib/dovecot/sieve/imap/learn-spam.sieve`
- Create: `rootfs/var/lib/dovecot/sieve/imap/learn-ham.sieve`

- [ ] **Step 1: Make the directory in repo**

```sh
mkdir -p /home/kirby/projects/github/iredadmin/rootfs/var/lib/dovecot/sieve/imap
```

- [ ] **Step 2: Create learn-spam.sieve**

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

- [ ] **Step 3: Create learn-ham.sieve (identical except "spam" → "ham")**

```
# imap_sieve _after script — IMAP COPY/MOVE/APPEND already happened.
# Both `environment` (RFC 5183) and `vnd.dovecot.environment` are required:
# the standard ext enables the `environment` keyword, the vendor ext adds
# the `imap.user` item we read below.
require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "vnd.dovecot.environment", "variables"];

if size :over 10M { stop; }

if environment :matches "imap.user" "*" {
  set "username" "${1}";
}

pipe :copy "sa-learn-pipe.sh" ["ham", "${username}"];
```

- [ ] **Step 4: Verify file modes (must be readable by Dovecot)**

```sh
chmod 0644 /home/kirby/projects/github/iredadmin/rootfs/var/lib/dovecot/sieve/imap/learn-{spam,ham}.sieve
ls -l /home/kirby/projects/github/iredadmin/rootfs/var/lib/dovecot/sieve/imap/
```

Expected: both files exist, mode -rw-r--r--.

- [ ] **Step 5: Commit**

```sh
cd /home/kirby/projects/github/iredadmin && git add rootfs/var/lib/dovecot/sieve/imap/ && git commit -m "sieve: imap_sieve scripts for spam+ham Bayes training

learn-spam fires on COPY/MOVE/APPEND into Junk; learn-ham fires on
COPY/MOVE out of Junk to any folder. Both pipe message body to
sa-learn-pipe.sh via sieve_pipe. 10 MB size cap. require lists both
'environment' (RFC 5183) and 'vnd.dovecot.environment' (for imap.user)."
```

---

## Task 5 — Extend `91-iredmail-sieve.conf` with imap_sieve plugin block

**Files:**
- Modify: `rootfs/etc/dovecot/conf.d/91-iredmail-sieve.conf`

- [ ] **Step 1: Read current contents**

```sh
cat /home/kirby/projects/github/iredadmin/rootfs/etc/dovecot/conf.d/91-iredmail-sieve.conf
```

Note the existing structure (`protocol lmtp`, `plugin {}`, etc.).

- [ ] **Step 2: Append the imap_sieve block at the end of the file**

Add this AFTER the existing content (don't modify existing lines):

```
# =============================================================================
# imap_sieve — user-driven Bayes training via Junk-folder COPY/MOVE/APPEND
# =============================================================================
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

If the existing file already has a `plugin { ... }` block, MERGE the new keys into the existing block instead of duplicating it. (Dovecot config tolerates two `plugin` blocks but it's confusing.)

- [ ] **Step 3: Static check — no syntax errors via grep heuristics**

```sh
grep -c "imapsieve_mailbox1_after\|sieve_pipe_bin_dir" /home/kirby/projects/github/iredadmin/rootfs/etc/dovecot/conf.d/91-iredmail-sieve.conf
```

Expected: 2 (one of each). True Dovecot syntax check happens at container start.

- [ ] **Step 4: Commit**

```sh
cd /home/kirby/projects/github/iredadmin && git add rootfs/etc/dovecot/conf.d/91-iredmail-sieve.conf && git commit -m "dovecot: enable imap_sieve plugin for Bayes training

protocol imap loads imap_sieve. Two imapsieve_mailbox* rules: COPY/MOVE/
APPEND into Junk -> learn-spam.sieve; COPY/MOVE out of Junk to any folder
-> learn-ham.sieve. _after timing so training fires only on successful
filing. sieve_pipe_bin_dir tightened to dedicated sieve-pipe/ dir."
```

---

## Task 6 — Modify `init.sh`: bootstrap bayes dir + compile imap sieves

**Files:**
- Modify: `rootfs/etc/s6-overlay/scripts/init.sh`

- [ ] **Step 1: Locate the existing before.d sieve compile loop**

```sh
grep -n "before.d\|sievec" /home/kirby/projects/github/iredadmin/rootfs/etc/s6-overlay/scripts/init.sh
```

You should see lines around 666-677 with a `sievec ... before.d/*.sieve` loop. We'll mirror that pattern.

- [ ] **Step 2: Locate the amavis configuration section**

```sh
grep -n "amavis\|/var/lib/amavis" /home/kirby/projects/github/iredadmin/rootfs/etc/s6-overlay/scripts/init.sh | head
```

Find a logical place (probably inside or right after the function that sets up amavis) to add the bayes-dir bootstrap.

- [ ] **Step 3: Add bayes-dir bootstrap (idempotent)**

Insert the following near the amavis-setup section (or before `start dovecot` whichever comes first):

```bash
# Ensure the Bayes DB bind-mount target exists with correct ownership.
# Idempotent: install -d only chowns/chmods the target itself, never recurses.
install -d -o amavis -g amavis -m 0700 /var/lib/amavis/.spamassassin
```

- [ ] **Step 4: Add imap-sieve compile loop mirroring before.d pattern**

Right after the existing `before.d/*.sieve` compile loop, add an analogous loop for `/var/lib/dovecot/sieve/imap/*.sieve`:

```bash
# Compile imap_sieve scripts (analogous to the before.d compile above).
# Idempotent — sievec rewrites .svbin from .sieve every run.
for f in /var/lib/dovecot/sieve/imap/*.sieve; do
  if [ -f "$f" ]; then
    sievec "$f"
  fi
done
chown -R vmail:vmail /var/lib/dovecot/sieve/imap
```

(Note: the existing before.d loop probably has its own ownership model; mirror what it does. Check the surrounding lines first.)

- [ ] **Step 5: Bash syntax check**

```sh
bash -n /home/kirby/projects/github/iredadmin/rootfs/etc/s6-overlay/scripts/init.sh
```

Expected: no output.

- [ ] **Step 6: Commit**

```sh
cd /home/kirby/projects/github/iredadmin && git add rootfs/etc/s6-overlay/scripts/init.sh && git commit -m "init.sh: bootstrap bayes dir + compile imap_sieve scripts

install -d for /var/lib/amavis/.spamassassin (idempotent, no -R chown).
sievec loop for imap/*.sieve mirrors the existing before.d pattern."
```

---

## Task 7 — Add bind mount to `docker-compose.yml`

**Files:**
- Modify: `docker-compose.yml`

- [ ] **Step 1: Locate the iredmail-core service mount block**

```sh
grep -nE "iredmail-core:|volumes:|amavis|spamassassin" /home/kirby/projects/github/iredadmin/docker-compose.yml | head -30
```

Find the `volumes:` list under the `iredmail-core` (or whatever the iRedMail-core service is named) service. The existing data/* mounts are listed there.

- [ ] **Step 2: Add the new mount line**

Append to the volumes list of the iredmail-core service:

```yaml
      - ./data/amavis-spamassassin:/var/lib/amavis/.spamassassin
```

Place it next to the other amavis-related mounts if any, or alphabetically with the other `./data/*` mounts. Indentation must match (typically 6 spaces).

- [ ] **Step 3: Validate compose file**

```sh
cd /home/kirby/projects/github/iredadmin && docker compose config >/dev/null
```

Expected: no error. (`config` parses+validates the compose file without starting anything.)

- [ ] **Step 4: Commit**

```sh
cd /home/kirby/projects/github/iredadmin && git add docker-compose.yml && git commit -m "docker-compose: persist amavis Bayes DB via bind mount

data/amavis-spamassassin -> /var/lib/amavis/.spamassassin. Was
previously in the container's writable layer (wiped on rebuild)."
```

---

## Task 8 — Enable `markasjunk` in Roundcube custom config

**Files:**
- Modify: `config/roundcube/config.inc.php`

- [ ] **Step 1: Read current custom config**

```sh
cat /home/kirby/projects/github/iredadmin/config/roundcube/config.inc.php
```

Note the existing style (`<?php` opening, `$config['…']` lines).

- [ ] **Step 2: Append markasjunk activation block**

Add to the bottom of `config/roundcube/config.inc.php` (before any closing `?>` if present — usually omitted in Roundcube custom configs):

```php

// markasjunk activation. learning_driver=null means plugin only does IMAP
// move — our Dovecot imap_sieve catches that. Avoids double-training.
$config['plugins'] = array_merge(isset($config['plugins']) ? $config['plugins'] : [], ['markasjunk']);
$config['markasjunk_learning_driver'] = null;
$config['markasjunk_spam_mbox']       = 'Junk';
$config['markasjunk_ham_mbox']        = 'INBOX';
```

- [ ] **Step 3: PHP syntax check**

```sh
php -l /home/kirby/projects/github/iredadmin/config/roundcube/config.inc.php
```

Expected: `No syntax errors detected …`. If `php` isn't installed locally, skip — Roundcube will fail-loud at runtime if syntax is wrong.

- [ ] **Step 4: Commit**

```sh
cd /home/kirby/projects/github/iredadmin && git add config/roundcube/config.inc.php && git commit -m "roundcube: enable markasjunk plugin (IMAP-move only)

Adds visible 'Mark as junk' button. learning_driver=null so the
plugin only does the IMAP move — our Dovecot imap_sieve does the
training, single code path. _spam_mbox/_ham_mbox govern the button's
destination only; learning trigger is the imap_sieve mailbox match."
```

---

## Task 9 — Local Docker build verification

Verify all the in-repo changes pass build (visudo, image layers complete) before touching the server.

**Files:** none (build verification only)

- [ ] **Step 1: Local docker build, NO push, NO deploy**

```sh
cd /home/kirby/projects/github/iredadmin && docker compose build iredmail-core 2>&1 | tail -50
```

Expected: build completes without errors. The visudo step (Task 1 Step 3) runs and confirms sudoers syntax. apt-get install includes sudo. The COPY rootfs step ships sudoers + wrapper + sieve scripts.

- [ ] **Step 2: Verify the image actually contains what we expect**

```sh
docker run --rm --entrypoint='' iredmail-iredmail-core ls -la \
  /etc/sudoers.d/sa-learn \
  /usr/local/lib/dovecot/sieve-pipe/sa-learn-pipe.sh \
  /var/lib/dovecot/sieve/imap/learn-spam.sieve \
  /var/lib/dovecot/sieve/imap/learn-ham.sieve
```

Replace `iredmail-iredmail-core` with the actual image tag if different (`docker images | grep iredmail`). Expected output:
- `sa-learn` mode `-r--r-----` (0440)
- `sa-learn-pipe.sh` mode `-rwxr-xr-x` (0755)
- both `.sieve` files mode `-rw-r--r--` (0644)

- [ ] **Step 3: Verify sudo binary present**

```sh
docker run --rm --entrypoint='' iredmail-iredmail-core which sudo
```

Expected: `/usr/bin/sudo`

- [ ] **Step 4: Verify sudoers parses inside the image**

```sh
docker run --rm --entrypoint='' iredmail-iredmail-core visudo -cf /etc/sudoers.d/sa-learn
```

Expected: `… parsed OK`.

- [ ] **Step 5: If everything green, push the in-repo commits to origin**

```sh
cd /home/kirby/projects/github/iredadmin && git push
```

(Server pulls happen separately — see Task 10.)

---

## Task 10 — Server-side migration (the disruptive step)

This is the deploy. From this point onward, mail-flow is briefly halted while the container restarts. Total downtime: ~30 seconds.

**Files:** none (server-side runbook)

- [ ] **Step 1: SSH and re-verify pre-flight (Task 0 might have been hours ago)**

```sh
ssh mail 'sudo docker exec iredmail-core id amavis && sudo docker exec iredmail-core sudo -u amavis sa-learn --dump magic' | tee /tmp/bayes-pre.txt
```

Confirm uid/gid 111/115. Note current `nspam`/`nham` for after-migration compare.

- [ ] **Step 2: Sync repo to server**

The server `/opt/iredmail/` is known to be out of sync with origin/main (pre-existing — see todo.md). Use the existing pattern (scp + manual edit), or if the server's git tree is workable, `git pull`.

The PRACTICAL minimum: scp these specific paths to the server's `/opt/iredmail/` so the next container build sees them:
- `Dockerfile`
- `docker-compose.yml`
- `rootfs/etc/sudoers.d/sa-learn`
- `rootfs/usr/local/lib/dovecot/sieve-pipe/sa-learn-pipe.sh`
- `rootfs/var/lib/dovecot/sieve/imap/learn-spam.sieve`
- `rootfs/var/lib/dovecot/sieve/imap/learn-ham.sieve`
- `rootfs/etc/dovecot/conf.d/91-iredmail-sieve.conf`
- `rootfs/etc/s6-overlay/scripts/init.sh`
- `config/roundcube/config.inc.php`

```sh
cd /home/kirby/projects/github/iredadmin
ssh mail 'sudo install -d -o root -g root /opt/iredmail/rootfs/etc/sudoers.d /opt/iredmail/rootfs/usr/local/lib/dovecot/sieve-pipe /opt/iredmail/rootfs/var/lib/dovecot/sieve/imap'
scp Dockerfile docker-compose.yml mail:/tmp/
scp rootfs/etc/sudoers.d/sa-learn mail:/tmp/sa-learn.sudoers
scp rootfs/usr/local/lib/dovecot/sieve-pipe/sa-learn-pipe.sh mail:/tmp/sa-learn-pipe.sh
scp rootfs/var/lib/dovecot/sieve/imap/learn-spam.sieve rootfs/var/lib/dovecot/sieve/imap/learn-ham.sieve mail:/tmp/
scp rootfs/etc/dovecot/conf.d/91-iredmail-sieve.conf mail:/tmp/91-iredmail-sieve.conf
scp rootfs/etc/s6-overlay/scripts/init.sh mail:/tmp/init.sh
scp config/roundcube/config.inc.php mail:/tmp/roundcube.inc.php
ssh mail 'sudo install -m 644 /tmp/Dockerfile /opt/iredmail/Dockerfile && \
  sudo install -m 644 /tmp/docker-compose.yml /opt/iredmail/docker-compose.yml && \
  sudo install -m 440 /tmp/sa-learn.sudoers /opt/iredmail/rootfs/etc/sudoers.d/sa-learn && \
  sudo install -m 755 /tmp/sa-learn-pipe.sh /opt/iredmail/rootfs/usr/local/lib/dovecot/sieve-pipe/sa-learn-pipe.sh && \
  sudo install -m 644 /tmp/learn-spam.sieve /opt/iredmail/rootfs/var/lib/dovecot/sieve/imap/learn-spam.sieve && \
  sudo install -m 644 /tmp/learn-ham.sieve /opt/iredmail/rootfs/var/lib/dovecot/sieve/imap/learn-ham.sieve && \
  sudo install -m 644 /tmp/91-iredmail-sieve.conf /opt/iredmail/rootfs/etc/dovecot/conf.d/91-iredmail-sieve.conf && \
  sudo install -m 755 /tmp/init.sh /opt/iredmail/rootfs/etc/s6-overlay/scripts/init.sh && \
  sudo install -m 644 /tmp/roundcube.inc.php /opt/iredmail/config/roundcube/config.inc.php && \
  rm /tmp/Dockerfile /tmp/docker-compose.yml /tmp/sa-learn.sudoers /tmp/sa-learn-pipe.sh /tmp/learn-{spam,ham}.sieve /tmp/91-iredmail-sieve.conf /tmp/init.sh /tmp/roundcube.inc.php'
```

- [ ] **Step 3: Stop iredmail-core to freeze amavis writes**

```sh
ssh mail 'cd /opt/iredmail && sudo docker compose stop iredmail-core'
```

⚠️ At this point IMAP/SMTP/webmail are unavailable. Move quickly — total downtime target ~60s.

- [ ] **Step 4: Migrate Bayes DB to host bind-mount target**

```sh
ssh mail 'sudo install -d -o 111 -g 115 -m 0700 /opt/iredmail/data/amavis-spamassassin && \
  sudo docker cp iredmail-core:/var/lib/amavis/.spamassassin/. /opt/iredmail/data/amavis-spamassassin/ && \
  sudo chown -R 111:115 /opt/iredmail/data/amavis-spamassassin/ && \
  sudo chmod 700 /opt/iredmail/data/amavis-spamassassin && \
  sudo find /opt/iredmail/data/amavis-spamassassin -type f -exec chmod 600 {} \;'
```

- [ ] **Step 5: Build and start with new mount + new code**

```sh
ssh mail 'cd /opt/iredmail && sudo docker compose up -d --build iredmail-core'
```

Wait ~20s for s6 to bring all services up.

- [ ] **Step 6: Verify Bayes counters survived**

```sh
ssh mail 'sudo docker exec iredmail-core sudo -u amavis sa-learn --dump magic' | diff /tmp/bayes-pre.txt -
```

Expected: zero diff (or only timestamps changed). If the counts changed, the migration lost or duplicated tokens — investigate before proceeding.

- [ ] **Step 7: Verify all 6 fail2ban jails still up + amavis ports listening**

```sh
ssh mail 'sudo docker exec iredmail-fail2ban fail2ban-client status; sudo docker exec iredmail-core ss -ltn | grep -E "10024|10025|10026"'
```

Expected: 6 jails (dovecot, iredadmin, postfix-sasl, recidive, roundcube-auth, sogo-auth), and ports 10024/10025/10026 all `LISTEN`. If a jail or port is missing, the new conf likely broke something — see Task 12 rollback.

---

## Task 11 — Install host-side sync cron

**Files:** none (host file outside repo: `/etc/cron.d/sa-learn-sync`)

- [ ] **Step 1: Create cron file via ssh + tee**

```sh
ssh mail 'echo "*/15 * * * * root /usr/bin/timeout 60 /usr/bin/docker exec --user amavis iredmail-core /usr/bin/sa-learn --sync --siteconfigpath=/etc/spamassassin >/dev/null 2>&1" | sudo tee /etc/cron.d/sa-learn-sync >/dev/null && sudo chmod 644 /etc/cron.d/sa-learn-sync'
```

- [ ] **Step 2: Verify cron picked it up**

```sh
ssh mail 'sudo systemctl status cron.service --no-pager | head; sudo grep sa-learn-sync /var/log/syslog 2>/dev/null | tail -3'
```

Expected: cron service `active (running)`. Syslog grep may be empty until first 15-min mark hits.

- [ ] **Step 3: Manual one-shot test**

```sh
ssh mail 'sudo /usr/bin/timeout 60 /usr/bin/docker exec --user amavis iredmail-core /usr/bin/sa-learn --sync --siteconfigpath=/etc/spamassassin && echo OK'
```

Expected: `OK` printed (sa-learn --sync exits 0 even on no-op).

---

## Task 12 — Verification: run all the testing scenarios from the spec

This is the substantive validation step. Each substep mirrors a §Testing item in the spec.

**Files:** none (runtime verification on server)

- [ ] **Step 1: Namespace verification**

```sh
ssh mail 'sudo docker exec iredmail-core grep -E "^\\\$daemon_user" /etc/amavis/conf.d/*.conf 2>/dev/null; sudo docker exec iredmail-core sudo -u amavis perl -e "use Mail::SpamAssassin; my \$sa = Mail::SpamAssassin->new(); print \$sa->{username},\"\\n\"" 2>/dev/null'
```

Expected: `daemon_user = "amavis"` somewhere; perl prints `amavis`. If the perl one-liner errors, fall back to `docker exec iredmail-core sudo -u amavis sa-learn -D 2>&1 | grep username`.

- [ ] **Step 2: LMTP-no-trigger guarantee**

Note `nspam` from `sa-learn --dump magic`. Send a GTUBE-tagged mail from outside (smtplib script, or a test webhook). It will route to Junk via existing `before.d/spam-to-junk.sieve`. Wait 30s, then sync and check counter:

```sh
ssh mail 'sudo /usr/bin/timeout 60 /usr/bin/docker exec --user amavis iredmail-core /usr/bin/sa-learn --sync --siteconfigpath=/etc/spamassassin'
ssh mail 'sudo docker exec iredmail-core sudo -u amavis sa-learn --dump magic | grep nspam'
```

Expected: `nspam` UNCHANGED from before. If it grew by 1, the LMTP filing fired imap_sieve — that's a feedback-loop bug, abort and investigate.

- [ ] **Step 3: Spam-learn E2E (Roundcube)**

Send a fresh non-GTUBE test mail from your laptop to a test mailbox so it lands in INBOX. From Roundcube web UI: select → "Mark as junk" button. Verify it moves to Junk. Then:

```sh
ssh mail 'sudo /usr/bin/timeout 60 /usr/bin/docker exec --user amavis iredmail-core /usr/bin/sa-learn --sync && sudo docker exec iredmail-core sudo -u amavis sa-learn --dump magic | grep nspam'
```

Expected: `nspam` +1.

- [ ] **Step 4: Spam-learn E2E (Thunderbird drag)**

Repeat Step 3 but use Thunderbird's drag-to-Junk on a different test mail. Sync. `nspam` +1 again.

- [ ] **Step 5: Ham-learn E2E**

Drag a clean message from Junk back to INBOX. Sync. `nham` should be +1:

```sh
ssh mail 'sudo /usr/bin/timeout 60 /usr/bin/docker exec --user amavis iredmail-core /usr/bin/sa-learn --sync && sudo docker exec iredmail-core sudo -u amavis sa-learn --dump magic | grep nham'
```

- [ ] **Step 6: Re-classification refusal (validates Known Limitations)**

Move the same Step 3 mail BACK to INBOX (so it goes the opposite direction). Sync. `nham` should be UNCHANGED. Check the wrapper logged the refusal:

```sh
ssh mail 'sudo tail -50 /opt/iredmail/data/iredmail-logs/maillog | grep sa-learn-pipe | tail'
```

Expected: a `mail.warning` line `sa-learn FAILED ... err=… opposite class …`. (Path may be `/var/log/iredmail/maillog` — confirm via the existing fail2ban jail config which references `/var/log/iredmail/maillog`.)

- [ ] **Step 7: Sudo policy negative — argv mismatch**

```sh
ssh mail 'sudo docker exec -u vmail iredmail-core /usr/bin/sudo -n -u amavis /usr/bin/sa-learn --foo 2>&1 | head'
```

Expected: `Sorry, user vmail is not allowed to execute …`.

- [ ] **Step 8: Sudo policy negative — env_reset enforcement**

```sh
ssh mail 'sudo docker exec -u vmail iredmail-core /usr/bin/sudo -n -E -u amavis /usr/bin/sa-learn --no-sync --spam --username=amavis --siteconfigpath=/etc/spamassassin 2>&1 | head'
```

Expected: a denial referencing env vars or a password prompt — argv is whitelisted, so the rejection has to come from `-E` being incompatible with `env_reset`.

- [ ] **Step 9: Pipe size DoS guard**

```sh
ssh mail 'sudo docker exec iredmail-core sh -c "dd if=/dev/urandom bs=1M count=20 2>/dev/null | doveadm save -u $TEST_USER Junk"' && \
  ssh mail 'sudo tail -5 /opt/iredmail/data/iredmail-logs/maillog | grep sa-learn-pipe || echo NO-TRAIN-LINE-CONFIRMED'
```

Replace `$TEST_USER` with a real test mailbox login on the server (e.g., `postmaster@kirby.rocks`). Expected: `NO-TRAIN-LINE-CONFIRMED` — the 20 MB exceeds the 10 MB sieve cap, no training fires.

- [ ] **Step 10: Persistence test (the whole reason for the bind mount)**

```sh
ssh mail 'sudo docker exec iredmail-core sudo -u amavis sa-learn --dump magic > /tmp/bayes-pre-restart.txt && cd /opt/iredmail && sudo docker compose restart iredmail-core' && \
  sleep 30 && \
  ssh mail 'sudo docker exec iredmail-core sudo -u amavis sa-learn --dump magic | diff /tmp/bayes-pre-restart.txt -'
```

Expected: zero diff — counters survived the restart.

- [ ] **Step 11: Borg inclusion test**

After the next scheduled borg run (every 4h, or trigger manually):

```sh
ssh mail 'sudo /opt/iredmail/scripts/borg-backup.sh 2>&1 | tail -10 && sudo borg list /opt/iredmail/data/borg-repo ::$(sudo borg list /opt/iredmail/data/borg-repo --short --last 1) | grep amavis-spamassassin'
```

(needs BORG_PASSPHRASE in env or via passcommand). Expected: `bayes_seen` and `bayes_toks` listed.

---

## Task 13 — Update `progress.md` + `todo.md` to reflect feature done

**Files:**
- Modify: `progress.md`
- Modify: `todo.md`

- [ ] **Step 1: Edit progress.md**

In the "Open — pick next" list, mark P1-B Phase 2 done with date + brief outcome (e.g., "spam-learning live 2026-05-XX, all 11 verification scenarios passed"). Move it to "What's SOLID" with the verification details.

- [ ] **Step 2: Edit todo.md**

Add to "Cleanup ideas" any deferred/Future-tightening items from the spec (auto_learn re-enable later, healthcheck cron for sa-learn ratio, README-DR mention).

- [ ] **Step 3: Commit + push**

```sh
cd /home/kirby/projects/github/iredadmin && git add progress.md todo.md && git commit -m "progress.md: P1-B Phase 2 spam-learning live" && git push
```

---

## Self-review

**Spec coverage:** every spec section has at least one task —
- §1 Bind mount + Bayes migration → Tasks 7, 10
- §2 Dovecot imap_sieve plugin + Sieve scripts → Tasks 4, 5, 6
- §3 sa-learn-pipe.sh wrapper + sudo policy → Tasks 1, 2, 3
- §4 Roundcube markasjunk activation → Task 8
- §5 Bayes journal sync → Task 11
- §6 Logging routes → relies on existing rsyslog (verified inline at Task 12 Step 6 by grepping maillog)
- §Error handling → exercised by Task 12 verification scenarios
- §Testing → Task 12 (1:1 mapping)
- §Migration steps → Task 10
- §Rollback → not pre-coded; documented in spec for use only if Task 10 Step 7 fails
- §Future tightening → Task 13 captures into todo.md

**Placeholder scan:** no TBD/TODO/"implement later". Each step has actual content. Step "fail-fast" markers ("ABORT condition", "investigate before proceeding") are real go/no-go gates, not placeholders.

**Type/path consistency:** verified —
- wrapper path `/usr/local/lib/dovecot/sieve-pipe/sa-learn-pipe.sh` consistent in Tasks 3, 5, 9, 10
- sudoers path `/etc/sudoers.d/sa-learn` consistent in Tasks 1, 2, 9, 10
- sieve script paths `/var/lib/dovecot/sieve/imap/learn-{spam,ham}.sieve` consistent in Tasks 4, 5, 9, 10
- bayes mount `data/amavis-spamassassin` ↔ `/var/lib/amavis/.spamassassin` consistent in Tasks 6, 7, 10, 12

No gaps found.
