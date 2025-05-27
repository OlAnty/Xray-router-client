#!/bin/sh
# setup/generate_domains.sh

if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
else
  SUDO=""
fi

CONFIG_DIR="/opt/etc/xray"
DOMAIN_FILE="$CONFIG_DIR/custom_domains.txt"

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
