#!/bin/sh
# xray-proxy-admin.sh — must be run from the same folder where other setup scripts are located.

CONFIG_FILE="/opt/etc/xray/vless.json"
CLIENT_SCRIPT="/opt/etc/init.d/S99xray-client"
ROUTES_SCRIPT="/opt/etc/init.d/S99xray-routes"
WATCHDOG_SCRIPT="/opt/etc/init.d/S99xray-watchdog"
ACCESS_LOG="/opt/var/log/xray-access.log"
ERROR_LOG="/opt/var/log/xray-error.log"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# Colors
GREEN="\033[0;32m"
RED="\033[0;31m"
CYAN="\033[0;36m"
YELLOW="\033[1;33m"
NC="\033[0m"

if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
else
  SUDO=""
fi

header() {
  printf "\n${CYAN}======== XRAY PROXY ADMIN MENU ========${NC}\n"
}

pause() {
  printf "\nPress Enter to continue..."
  read dummy
}

ensure_admin_in_path() {
  if [ -f /opt/etc/init.d/rc.unslung ] || grep -qi 'entware' /proc/version; then
    TARGET_DIR="/opt/bin"
  else
    TARGET_DIR="/usr/local/bin"
  fi

  TARGET="$TARGET_DIR/xray-proxy-admin"
  ORIGIN="$(realpath "$0" 2>/dev/null || readlink -f "$0")"

  # Avoid overwrite if identical
  if [ -L "$TARGET" ] && [ "$(readlink "$TARGET")" = "$ORIGIN" ]; then
    return
  fi

  if [ -w "$TARGET_DIR" ]; then
    ln -sf "$ORIGIN" "$TARGET"
    chmod +x "$ORIGIN"
    printf "${GREEN}Installed 'xray-proxy-admin' as a symlink to $ORIGIN. You can now run it from anywhere.${NC}\n"
  else
    printf "${RED}Failed to create symlink to 'xray-proxy-admin'. Cannot write to $TARGET_DIR.${NC}\n"
  fi

  pause
}

install_menu() {
  if [ -f "$CLIENT_SCRIPT" ] && [ -f "$CONFIG_FILE" ]; then
    IS_INSTALLED=1
  else
    IS_INSTALLED=0
  fi

  printf "\n${YELLOW}Installation menu:${NC}\n"
  if [ "$IS_INSTALLED" -eq 0 ]; then
    printf "1) Install Xray\n"
  else
    printf "1) Reinstall Xray\n"
  fi
  printf "2) Uninstall Xray\n"
  printf "0) Back\n"
  printf "Choose an option: "
  read instopt

  case "$instopt" in
    1)
      printf "${YELLOW}Running install_all.sh...${NC}\n"
      sh "$SCRIPT_DIR/install_all.sh"
      pause
      ;;
    2)
      printf "${RED}Uninstalling Xray and cleaning up...${NC}\n"

      if ! command -v iptables >/dev/null 2>&1; then
        printf "${RED}'iptables' is required but not found. Please install it first.${NC}\n"
        exit 1
      fi
      
      XRAY_UID=$(detect_xray_uid)
      if [ -z "$XRAY_UID" ]; then
        printf "${RED}Failed to detect Xray UID. Is the client installed?${NC}\n"
        pause
        return
      fi
      LOCAL_IP=$(hostname -I | awk '{print $1}')
      LAN_IFACE=$(detect_lan_interface)
      echo "LAN interface used: $LAN_IFACE"

      echo "Removing configuration files..."
      $SUDO pkill -f /opt/sbin/xray
      $SUDO pkill -f "$WATCHDOG_SCRIPT"
      $SUDO rm -f "$CLIENT_SCRIPT" "$WATCHDOG_SCRIPT" "$ROUTES_SCRIPT"
      $SUDO rm -f "$CONFIG_FILE"

      echo "Updating iptables..."
      $SUDO iptables -t nat -F XRAY_REDIRECT 2>/dev/null
      $SUDO iptables -t nat -X XRAY_REDIRECT 2>/dev/null

      # General PREROUTING cleanup
      $SUDO iptables -t nat -D PREROUTING -j XRAY_REDIRECT 2>/dev/null
      $SUDO iptables -t nat -D PREROUTING -p tcp -j XRAY_REDIRECT 2>/dev/null
      $SUDO iptables -t nat -D PREROUTING -p udp -j XRAY_REDIRECT 2>/dev/null

      # Interface-specific PREROUTING rules
      $SUDO iptables -t nat -D PREROUTING -i "$LAN_IFACE" -p tcp -j XRAY_REDIRECT 2>/dev/null
      $SUDO iptables -t nat -D PREROUTING -i "$LAN_IFACE" -p udp -j XRAY_REDIRECT 2>/dev/null

      # OUTPUT redirect cleanup
      $SUDO iptables -t nat -D OUTPUT -p tcp -m owner ! --uid-owner "$XRAY_UID" -j XRAY_REDIRECT 2>/dev/null
      $SUDO iptables -t nat -D OUTPUT -p tcp -j XRAY_REDIRECT 2>/dev/null
      $SUDO iptables -t nat -D OUTPUT -p tcp --dport 22 -j RETURN 2>/dev/null
      $SUDO iptables -t nat -D OUTPUT -p tcp --dport 222 -j RETURN 2>/dev/null
      $SUDO iptables -t nat -D XRAY_REDIRECT -d "$LOCAL_IP" -j RETURN 2>/dev/null

      # Delete all PREROUTING rules that send specific IPs to XRAY_REDIRECT
      $SUDO iptables-save -t nat | grep '^-A PREROUTING -s .* -j XRAY_REDIRECT' | while read -r rule; do
        delete_rule=$(echo "$rule" | sed 's/^-A /-D /')
        $SUDO iptables -t nat $delete_rule 2>/dev/null
      done

      printf "${GREEN}✅ Uninstallation complete.${NC}\n"
      pause
      ;;
    0) return ;;
    *) printf "${RED}Invalid option.${NC}\n"; pause ;;
  esac
}

manage_config() {
  while true; do
    printf "${YELLOW}\nManage VLESS Configuration:${NC}\n"
    printf "1) Regenerate config\n"
    printf "2) Edit routing rules\n"
    printf "3) Show current config\n"
    printf "0) Back\n"
    printf "Choose an option: "
    read confopt
    case "$confopt" in
      1) sh "$SCRIPT_DIR/vless_config.sh" ;;
      2) edit_routing_rules ;;
      3) show_vless_config ;;
      0) return ;;
      *) printf "${RED}Invalid option.${NC}\n" ;;
    esac
  done
}

edit_routing_rules() {
  if [ ! -f "$CONFIG_FILE" ]; then
    printf "${RED}Config not found. Please generate it first.${NC}\n"
    pause
    return
  fi

  printf "${CYAN}\nRouting Rule Editor:${NC}\n"
  printf "1) Route all traffic\n"
  printf "2) Edit specific domains\n"
  printf "0) Back\n"
  read routeopt
  case "$routeopt" in
    1)
      printf "${YELLOW}This will overwrite all domain-based rules and route ALL traffic through the VPN.${NC}\n"
      printf "Type '${CYAN}yes${NC}' to proceed: "
      read confirm
      if [ "$confirm" != "yes" ]; then
        printf "${CYAN}Action cancelled. No changes were made.${NC}\n"
        pause
        return
      fi

      awk '
      BEGIN { skip=0; depth=0 }
      /"rules": \[/ {
        print "    \"rules\": [\n      {\n        \"type\": \"field\",\n        \"ip\": [\"0.0.0.0/0\", \"::/0\"],\n        \"outboundTag\": \"vless-out\"\n      }\n    ]";
        skip=1
        depth=1
        next
      }
      skip {
        depth += gsub(/\[/, "[")
        depth -= gsub(/\]/, "]")
        if (depth <= 0) {
          skip=0
        }
        next
      }
      { print }
      ' "$CONFIG_FILE" | $SUDO tee "${CONFIG_FILE}.tmp" >/dev/null && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

      printf "${GREEN}Routing changed: all traffic will go through the VPN.${NC}\n"
      ;;
    2)
      printf "${YELLOW}This will replace all existing routing rules with the new domain list.${NC}\n"
      printf "Type '${CYAN}yes${NC}' to proceed: "
      read confirm
      if [ "$confirm" != "yes" ]; then
        printf "${CYAN}Action cancelled. No changes were made.${NC}\n"
        pause
        return
      fi

      current_domains=$(grep -o '"domain:[^"]*"' "$CONFIG_FILE" | cut -d: -f2 | tr -d '"' | sort -u)
      if [ -n "$current_domains" ]; then
        printf "${GREEN}Current domains routed via VPN:${NC}\n"
        echo "$current_domains" | sed 's/^/ - /'
      else
        printf "${YELLOW}No domains found. Starting fresh.${NC}\n"
      fi

      printf "\nEnter new comma-separated domains (e.g., youtube.com,instagram.com): "
      read new_domains

      CLEAN_DOMAINS=""
      IFS=","
      for domain in $new_domains; do
        domain=$(echo "$domain" | sed 's/^ *//;s/ *$//')
        CLEAN_DOMAINS="$CLEAN_DOMAINS\n          \"domain:$domain\",\n          \"domain:www.$domain\","
      done
      unset IFS

      CLEAN_DOMAINS=$(echo "$CLEAN_DOMAINS" | sed '$ s/,$//')

      awk -v rules="$CLEAN_DOMAINS" '
      BEGIN { skip=0; depth=0 }
      /"rules": \[/ {
        print "    \"rules\": [\n      {\n        \"type\": \"field\",\n        \"domain\": [" rules "\n        ],\n        \"outboundTag\": \"vless-out\"\n      },\n      {\n        \"type\": \"field\",\n        \"network\": \"tcp,udp\",\n        \"outboundTag\": \"direct\"\n      }\n    ]";
        skip=1
        depth=1
        next
      }
      skip {
        # Track depth of brackets to detect end of rules block
        depth += gsub(/\[/, "[")
        depth -= gsub(/\]/, "]")
        if (depth <= 0) {
          skip=0
        }
        next
      }
      { print }
      ' "$CONFIG_FILE" | $SUDO tee "${CONFIG_FILE}.tmp" >/dev/null && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"


      printf "${GREEN}Domain routing updated successfully.${NC}\n"
      ;;
    0)
      return
      ;;
    *)
      printf "${RED}Invalid option.${NC}\n"
      ;;
  esac
  pause
}

show_vless_config() {
  if [ -f "$CONFIG_FILE" ]; then
    printf "${GREEN}VLESS config:${NC} $CONFIG_FILE\n"
    if command -v less >/dev/null 2>&1; then
      printf "${CYAN}(Press 'q' to exit viewer)${NC}\n"
      sleep 2
      less "$CONFIG_FILE"
    else
      cat "$CONFIG_FILE"
    fi
  else
    printf "${RED}VLESS config not found.${NC}\n"
  fi
  pause
}

manage_prerouting() {
  printf "${YELLOW}PREROUTING management:${NC}\n"
  printf "1) Add rules\n2) Remove rules\n3) Show current\n0) Back\n"
  read prerule
  case "$prerule" in
    1) 
      if [ -f "$ROUTES_SCRIPT" ]; then
        sh "$ROUTES_SCRIPT"
      else
        printf "${RED}Routes script not found at $ROUTES_SCRIPT.${NC}\n"
      fi
      ;;
    2)
      LAN_IFACE=$(detect_lan_interface)
      echo "LAN interface used: $LAN_IFACE"
      echo "Updating iptables..."
      $SUDO iptables -t nat -F XRAY_REDIRECT 2>/dev/null
      $SUDO iptables -t nat -X XRAY_REDIRECT 2>/dev/null

      # General PREROUTING cleanup
      $SUDO iptables -t nat -D PREROUTING -j XRAY_REDIRECT 2>/dev/null
      $SUDO iptables -t nat -D PREROUTING -p tcp -j XRAY_REDIRECT 2>/dev/null
      $SUDO iptables -t nat -D PREROUTING -p udp -j XRAY_REDIRECT 2>/dev/null

      # Interface-specific PREROUTING rules
      $SUDO iptables -t nat -D PREROUTING -i "$LAN_IFACE" -p tcp -j XRAY_REDIRECT 2>/dev/null
      $SUDO iptables -t nat -D PREROUTING -i "$LAN_IFACE" -p udp -j XRAY_REDIRECT 2>/dev/null

      # Delete all PREROUTING rules that send specific IPs to XRAY_REDIRECT
      $SUDO iptables-save -t nat | grep '^-A PREROUTING -s .* -j XRAY_REDIRECT' | while read -r rule; do
        delete_rule=$(echo "$rule" | sed 's/^-A /-D /')
        $SUDO iptables -t nat $delete_rule 2>/dev/null
      done
      printf "${GREEN}All PREROUTING rules related to XRAY_REDIRECT removed.${NC}\n"
      ;;
    3)
      echo ""

      echo "--- OUTPUT chain:"
      $SUDO iptables -t nat -L OUTPUT -n --line-numbers | grep -E "XRAY_REDIRECT|RETURN" || echo "(none)"
      echo "Raw rule:"
      $SUDO iptables-save -t nat | grep --color=auto -E '^-A OUTPUT' || echo "(none)"
      echo "--- PREROUTING chain:"
      $SUDO iptables -t nat -L PREROUTING -n --line-numbers | grep -E "XRAY_REDIRECT" || echo "(none)"
      echo "Raw rule:"
      $SUDO iptables-save -t nat | grep --color=auto -E '^-A PREROUTING' | grep XRAY_REDIRECT || echo "(none)"
      ;;
    0) return ;;
    *) printf "${RED}Invalid option.${NC}\n" ;;
  esac
  pause
}

manage_xray() {
  printf "${YELLOW}Manage Xray:${NC}\n"
  printf "1) Start Xray\n"
  printf "2) Stop Xray\n"
  printf "3) Restart Xray\n"
  printf "0) Back\n"
  read xopt
  case "$xopt" in
    1)
      if [ -f "$CLIENT_SCRIPT" ]; then
        "$CLIENT_SCRIPT" start
      else
        printf "${RED}Client script not found.${NC}\n"
      fi
      ;;
    2)
      if [ -f "$CLIENT_SCRIPT" ]; then
        "$CLIENT_SCRIPT" stop
      else
        printf "${RED}Client script not found.${NC}\n"
      fi
      ;;
    3)
      if [ -f "$CLIENT_SCRIPT" ]; then
        "$CLIENT_SCRIPT" restart
      else
        printf "${RED}Client script not found.${NC}\n"
      fi
      ;;
    0) return ;;
    *) printf "${RED}Invalid option.${NC}\n" ;;
  esac
  pause
}

manage_watchdog() {
  printf "${YELLOW}Watchdog management:${NC}\n"
  printf "1) Start\n2) Stop\n3) Show config\n0) Back\n"
  read wopt
  case "$wopt" in
    1) 
      if [ -f "$WATCHDOG_SCRIPT" ]; then
        sh "$WATCHDOG_SCRIPT" &
      else
        printf "${RED}Watchdog script not found at $WATCHDOG_SCRIPT.${NC}\n"
      fi
      ;;
    2)
      PIDS=$(ps | grep '[S]99xray-watchdog' | awk '{print $1}')
      if [ -n "$PIDS" ]; then
        for pid in $PIDS; do
          kill "$pid" 2>/dev/null
        done
        printf "${GREEN}Watchdog stopped.${NC}\n"
      else
        printf "${RED}Watchdog not running.${NC}\n"
      fi
      ;;
#      pkill -f "$WATCHDOG_SCRIPT" && printf "${GREEN}Watchdog stopped.${NC}\n" || printf "${RED}Watchdog not running.${NC}\n";;
    3) grep -Ev '^#|^$' "$WATCHDOG_SCRIPT" 2>/dev/null || printf "${RED}No config found.${NC}\n" ;;
    0) return ;;
    *) printf "${RED}Invalid option.${NC}\n" ;;
  esac
  pause
}

status_report() {
  printf "${YELLOW}Status report:${NC}\n"
  
  if pgrep -f /opt/sbin/xray >/dev/null; then
    printf "🟢 Xray: ${GREEN}Running${NC}\n"
  else
    printf "🔴 Xray: ${RED}Not running${NC}\n"
  fi

  if $SUDO iptables -t nat -L PREROUTING | grep -q XRAY_REDIRECT; then
    printf "🟢 PREROUTING: ${GREEN}Exists${NC}\n"
  else
    printf "🔴 PREROUTING: ${RED}Missing${NC}\n"
  fi

  if pgrep -f "$WATCHDOG_SCRIPT" >/dev/null; then
    printf "🟢 Watchdog: ${GREEN}Running${NC}\n"
  else
    printf "🔴 Watchdog: ${RED}Not running${NC}\n"
  fi

  printf "\n${CYAN}Xray-related processes:${NC}\n"
  if ps aux >/dev/null 2>&1; then
    ps aux | grep xray | grep -v grep
  else
    ps | grep xray | grep -v grep
  fi


  pause
}

manage_output_redirect() {
  printf "${YELLOW}OUTPUT redirect:${NC}\n"
  printf "1) Add\n2) Remove\n3) Show current\n0) Back\n"
  read outopt
  case "$outopt" in
    1)
      XRAY_UID=$(detect_xray_uid)
      if [ -z "$XRAY_UID" ]; then
        printf "${RED}Failed to detect Xray UID. Is the client installed?${NC}\n"
        pause
        return
      fi
      $SUDO iptables -t nat -C OUTPUT -p tcp -m owner ! --uid-owner "$XRAY_UID" -j XRAY_REDIRECT 2>/dev/null ||
      $SUDO iptables -t nat -A OUTPUT -p tcp -m owner ! --uid-owner "$XRAY_UID" -j XRAY_REDIRECT
      printf "${GREEN}OUTPUT redirect added for UID $XRAY_UID.${NC}\n"
      ;;
    2)
      XRAY_UID=$(detect_xray_uid)
      if [ -z "$XRAY_UID" ]; then
        printf "${RED}Failed to detect Xray UID. Is the client installed?${NC}\n"
        pause
        return
      fi
      $SUDO iptables -t nat -D OUTPUT -p tcp -m owner ! --uid-owner "$XRAY_UID" -j XRAY_REDIRECT 2>/dev/null
      $SUDO iptables -t nat -D OUTPUT -p tcp -j XRAY_REDIRECT 2>/dev/null
      $SUDO iptables -t nat -D OUTPUT -p tcp --dport 22 -j RETURN 2>/dev/null
      $SUDO iptables -t nat -D OUTPUT -p tcp --dport 222 -j RETURN 2>/dev/null
      $SUDO iptables -t nat -D XRAY_REDIRECT -d "$LOCAL_IP" -j RETURN 2>/dev/null
      printf "${GREEN}Redirect removed.${NC}\n"
      ;;
    3) $SUDO iptables -t nat -L OUTPUT ;;
    0) return ;;
    *) printf "${RED}Invalid option.${NC}\n" ;;
  esac
  pause
}

run_connectivity_test() {
  if [ ! -f "/opt/sbin/xray" ] || [ ! -f "$CONFIG_FILE" ]; then
    printf "${RED}Failed to detect Xray UID. Is the client running?${NC}\n"
    return
  fi
  if [ ! -f "$SCRIPT_DIR/connectivity_test.sh" ]; then
    echo "Script directory: $SCRIPT_DIR"
    printf "${RED}connectivity_test.sh not found.${NC}\n"
    pause
    return
  fi

  if [ "$(uname)" = "Linux" ] && [ "$(id -u)" = "0" ]; then
    echo "Available users:"
    i=1
    cut -d: -f1 /etc/passwd | grep -vE '^(root|nobody|daemon|bin)$' | while read user; do
      printf "  %2d) %s\n" "$i" "$user"
      i=$((i + 1))
    done
    printf "${CYAN}Enter a USER NAME to run test as (or press Enter to use root):${NC}\n "
    read user_choice

    if [ -n "$user_choice" ]; then
      if id "$user_choice" >/dev/null 2>&1; then
        sudo -u "$user_choice" sh "$SCRIPT_DIR/connectivity_test.sh"
      else
        printf "${RED}User not found.${NC}\n"
      fi
    else
      sh "$SCRIPT_DIR/connectivity_test.sh"
    fi
  else
    # On Entware or non-root environment, just run directly
    sh "$SCRIPT_DIR/connectivity_test.sh"
  fi

  pause
}

show_logs() {
  printf "${YELLOW}Log viewer:${NC}\n"
  printf "1) Access Log\n2) Error Log\n"
  read -r logopt
  case "$logopt" in
    1) tail -n 50 "$ACCESS_LOG" ;;
    2) tail -n 50 "$ERROR_LOG" ;;
    *) printf "${RED}Invalid choice.${NC}\n" ;;
  esac
  pause
}

detect_lan_interface() {
  if command -v ifconfig >/dev/null 2>&1; then
    IFACES=$(ifconfig | grep '^[a-zA-Z0-9]' | awk '{print $1}')
    for iface in $IFACES; do
      case "$iface" in
        lo|*ppp*|*wwan*|*wan*|*usb*) continue ;;
      esac
      if ifconfig "$iface" | grep -qE 'inet addr:(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01]))'; then
        echo "$iface"
        return 0
      fi
    done
  elif command -v ip >/dev/null 2>&1; then
    IFACES=$(ip link | awk -F: '/^[0-9]+: / {print $2}' | tr -d ' ')
    for iface in $IFACES; do
      case "$iface" in
        lo|*ppp*|*wwan*|*wan*|*usb*) continue ;;
      esac
      if ip a show "$iface" | grep -qE 'inet (192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01]))'; then
        echo "$iface"
        return 0
      fi
    done
  fi

  printf "${YELLOW}No private LAN interface found. Falling back to br0.${NC}\n" >&2
  echo "br0"
}

detect_xray_uid() {
  XRAY_PID=$(pgrep -f '/opt/sbin/xray')
  if [ -n "$XRAY_PID" ] && [ -f "/proc/$XRAY_PID/status" ]; then
    awk '/Uid:/ {print $2}' /proc/"$XRAY_PID"/status
  else
    return 1
  fi
}

main_menu() {
  header
  printf "1) Installation\n"
  printf "2) Show status\n"
  printf "3) Manage VLESS config\n"
  printf "4) Manage PREROUTING rules\n"
  printf "5) Manage Xray\n"
  printf "6) Manage Watchdog\n"
  printf "7) Manage OUTPUT redirect\n"
  printf "8) Run connectivity test\n"
  printf "9) View logs\n"
  printf "0) Exit\n"
}

ensure_admin_in_path

while true; do
  main_menu
  printf "Choose an option: "
  read choice
  case "$choice" in
    1) install_menu ;;
    2) status_report ;;
    3) manage_config ;;
    4) manage_prerouting ;;
    5) manage_xray ;;
    6) manage_watchdog ;;
    7) manage_output_redirect ;;
    8) run_connectivity_test ;;
    9) show_logs ;;
    0) printf "Bye!\n" && exit 0 ;;
    *) printf "${RED}Invalid choice.${NC}\n" && pause ;;
  esac
done
