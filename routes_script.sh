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

is_route_all_enabled() {
  grep -q '"ip": \["0.0.0.0/0", "::/0"\]' "$CONFIG_FILE"
}

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

# Prompt for optional device IP if routing is NOT set to "all traffic"
if ! is_route_all_enabled; then
  while true; do
    read -p "Do you want to add routing for specific local device IPs (e.g., TV, console)? Type 'yes' to add, or press Enter to skip: " ADD_DEVICE_IP
    ADD_DEVICE_IP=$(echo "$ADD_DEVICE_IP" | tr '[:upper:]' '[:lower:]')

    if [ "$ADD_DEVICE_IP" = "yes" ] || [ "$ADD_DEVICE_IP" = "" ]; then
      break
    else
      echo "Please type 'yes' or press Enter."
    fi
  done

  DEVICE_IP_LIST=""
  if [ "$ADD_DEVICE_IP" = "yes" ]; then
    while true; do
      read -p "Enter one or more device IPs, separated by commas (e.g. 192.168.1.55,192.168.1.99). Press Enter to cancel: " DEVICE_IPS_RAW
      if [ -z "$DEVICE_IPS_RAW" ]; then
        echo "No IPs entered — skipping device-specific rules."
        break
      fi

      DEVICE_IPS_CLEAN=$(echo "$DEVICE_IPS_RAW" | sed 's/ *, */,/g')
      OLD_IFS="$IFS"
      IFS=','

      VALID=true
      DEVICE_IP_LIST=""
      IP_JSON_LIST=""

      for ip in $DEVICE_IPS_CLEAN; do
        CLEANED_IP=$(echo "$ip" | xargs)
        if echo "$CLEANED_IP" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
          DEVICE_IP_LIST="$DEVICE_IP_LIST$CLEANED_IP "
          IP_JSON_LIST="$IP_JSON_LIST\"$CLEANED_IP\","
        else
          printf "${YELLOW}Invalid IP format: '$CLEANED_IP'${NC}\n"
          VALID=false
          break
        fi
      done

      IFS="$OLD_IFS"

      if [ "$VALID" = true ]; then
        # Remove trailing comma from IP list for JSON
        IP_JSON_LIST=$(echo "$IP_JSON_LIST" | sed 's/,$//')

        # Create new IP rule block
        NEW_RULE="{
  \"type\": \"field\",
  \"ip\": [
    $IP_JSON_LIST
  ],
  \"outboundTag\": \"vless-out\"
},"

        # Insert IP rule into routing.rules
        awk -v new_rule="$NEW_RULE" '
        BEGIN { inserted=0 }
        /"rules": \[/ {
          print $0
          print new_rule
          inserted=1
          next
        }
        { print }
        ' "$CONFIG_FILE" | $SUDO tee "${CONFIG_FILE}.tmp" >/dev/null && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

        printf "${GREEN}Xray config updated with IP routing rules.${NC}\n"

        break
      else
        printf "${YELLOW}Please enter all IPs in a valid format.${NC}\n"
      fi
    done
  fi
fi

LAN_IFACE=$(detect_lan_interface)

# Generate route script
{
  echo '#!/bin/sh'
  echo ""
  echo "XRAY_PORT=$XRAY_PORT"
  echo ""
  echo "$SUDO iptables -t nat -N XRAY_REDIRECT 2>/dev/null"
  echo "$SUDO iptables -t nat -F XRAY_REDIRECT"
  echo ""
  echo "$SUDO iptables -t nat -A XRAY_REDIRECT -d 127.0.0.1 -j RETURN"
  echo "$SUDO iptables -t nat -A XRAY_REDIRECT -d $ROUTER_IP -j RETURN"
  echo "$SUDO iptables -t nat -A XRAY_REDIRECT -d $VPN_SERVER_IP -j RETURN"
  echo ""
  echo "$SUDO iptables -t nat -A XRAY_REDIRECT -p tcp --dport 80 -j REDIRECT --to-ports \$XRAY_PORT"
  echo "$SUDO iptables -t nat -A XRAY_REDIRECT -p tcp --dport 443 -j REDIRECT --to-ports \$XRAY_PORT"
  echo "$SUDO iptables -t nat -A XRAY_REDIRECT -p udp --dport 443 -j REDIRECT --to-ports \$XRAY_PORT"
  echo ""
  echo "$SUDO iptables -t nat -C PREROUTING -i $LAN_IFACE -p tcp -j XRAY_REDIRECT 2>/dev/null || \\"
  echo "$SUDO iptables -t nat -A PREROUTING -i $LAN_IFACE -p tcp -j XRAY_REDIRECT"
  echo ""
  echo "$SUDO iptables -t nat -C PREROUTING -i $LAN_IFACE -p udp -j XRAY_REDIRECT 2>/dev/null || \\"
  echo "$SUDO iptables -t nat -A PREROUTING -i $LAN_IFACE -p udp -j XRAY_REDIRECT"
  echo ""
} | $SUDO tee "$ROUTES_FILE" > /dev/null

$SUDO chmod +x "$ROUTES_FILE"
echo "✅ Route script created and made executable."

# Final summary
echo "Routes configuration saved to: $ROUTES_FILE"
echo "Router IP: $ROUTER_IP"
echo "VPN server IP: $VPN_SERVER_IP"
echo "LAN interface: $LAN_IFACE"
if [ -n "$DEVICE_IP_LIST" ]; then
  echo "Device IPs routed through VPN: $DEVICE_IP_LIST"
else
  echo "No device-specific IPs added."
fi
echo "––––––––––––––––––––––––––––––––––––––––––––"