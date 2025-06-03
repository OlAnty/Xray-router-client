#!/bin/sh
# setup/routes_script.sh
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

. "$(dirname "$SCRIPT_PATH")/utils.sh"

if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
else
  SUDO=""
fi

if [ -t 1 ]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; NC=''
fi

ROUTES_FILE="/opt/etc/init.d/S99xray-routes"
CONFIG_FILE="/opt/etc/xray/vless.json"
XRAY_PORT=1081

echo ""
echo "🛠️ Generating iptables routing script at $ROUTES_FILE..."

# Extract VPN server IP from config if available
VPN_SERVER_IP=""
if [ -f "$CONFIG_FILE" ]; then
  VPN_SERVER_IP=$(grep -oE '"address": *"[^"]+"' "$CONFIG_FILE" | head -n1 | cut -d'"' -f4)
fi

if [ -z "$VPN_SERVER_IP" ]; then
  read -p "🌐 Enter your VPN server IP (to bypass in routing): " VPN_SERVER_IP
fi

# Try to detect router local IP (default gateway)
ROUTER_IP=$(ip route | awk '/default/ {print $3}' | head -n1)
if [ -z "$ROUTER_IP" ]; then
  read -p "Unable to auto-detect router IP. Enter router IP (e.g. 192.168.1.1): " ROUTER_IP
fi

LAN_IFACE=$(detect_lan_interface)

# Generate route script
{
  echo '#!/bin/sh'
  echo 'echo "Applying PREROUTING rules..."'
  echo ""
  echo 'case "$1" in'
  echo '  start|"")'
  echo "    XRAY_PORT=$XRAY_PORT"
  echo ""
  echo "    $SUDO iptables -t nat -N XRAY_REDIRECT 2>/dev/null"
  echo "    $SUDO iptables -t nat -F XRAY_REDIRECT"
  echo ""
  echo "    $SUDO iptables -t nat -A XRAY_REDIRECT -d 127.0.0.1 -j RETURN"
  echo "    $SUDO iptables -t nat -A XRAY_REDIRECT -d $ROUTER_IP -j RETURN"
  echo "    $SUDO iptables -t nat -A XRAY_REDIRECT -d $VPN_SERVER_IP -j RETURN"
  echo ""
  echo "    $SUDO iptables -t nat -A XRAY_REDIRECT -p tcp --dport 80 -j REDIRECT --to-ports \$XRAY_PORT"
  echo "    $SUDO iptables -t nat -A XRAY_REDIRECT -p tcp --dport 443 -j REDIRECT --to-ports \$XRAY_PORT"
  echo "    $SUDO iptables -t nat -A XRAY_REDIRECT -p udp --dport 443 -j REDIRECT --to-ports \$XRAY_PORT"
  echo ""
  echo "    $SUDO iptables -t nat -C PREROUTING -i $LAN_IFACE -p tcp -j XRAY_REDIRECT 2>/dev/null || \\"
  echo "    $SUDO iptables -t nat -A PREROUTING -i $LAN_IFACE -p tcp -j XRAY_REDIRECT"
  echo ""
  echo "    $SUDO iptables -t nat -C PREROUTING -i $LAN_IFACE -p udp -j XRAY_REDIRECT 2>/dev/null || \\"
  echo "    $SUDO iptables -t nat -A PREROUTING -i $LAN_IFACE -p udp -j XRAY_REDIRECT"
  echo "    ;;"
  echo "esac"
  echo ""
  echo 'echo "PREROUTING rules are all set"'
} | $SUDO tee "$ROUTES_FILE" > /dev/null

$SUDO chmod +x "$ROUTES_FILE"
echo "✅ Route script created and made executable."

# Final summary
echo "Routes configuration saved to: $ROUTES_FILE"
echo "Router IP: $ROUTER_IP"
echo "VPN server IP: $VPN_SERVER_IP"
echo "LAN interface: $LAN_IFACE"
echo "––––––––––––––––––––––––––––––––––––––––––––"