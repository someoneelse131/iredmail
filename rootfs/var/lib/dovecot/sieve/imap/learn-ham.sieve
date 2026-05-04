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
