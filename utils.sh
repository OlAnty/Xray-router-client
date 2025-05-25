if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
else
  SUDO=""
fi

detect_lan_interface() {
  if command -v ip >/dev/null 2>&1; then
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
  fi

  echo "No private LAN interface found. Falling back to br0." >&2
  echo "br0"
}

detect_xray_uid() {
  XRAY_PID=$(pgrep -f '/opt/sbin/xray')
  if [ -n "$XRAY_PID" ] && [ -f "/proc/$XRAY_PID/status" ]; then
    awk '/Uid:/ {print $2}' /proc/"$XRAY_PID"/status
  fi
}

detect_local_ip() {
  if command -v ip >/dev/null 2>&1; then
    ip addr show | awk '/inet / && $2 !~ /^127/ {split($2,a,"/"); print a[1]; exit}'
  elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig | awk '/inet addr:/{print substr($2,6); exit}'
  else
    echo "127.0.0.1"
  fi
}

detect_router() {
  if grep -qi 'debian\|ubuntu\|fedora\|arch\|alpine' /etc/*release 2>/dev/null || \
     [ -f /etc/debian_version ] || [ -f /etc/redhat-release ]; then
    echo "false"
  else
    echo "true"
  fi
}

cleanup_scripts() {
  echo "🧹 Removing configuration files and stopping related processes..."

  # Kill xray processes
  if ps aux >/dev/null 2>&1; then
    XRAY_PIDS=$(ps aux | grep '[o]pt/sbin/xray' | grep -v 'watchdog' | awk '{print $2}')
  else
    XRAY_PIDS=$(ps | grep '[x]ray' | grep -v 'watchdog' | awk '{print $1}')
  fi

  for PID in $XRAY_PIDS; do
    [ "$PID" != "$$" ] && $SUDO kill "$PID" 2>/dev/null && echo "🔻 Killed xray process: $PID"
  done

  # Kill watchdog processes
  if ps aux >/dev/null 2>&1; then
    WD_PIDS=$(ps aux | grep '[/]opt/etc/init.d/S99xray-watchdog' | awk '{print $2}')
  else
    WD_PIDS=$(ps | grep '[S]99xray-watchdog' | awk '{print $1}')
  fi

  for PID in $WD_PIDS; do
    [ "$PID" != "$$" ] && $SUDO kill "$PID" 2>/dev/null && echo "🔻 Killed watchdog process: $PID"
  done

  # Remove config files and scripts
  $SUDO rm -f "$CLIENT_SCRIPT" "$WATCHDOG_SCRIPT" "$ROUTES_SCRIPT" "$CONFIG_FILE"
}

remove_prerouting_redirect() {
  LAN_IFACE=$(detect_lan_interface)

  echo "Removing PREROUTING XRAY_REDIRECT rules..."
  $SUDO iptables -t nat -F XRAY_REDIRECT 2>/dev/null
  $SUDO iptables -t nat -X XRAY_REDIRECT 2>/dev/null

  $SUDO iptables -t nat -D PREROUTING -j XRAY_REDIRECT 2>/dev/null
  $SUDO iptables -t nat -D PREROUTING -p tcp -j XRAY_REDIRECT 2>/dev/null
  $SUDO iptables -t nat -D PREROUTING -p udp -j XRAY_REDIRECT 2>/dev/null
  $SUDO iptables -t nat -D PREROUTING -i "$LAN_IFACE" -p tcp -j XRAY_REDIRECT 2>/dev/null
  $SUDO iptables -t nat -D PREROUTING -i "$LAN_IFACE" -p udp -j XRAY_REDIRECT 2>/dev/null

  # Specific device IPs cleanup
  $SUDO iptables-save -t nat | grep '^-A PREROUTING -s .* -j XRAY_REDIRECT' | while read -r rule; do
    delete_rule=$(echo "$rule" | sed 's/^-A /-D /')
    $SUDO iptables -t nat $delete_rule 2>/dev/null
  done
}

remove_output_redirect() {
  XRAY_UID=$(detect_xray_uid)
  if [ -z "$XRAY_UID" ]; then
    printf "${RED}Failed to detect Xray UID. Is the client installed?${NC}\n"
    pause
    return
  fi
  LOCAL_IP=$(detect_local_ip)

  echo "Removing OUTPUT redirect rules..."
  $SUDO iptables -t nat -D OUTPUT -p tcp -m owner ! --uid-owner "$XRAY_UID" -j XRAY_REDIRECT 2>/dev/null
  $SUDO iptables -t nat -D OUTPUT -p tcp -j XRAY_REDIRECT 2>/dev/null
  $SUDO iptables -t nat -D OUTPUT -p tcp --dport 22 -j RETURN 2>/dev/null
  $SUDO iptables -t nat -D OUTPUT -p tcp --dport 222 -j RETURN 2>/dev/null
  $SUDO iptables -t nat -D XRAY_REDIRECT -d "$LOCAL_IP" -j RETURN 2>/dev/null
}