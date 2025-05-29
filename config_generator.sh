#!/bin/sh
# setup/config_generator.sh

if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
else
  SUDO=""
fi

CONFIG_DIR="/opt/etc/xray"
DOMAIN_FILE="$CONFIG_DIR/custom_domains.txt"
IP_FILE="$CONFIG_DIR/custom_ips.txt"

add_domains_to_file() {
  echo ""

  if [ -f "$DOMAIN_FILE" ]; then
    echo "Choose an option:"
    echo "  1. Domain list already exists: reuse and append to existing domain list"
    echo "  2. Overwrite with new domains"
    read -p "Your choice (1 or 2): " CHOICE
    case "$CHOICE" in
      1)
        echo "📌 Appending to existing list. Press Enter to skip."
        ;;
      2)
        echo "" | $SUDO tee "$DOMAIN_FILE" >/dev/null
        echo "🆕 Overwritten $DOMAIN_FILE"
        ;;
      *)
        echo "❌ Invalid choice. Aborting."
        return 1
        ;;
    esac
  else
    $SUDO mkdir -p "$(dirname "$DOMAIN_FILE")"
    $SUDO touch "$DOMAIN_FILE"
    $SUDO chmod 644 "$DOMAIN_FILE"
    echo "🆕 Created $DOMAIN_FILE"
  fi

  echo ""
  echo "🌐 Enter domains to add (comma-separated, no www/https, e.g., youtube.com): "
  read input
  OLD_IFS="$IFS"
  IFS=','

  for domain in $(echo "$input" | sed 's/ *, */,/g'); do
    domain=$(echo "$domain" | xargs)
    if ! grep -Fxq "$domain" "$DOMAIN_FILE"; then
      echo "$domain" | $SUDO tee -a "$DOMAIN_FILE" >/dev/null
    fi
  done

  IFS="$OLD_IFS"
  echo "✅ Domains saved to $DOMAIN_FILE"
}

generate_domain_rules_from_file() {
  if [ ! -f "$DOMAIN_FILE" ]; then
    echo "❌ Domain file not found: $DOMAIN_FILE"
    return 1
  fi

  DOMAIN_RULES=""
  while read -r domain; do
    domain=$(echo "$domain" | xargs)
    [ -n "$domain" ] && DOMAIN_RULES="$DOMAIN_RULES\"domain:$domain\",\"domain:www.$domain\","
  done < "$DOMAIN_FILE"

  # Trim trailing comma
  DOMAIN_RULES=$(echo "$DOMAIN_RULES" | sed 's/,\s*$//')
  echo "$DOMAIN_RULES"
}

add_ips_to_file() {
  echo ""

  if [ -f "$IP_FILE" ]; then
    echo "Choose an option:"
    echo "  1. IP list already exists: reuse and append to existing IP list"
    echo "  2. Overwrite with new IPs"
    read -p "Your choice (1 or 2): " CHOICE
    case "$CHOICE" in
      1)
        echo "📌 Appending to existing list. Press Enter to skip."
        ;;
      2)
        echo "" | $SUDO tee "$IP_FILE" >/dev/null
        echo "🆕 Overwritten $IP_FILE"
        ;;
      *)
        echo "❌ Invalid choice. Aborting."
        return 1
        ;;
    esac
  else
    $SUDO mkdir -p "$(dirname "$IP_FILE")"
    $SUDO touch "$IP_FILE"
    $SUDO chmod 644 "$IP_FILE"
    echo "🆕 Created $IP_FILE"
  fi

  echo ""
  echo "💻 Enter IPs to add (comma-separated, e.g., 192.168.1.55,10.0.0.88): "
  read input
  OLD_IFS="$IFS"
  IFS=','

  for ip in $(echo "$input" | sed 's/ *, */,/g'); do
    ip=$(echo "$ip" | xargs)
    if echo "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
      if ! grep -Fxq "$ip" "$IP_FILE"; then
        echo "$ip" | $SUDO tee -a "$IP_FILE" >/dev/null
      fi
    else
      echo "❌ Invalid IP format: $ip"
    fi
  done

  IFS="$OLD_IFS"
  echo "✅ IPs saved to $IP_FILE"
}

generate_ip_rules_from_file() {
  if [ ! -f "$IP_FILE" ]; then
    echo "❌ IP file not found: $IP_FILE"
    return 1
  fi

  IP_LIST=""
  while read -r ip; do
    ip=$(echo "$ip" | xargs)
    [ -n "$ip" ] && IP_LIST="$IP_LIST\"$ip\","
  done < "$IP_FILE"

  IP_LIST=$(echo "$IP_LIST" | sed 's/,\s*$//')

  if [ -z "$IP_LIST" ]; then
    return 0
  fi

  cat <<EOF
    {
      "type": "field",
      "source": [
        $IP_LIST
      ],
      "outboundTag": "vless-out"
    }
EOF
}

generate_routing_block() {
  local route_all="$1"
  local domain_rules="$2"
  local ip_rules="$3"

  if [ "$route_all" = "yes" ]; then
    cat <<EOF
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
  }
EOF
  else
    local rules_json=""

    [ -n "$domain_rules" ] && rules_json="$rules_json
      {
        \"type\": \"field\",
        \"domain\": [
          $domain_rules
        ],
        \"outboundTag\": \"vless-out\"
      },"

    [ -n "$ip_rules" ] && rules_json="$rules_json
      $ip_rules,"

    rules_json="$rules_json
      {
        \"type\": \"field\",
        \"network\": \"tcp,udp\",
        \"outboundTag\": \"direct\"
      }"

    cat <<EOF
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
$rules_json
    ]
  }
EOF
  fi
}
