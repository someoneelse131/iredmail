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
