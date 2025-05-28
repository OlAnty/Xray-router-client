#!/bin/sh
# setup/generate_ips.sh

if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
else
  SUDO=""
fi

CONFIG_DIR="/opt/etc/xray"
IP_FILE="$CONFIG_DIR/custom_ips.txt"

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

  cat <<EOF
{
  "type": "field",
  "ip": [
    $IP_LIST
  ],
  "outboundTag": "vless-out"
}
EOF
}
