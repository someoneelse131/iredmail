require ["fileinto", "imap4flags"];

# amavis sets X-Spam-Flag: YES when SpamAssassin score >= sa_tag2_level_deflt.
# Deliver into Junk and pre-mark as Seen so spam doesn't trigger "new mail"
# notifications. User can still find it in Junk.
if header :is "X-Spam-Flag" "YES" {
  setflag "\\Seen";
  fileinto "Junk";
  stop;
}
