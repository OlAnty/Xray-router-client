#!/bin/sh
# setup/vless_config.sh

if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
else
  SUDO=""
fi

set -e

CONFIG_DIR="/opt/etc/xray"
CONFIG_FILE="$CONFIG_DIR/vless.json"

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
  read -p "🌐 Enter domains to route via VPN (e.g., youtube.com, comma-separated, no www/https): " DOMAINS_RAW

  CLEAN_DOMAINS=""
  OLD_IFS="$IFS"
  IFS=','

  for domain in $(echo "$DOMAINS_RAW" | sed 's/ *, */,/g'); do
    domain=$(echo "$domain" | xargs)
    CLEAN_DOMAINS="$CLEAN_DOMAINS \"domain:$domain\",\"domain:www.$domain\","
  done

  IFS="$OLD_IFS"

  # Remove trailing comma
  DOMAIN_RULES=$(echo "$CLEAN_DOMAINS" | sed 's/,\s*$//')
fi

# Create config directory
$SUDO mkdir -p "$CONFIG_DIR"

# Build routing rules
if [ "$ROUTE_ALL" = "yes" ]; then
  ROUTING_BLOCK='
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": [
          "0.0.0.0/0",
          "::/0"
        ],
        "outboundTag": "vless-out"
      }
    ]
  }'
else
  ROUTING_BLOCK=$(cat <<EOF
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "domain": [
          $DOMAIN_RULES
        ],
        "outboundTag": "vless-out"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "direct"
      }
    ]
  }
EOF
)
fi

# Generate config file
# cat <<EOF > "$CONFIG_FILE"
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
  echo "🌐 Routing: Only selected domains:"
  DOMAINS_RAW=$(echo "$DOMAINS_RAW" | sed 's/ *, */,/g' | tr ',' ' ')
  for domain in $DOMAINS_RAW; do
    domain=$(echo "$domain" | xargs)
    echo "    - $domain"
    echo "    - www.$domain"
  done
fi
echo ""
echo "You can edit this config manually: $CONFIG_FILE"
echo "––––––––––––––––––––––––––––––––––––––––––––"