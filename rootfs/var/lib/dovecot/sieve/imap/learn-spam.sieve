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
