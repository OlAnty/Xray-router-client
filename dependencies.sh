#!/bin/sh
# setup/dependencies.sh

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

echo ""
echo "Installing dependecies..."

set -e

FORCE=0
CHECK_ONLY=0

for arg in "$@"; do
  case $arg in
    --force)
      FORCE=1
      ;;
    --check-only)
      CHECK_ONLY=1
      ;;
  esac
  shift
done

# Check for Entware or OpenWRT package manager
if command -v opkg >/dev/null 2>&1; then
  INSTALLER="opkg"
elif command -v apt >/dev/null 2>&1; then
  INSTALLER="apt"
elif [ -x /opt/bin/opkg ]; then
  INSTALLER="/opt/bin/opkg"
else
  printf "${RED}No supported package manager found. Make sure you're on Entware/OpenWRT or Debian/Ubuntu.${NC}\n"
  exit 1
fi

check_or_install() {
  BIN_NAME="$1"
  PKG_NAME="$2"

  if ! command -v "$BIN_NAME" >/dev/null 2>&1 || [ "$FORCE" -eq 1 ]; then
    if [ "$CHECK_ONLY" -eq 1 ]; then
      echo "$BIN_NAME (required)"
    else
      echo "Installing $BIN_NAME using $INSTALLER..."
      $SUDO $INSTALLER update && $SUDO $INSTALLER install "$PKG_NAME"
    fi
  else
    echo "$BIN_NAME is installed."
  fi
}

# Base dependencies for VLESS setup
check_or_install iptables iptables
check_or_install jq jq
check_or_install dig bind-dig
check_or_install ps procps-ng
check_or_install xray xray

# Optionally
# check_or_install wget wget
# check_or_install unzip unzip

# Make init.d scripts executable if present
INIT_DIR="/opt/etc/init.d"

if [ -d "$INIT_DIR" ]; then
  INIT_SCRIPTS=$(find "$INIT_DIR" -maxdepth 1 -name 'S*' -type f)

  if [ -n "$INIT_SCRIPTS" ]; then
    echo "Marking init scripts as executable..."
    for script in $INIT_SCRIPTS; do
      $SUDO chmod +x "$script"
    done
  else
    printf "${YELLOW}No init.d scripts found to mark as executable.${NC}\n"
  fi
else
  printf "${RED}init.d directory not found at $INIT_DIR${NC}\n"
fi

# Make xray executable
if [ -f /opt/sbin/xray ]; then
  $SUDO chmod +x /opt/sbin/xray
else
  printf "${RED}/opt/sbin/xray not found — cannot set executable permission.${NC}\n"
fi

echo "✅ All dependencies are installed and scripts are configured."
echo "––––––––––––––––––––––––––––––––––––––––––––"

exit 0