#!/bin/sh
# setup/connectivity_test.sh
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

. "$(dirname "$SCRIPT_PATH")/utils.sh"

if [ -t 1 ]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; NC=''
fi

echo "🧪 Running connectivity test as UID: $(id -u)..."

if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
else
  SUDO=""
fi

CONFIG_FILE="/opt/etc/xray/vless.json"
XRAY_LOG="/opt/var/log/xray-error.log"
TARGET_DOMAIN="example.org"

# === GENERAL CONNECTIVITY CHECK ===
echo ""
echo "🌐 Testing general internet connectivity via https://www.google.com..."
GOOGLE_STATUS=$(curl -4 -s -o /dev/null -w "%{http_code}" https://www.google.com)
if [ "$GOOGLE_STATUS" = "200" ]; then
  echo "Internet connectivity is working. Google returned 200."
else
  printf "${RED}Google test failed. HTTP status: $GOOGLE_STATUS — possible DNS or tunnel issue.${NC}\n"
fi

# === TEMPORARY REDIRECTION FOR LOCAL TESTING ===
echo ""
echo "Temporarily routing the router's own traffic through Xray for test..."

$SUDO iptables -t nat -N XRAY_REDIRECT 2>/dev/null || true

# Add rules to avoid loop and redirect all tcp to dokodemo-door
$SUDO iptables -t nat -C OUTPUT -p tcp --dport 443 -j RETURN 2>/dev/null || \
$SUDO iptables -t nat -A OUTPUT -p tcp --dport 443 -j RETURN

$SUDO iptables -t nat -C OUTPUT -p tcp -j REDIRECT --to-ports 1081 2>/dev/null || \
$SUDO iptables -t nat -A OUTPUT -p tcp -d $TARGET_DOMAIN -j REDIRECT --to-ports 1081

# === CLEANUP FUNCTION ===
cleanup() {
  remove_output_redirect
}
trap cleanup EXIT

# === CLEAR LOGS & SHOW IPTABLES ===
echo ""
echo "Truncating Xray logs before test..."
$SUDO truncate -s 0 /opt/var/log/xray-access.log 2>/dev/null
$SUDO truncate -s 0 /opt/var/log/xray-error.log 2>/dev/null

echo ""
echo "Checking iptables OUTPUT and PREROUTING rules before test..."
echo "--- OUTPUT chain:"
$SUDO iptables -t nat -L OUTPUT -n --line-numbers | grep -E "XRAY_REDIRECT|RETURN|1081" || echo "(none)"
echo "Raw rule:"
$SUDO iptables-save -t nat | grep --color=auto -E '^-A OUTPUT' || echo "(none)"

echo "--- PREROUTING chain:"
$SUDO iptables -t nat -L PREROUTING -n --line-numbers | grep -E "XRAY_REDIRECT" || echo "(none)"
echo "Raw rule:"
$SUDO iptables-save -t nat | grep --color=auto -E '^-A PREROUTING' | grep XRAY_REDIRECT || echo "(none)"

# Ensure dig is available
if ! command -v dig >/dev/null 2>&1; then
  printf "${RED}'dig' command not found. Please install 'dnsutils' or 'bind-dig'.${NC}\n"
  exit 1
fi

sleep 1

# === CONNECTIVITY TEST ===

echo ""
echo "🌐 Testing routed domain: $TARGET_DOMAIN"
echo "Resolving IP and checking connectivity..."

RESOLVED_IP=$(dig +short "$TARGET_DOMAIN" | head -n1)
RESPONSE=$(curl -4 -s -L -o /dev/null -w "%{http_code}" "https://$TARGET_DOMAIN")

echo "Resolved domain IP: $RESOLVED_IP"
echo "HTTP Status from $TARGET_DOMAIN: $RESPONSE"

if [ "$RESPONSE" = "200" ]; then
  echo "Traffic to $TARGET_DOMAIN succeeded."

  sleep 1

  ROUTED_LOG=$(grep -A5 "$TARGET_DOMAIN" "$XRAY_LOG" | grep -E "taking detour|default route|\btunneling request\b" | tail -n 2)

  if echo "$ROUTED_LOG" | grep -q "vless-out"; then
    printf "${GREEN}✅ Routing confirmed via 'vless-out':${NC}\n"
    echo "$ROUTED_LOG"
    VPN_IP=$(echo "$ROUTED_LOG" | grep "tunneling request" | awk '{print $NF}')
    if [ -n "$VPN_IP" ]; then
      CLEANED_VPN_IP=$(echo "$VPN_IP" | sed 's|/tcp:||')
      printf "${GREEN}✅ VPN server IP used: %s${NC}\n" "$CLEANED_VPN_IP"
    fi
  else
    printf "${YELLOW}Could not confirm routing via Xray client for $TARGET_DOMAIN.${NC}\n"
    echo "Check logs:"
    tail -n 10 "$XRAY_LOG"
  fi
else
  printf "${RED}Unexpected response from $TARGET_DOMAIN. Please check routing/IPTables/Xray config.${NC}\n"
fi
