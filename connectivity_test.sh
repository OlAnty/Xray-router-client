#!/bin/sh
# setup/connectivity_test.sh

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

# Determine if running NOT under Entware / OpenWRT
IS_ROUTER=true
if grep -qi 'debian\|ubuntu\|fedora\|arch\|alpine' /etc/*release 2>/dev/null || \
   [ -f /etc/debian_version ] || [ -f /etc/redhat-release ]; then
  IS_ROUTER=false
fi

CONFIG_FILE="/opt/etc/xray/vless.json"
XRAY_LOG="/opt/var/log/xray-error.log"

# === TEMPORARY REDIRECTION FOR LOCAL TESTING ===
echo "Temporarily routing the router's own traffic through Xray for test..."

# Skip SSH ports to avoid disconnect
$SUDO iptables -t nat -C OUTPUT -p tcp --dport 22 -j RETURN 2>/dev/null || \
$SUDO iptables -t nat -I OUTPUT -p tcp --dport 22 -j RETURN

$SUDO iptables -t nat -C OUTPUT -p tcp --dport 222 -j RETURN 2>/dev/null || \
$SUDO iptables -t nat -I OUTPUT -p tcp --dport 222 -j RETURN

# Detect host machine IP (for test on Debian)
if command -v ip >/dev/null 2>&1; then
  LOCAL_IP=$(ip addr show | awk '/inet / && $2 !~ /^127/ {split($2,a,"/"); print a[1]; exit}')
else
  LOCAL_IP=$(ifconfig | awk '/inet addr:/{print substr($2,6); exit}')
fi

$SUDO iptables -t nat -C XRAY_REDIRECT -d "$LOCAL_IP" -j RETURN 2>/dev/null || \
$SUDO iptables -t nat -A XRAY_REDIRECT -d "$LOCAL_IP" -j RETURN

# Add OUTPUT redirect — only exclude Xray if its UID is different from root
XRAY_PID=$(pgrep -f '/opt/sbin/xray')
if [ -n "$XRAY_PID" ]; then
  XRAY_UID=$(awk '/Uid:/ {print $2}' /proc/"$XRAY_PID"/status)
else
  XRAY_UID=0
fi
XRAY_USER=$(id -nu "$XRAY_UID" 2>/dev/null || echo "unknown")
CALLER_UID=$(id -u)
if [ -z "$XRAY_UID" ]; then
  printf "${RED}Failed to detect Xray UID. Is the client running?${NC}\n"
  exit 1
fi

if [ "$IS_ROUTER" = true ]; then
  # Detected router-like system — routing all OUTPUT traffic through XRAY_REDIRECT
  echo "Detected Entware/OpenWRT environment."
  $SUDO iptables -t nat -C OUTPUT -p tcp -j XRAY_REDIRECT 2>/dev/null || \
  $SUDO iptables -t nat -A OUTPUT -p tcp -j XRAY_REDIRECT
else
  # Detected non-router system — using UID exclusion to avoid loop
  echo "Detected standard Linux system."
  $SUDO iptables -t nat -C OUTPUT -p tcp -m owner ! --uid-owner "$XRAY_UID" -j XRAY_REDIRECT 2>/dev/null || \
  $SUDO iptables -t nat -A OUTPUT -p tcp -m owner ! --uid-owner "$XRAY_UID" -j XRAY_REDIRECT
fi

sleep 1

if [ "$XRAY_UID" -eq "$CALLER_UID" ]; then
  printf "${YELLOW}Xray and connectivity test run under the same user: $XRAY_USER, UID $CALLER_UID.${NC}\n"
  printf "${YELLOW}Traffic will not be redirected through Xray to avoid the inifinite loop. You won't see logs.${NC}\n"
  sleep 1
fi

# === CLEAR LOGS & SHOW IPTABLES ===
echo ""
echo "Truncating Xray logs before test..."
$SUDO truncate -s 0 /opt/var/log/xray-access.log 2>/dev/null
$SUDO truncate -s 0 /opt/var/log/xray-error.log 2>/dev/null

echo ""
echo "Checking iptables OUTPUT and PREROUTING rules before test..."
echo "--- OUTPUT chain:"
$SUDO iptables -t nat -L OUTPUT -n --line-numbers | grep -E "XRAY_REDIRECT|RETURN" || echo "(none)"
echo "Raw rule:" 
$SUDO iptables-save -t nat | grep --color=auto -E '^-A OUTPUT' || echo "(none)"

echo "--- PREROUTING chain:"
$SUDO iptables -t nat -L PREROUTING -n --line-numbers | grep -E "XRAY_REDIRECT" || echo "(none)"
echo "Raw rule:" 
$SUDO iptables-save -t nat | grep --color=auto -E '^-A PREROUTING' | grep XRAY_REDIRECT || echo "(none)"


# Extract first routed domain from config
FIRST_DOMAIN=$(grep -oE '"domain:[^"]+"' "$CONFIG_FILE" | head -n1 | cut -d':' -f2 | tr -d '"')

# Ensure dig is available
if ! command -v dig >/dev/null 2>&1; then
  printf "${RED}'dig' command not found. Please install 'dnsutils' or 'bind-dig'.${NC}\n"
  exit 1
fi

sleep 1

# === CONNECTIVITY TEST ===
TARGET_DOMAIN="$FIRST_DOMAIN"
IS_FULL_VPN=false

if [ -z "$TARGET_DOMAIN" ]; then
  TARGET_DOMAIN="www.google.com"
  IS_FULL_VPN=true
  echo "No routed domains found — assuming full VPN mode"
fi

echo ""
echo "🌐 Testing general internet connectivity via https://www.google.com..."
GOOGLE_STATUS=$(curl -4 -s -o /dev/null -w "%{http_code}" https://www.google.com)
if [ "$GOOGLE_STATUS" = "200" ]; then
  echo "Internet connectivity is working. Google returned 200."
else
  printf "${RED}Google test failed. HTTP status: $GOOGLE_STATUS — possible DNS or tunnel issue.${NC}\n"
fi

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
      printf "${GREEN}✅ VPN server IP used: %s${NC}" "$CLEANED_VPN_IP"
    fi
  else
    printf "${YELLOW}Could not confirm routing via Xray client for $TARGET_DOMAIN.${NC}\n"
    printf "${YELLOW}Try running the connectivity_test.sh separately with a different user than $XRAY_USER, UID $XRAY_UID.${NC}\n"
    echo "Check logs:"
    tail -n 10 "$XRAY_LOG"
  fi
else
  printf "${RED}Unexpected response from $TARGET_DOMAIN. Please check routing/IPTables/Xray config.${NC}\n"
fi

# === CLEANUP ===
cleanup() {
  echo ""
  echo "Cleaning up temporary routing rules..."

  $SUDO iptables -t nat -D OUTPUT -p tcp -m owner ! --uid-owner "$XRAY_UID" -j XRAY_REDIRECT 2>/dev/null
  $SUDO iptables -t nat -D OUTPUT -p tcp -j XRAY_REDIRECT 2>/dev/null
  $SUDO iptables -t nat -D OUTPUT -p tcp --dport 22 -j RETURN 2>/dev/null
  $SUDO iptables -t nat -D OUTPUT -p tcp --dport 222 -j RETURN 2>/dev/null
  $SUDO iptables -t nat -D XRAY_REDIRECT -d "$LOCAL_IP" -j RETURN 2>/dev/null
}
trap cleanup EXIT