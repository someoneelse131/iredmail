#!/bin/bash
# =============================================================================
# iRedMail Firewall Setup Script
# Configures UFW rules for all required mail server ports
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "iRedMail Firewall Setup"
echo "=========================================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root (use sudo)${NC}"
    exit 1
fi

# Check if ufw is installed
if ! command -v ufw &> /dev/null; then
    echo -e "${YELLOW}UFW not found. Installing...${NC}"
    apt-get update && apt-get install -y ufw
fi

# Define required ports
declare -A PORTS=(
    ["22"]="SSH"
    ["25"]="SMTP (mail server to server)"
    ["80"]="HTTP (webmail/admin)"
    ["443"]="HTTPS (webmail/admin)"
    ["587"]="Submission (authenticated mail)"
    ["465"]="SMTPS (secure submission)"
    ["143"]="IMAP"
    ["993"]="IMAPS (secure IMAP)"
    ["4190"]="ManageSieve"
)

# Optional ports (disabled by default in this setup)
# ["110"]="POP3"
# ["995"]="POP3S"

echo ""
echo "Checking and configuring firewall rules..."
echo ""

# Function to check if a port rule exists
port_exists() {
    local port=$1
    ufw status | grep -qE "^${port}[/ ].*ALLOW" 2>/dev/null
}

# Enable UFW if not already enabled
if ufw status | grep -q "Status: inactive"; then
    echo -e "${YELLOW}Enabling UFW...${NC}"
    # Set default policies
    ufw default deny incoming
    ufw default allow outgoing
    # Enable UFW (non-interactive)
    echo "y" | ufw enable
    echo -e "${GREEN}UFW enabled${NC}"
fi

# Add rules for each port
CHANGES_MADE=0
for port in "${!PORTS[@]}"; do
    description="${PORTS[$port]}"
    if port_exists "$port"; then
        echo -e "  [${GREEN}OK${NC}] Port $port ($description) - already allowed"
    else
        echo -e "  [${YELLOW}ADDING${NC}] Port $port ($description)"
        ufw allow "$port/tcp" comment "$description"
        CHANGES_MADE=1
    fi
done

echo ""

if [ $CHANGES_MADE -eq 1 ]; then
    echo -e "${GREEN}Firewall rules updated successfully!${NC}"
else
    echo -e "${GREEN}All firewall rules already in place.${NC}"
fi

echo ""
echo "Current UFW status:"
echo "==================="
ufw status verbose

echo ""
echo -e "${YELLOW}Note: Remember to request IONOS (or your VPS provider) to unblock${NC}"
echo -e "${YELLOW}outbound port 25 if you want to send mail directly.${NC}"
echo ""
