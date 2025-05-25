#!/bin/sh
# setup/install_all.sh

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

CONFIG_FILE="/opt/etc/xray/vless.json"
CLIENT_FILE="/opt/etc/init.d/S99xray-client"
ROUTES_FILE="/opt/etc/init.d/S99xray-routes"
WATCHDOG_FILE="/opt/etc/init.d/S99xray-watchdog"

SETUP_DIR="$(dirname "$0")"

echo ""
echo "🔧 Running setup..."

# 1. Install dependencies
if [ -f "$SETUP_DIR/dependencies.sh" ]; then
  sh "$SETUP_DIR/dependencies.sh"
else
  printf "${RED}dependencies.sh not found${NC}\n"
  exit 1
fi

# 2. Generate VLESS config
if [ -f "$SETUP_DIR/vless_config.sh" ]; then
  sh "$SETUP_DIR/vless_config.sh"
else
  printf "${RED}vless_config.sh not found${NC}\n"
  exit 1
fi

# 3. Generate iptables routing script
if [ -f "$SETUP_DIR/routes_script.sh" ]; then
  sh "$SETUP_DIR/routes_script.sh"
else
  printf "${RED}routes_script.sh not found${NC}\n"
  exit 1
fi

# 4. Setup log monitoring
if [ -f "$SETUP_DIR/log_monitoring.sh" ]; then
  sh "$SETUP_DIR/log_monitoring.sh"
else
  printf "${RED}log_monitoring.sh not found${NC}\n"
  exit 1
fi

# 5. Setup client launcher
if [ -f "$SETUP_DIR/client_launcher.sh" ]; then
  sh "$SETUP_DIR/client_launcher.sh"
else
  printf "${RED}client_launcher.sh not found${NC}\n"
  exit 1
fi

# 6. Start services if init.d files are present
echo ""
for script in "$CLIENT_FILE" "$ROUTES_FILE" "$WATCHDOG_FILE"; do
  if [ -f "$script" ]; then
    echo "🔁 Starting $(basename "$script")..."
    case "$script" in
      "$CLIENT_FILE")
        "$script" restart
        ;;
      "$WATCHDOG_FILE")
        "$script" &
        ;;
        *)
        sh "$script"
        ;;
    esac
    sleep 1
  else
    printf "${RED}$script not found — skipping.${NC}\n"
  fi
done

echo ""
echo "––––––––––––––––––––––––––––––––––––––––––––"

# 7. Run connectivity test
if [ -f "$SETUP_DIR/connectivity_test.sh" ]; then
  sh "$SETUP_DIR/connectivity_test.sh"
else
  printf "${YELLOW}Connectivity_test.sh not found — skipping connectivity check.${NC}\n"
fi