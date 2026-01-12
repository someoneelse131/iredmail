#!/bin/bash
# =============================================================================
# iRedMail Health Check Script
# =============================================================================

set -e

check_service() {
    local name="$1"
    local check="$2"

    if eval "$check" > /dev/null 2>&1; then
        echo "[OK] $name"
        return 0
    else
        echo "[FAIL] $name"
        return 1
    fi
}

errors=0

# Check Postfix
if ! check_service "Postfix" "postfix status"; then
    errors=$((errors + 1))
fi

# Check Dovecot
if ! check_service "Dovecot" "doveadm who -c 1"; then
    errors=$((errors + 1))
fi

# Check Nginx
if ! check_service "Nginx" "nginx -t"; then
    errors=$((errors + 1))
fi

# Check PHP-FPM
if ! check_service "PHP-FPM" "pgrep php-fpm"; then
    errors=$((errors + 1))
fi

# Check SMTP port
if ! check_service "SMTP (25)" "nc -z localhost 25"; then
    errors=$((errors + 1))
fi

# Check IMAP port
if ! check_service "IMAP (143)" "nc -z localhost 143"; then
    errors=$((errors + 1))
fi

# Check HTTPS port
if ! check_service "HTTPS (443)" "nc -z localhost 443"; then
    errors=$((errors + 1))
fi

# Check database connection
if ! check_service "Database" "mysql -h db -u vmail -p\"${VMAIL_DB_PASSWORD}\" -e 'SELECT 1' vmail"; then
    errors=$((errors + 1))
fi

if [ $errors -gt 0 ]; then
    echo ""
    echo "Health check failed with $errors error(s)"
    exit 1
fi

echo ""
echo "All health checks passed!"
exit 0
