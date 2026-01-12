#!/bin/bash
# =============================================================================
# Postfix Custom Configuration
# This script is executed during container initialization
# =============================================================================

echo "Applying Postfix custom configuration..."

# Add any custom postconf commands here
# Example:
# postconf -e "smtp_tls_loglevel = 1"

# Message size limit (default 50MB)
postconf -e "message_size_limit = ${MESSAGE_SIZE_LIMIT:-52428800}"

# Mailbox size limit (0 = unlimited, managed by Dovecot quotas)
postconf -e "mailbox_size_limit = 0"

echo "Postfix custom configuration applied."
