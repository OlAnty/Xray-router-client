#!/bin/sh
# setup/vless_config.sh

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

. "$(dirname "$SCRIPT_PATH")/config_generator.sh"

if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
else
  SUDO=""
fi

set -e

CONFIG_DIR="/opt/etc/xray"
CONFIG_FILE="$CONFIG_DIR/vless.json"

$SUDO mkdir -p "$CONFIG_DIR"

echo ""
echo "📦 Setting up VLESS + Reality configuration..."

# Prompt user for input
read -p "Enter VPN server IP or domain (e.g., 1.2.3.4 or yourdomain.com): " VPN_ADDR
read -p "Enter VPN server port [leave empty for 443]: " VPN_PORT
read -p "Enter your UUID: " UUID
read -p "Enter public key (from server): " PUB_KEY
read -p "Enter short ID (hex string): " SHORT_ID
read -p "Enter server name (e.g., domain used for Reality): " SERVER_NAME

while true; do
  echo "What traffic do you want to route via Xray proxy?"
  echo "  1. All traffic"
  echo "  2. Only traffic to specific domains."
  read -p "Enter your choice (1 or 2): " CHOICE

  case "$CHOICE" in
    1)
      ROUTE_ALL="yes"
      break
      ;;
    2)
      ROUTE_ALL="no"
      break
      ;;
    *)
      echo "Invalid input. Please enter 1 or 2."
      ;;
  esac
done

VPN_PORT=${VPN_PORT:-443}
ROUTE_ALL=$(echo "$ROUTE_ALL" | tr '[:upper:]' '[:lower:]')

DOMAIN_RULES=""
if [ "$ROUTE_ALL" != "yes" ]; then
  add_domains_to_file
  DOMAIN_RULES=$(generate_domain_rules_from_file)
fi

IP_RULES=""
if [ "$ROUTE_ALL" != "yes" ]; then
  echo ""
  while true; do
    echo "💡 Do you want to add specific device IPs (e.g., smart TVs, consoles) to route via VPN?"
    echo "  1. Yes"
    echo "  2. No (skip)"
    read -p "Enter your choice (1 or 2): " IP_CHOICE

    case "$IP_CHOICE" in
      1)
        add_ips_to_file
        IP_RULES=$(generate_ip_rules_from_file)
        break
        ;;
      2)
        echo "📛 Skipping device-specific IP routing."
        break
        ;;
      *)
        echo "Invalid choice. Please enter 1 or 2."
        ;;
    esac
  done
fi

# Build routing rules
ROUTING_BLOCK=$(generate_routing_block "$ROUTE_ALL" "$DOMAIN_RULES" "$IP_RULES")

# Generate config file
cat <<EOF | $SUDO tee "$CONFIG_FILE" >/dev/null
{
  "log": {
    "loglevel": "info",
    "access": "/opt/var/log/xray-access.log",
    "error": "/opt/var/log/xray-error.log"
  },
  "inbounds": [
    {
      "port": 1081,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "tag": "vless-out",
      "settings": {
        "vnext": [
          {
            "address": "$VPN_ADDR",
            "port": $VPN_PORT,
            "users": [
              {
                "id": "$UUID",
                "encryption": "none",
                "flow": "xtls-rprx-vision"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "$SERVER_NAME",
          "publicKey": "$PUB_KEY",
          "shortId": "$SHORT_ID",
          "fingerprint": "chrome"
        }
      }
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ],
$ROUTING_BLOCK
}
EOF

# Final summary
echo ""
echo "✅ VLESS configuration:"
echo "🔁 Inbound:"
echo "    - Protocol: dokodemo-door"
echo "    - Port: 1081"
echo "📤 Outbound:"
echo "    - Protocol: vless"
echo "    - Remote: $VPN_ADDR:$VPN_PORT"
echo "    - Security: reality"
echo "    - Fingerprint: chrome"
echo "    - Public key: $PUB_KEY"
echo "    - Short ID: $SHORT_ID"
if [ "$ROUTE_ALL" = "yes" ]; then
  echo "🌐 Routing: All traffic via VPN"
else
  echo "🌐 Routing only selected domains:"
  while read -r domain; do
    domain=$(echo "$domain" | xargs)
    [ -n "$domain" ] && echo "    - $domain" && echo "    - www.$domain"
  done < "$DOMAIN_FILE"
fi
if [ -n "$IP_RULES" ]; then
  echo "💻 Device IPs routed via VPN:"
  while read -r ip; do
    ip=$(echo "$ip" | xargs)
    [ -n "$ip" ] && echo "    - $ip"
  done < "$IP_FILE"
fi
echo ""
echo "You can edit this config manually: $CONFIG_FILE"
echo "––––––––––––––––––––––––––––––––––––––––––––"