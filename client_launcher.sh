#!/bin/sh
# setup/client_launcher.sh

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

CLIENT_SCRIPT="/opt/etc/init.d/S99xray-client"
CONFIG_FILE="/opt/etc/xray/vless.json"

echo ""
echo "🛠️ Creating Xray client launcher..."

# Ensure the target directory exists
mkdir -p /opt/etc/init.d

# Generate the init.d launcher
cat <<EOF | $SUDO tee "$CLIENT_SCRIPT" >/dev/null
#!/bin/sh
### BEGIN INIT INFO
# Provides: xray-client
# Short-Description: Start Xray client using vless.json configuration
### END INIT INFO
echo "🛠️ Creating Xray client launcher as UID: \$(id -u)"

CONFIG_FILE="$CONFIG_FILE"
XRAY_BIN="/opt/sbin/xray"

start() {
  echo "Starting Xray client..."
  if pgrep -f "\$XRAY_BIN -config \$CONFIG_FILE" >/dev/null; then
    echo "⚠️ Xray is already running. Use restart if needed."
    return
  fi
  \$XRAY_BIN -config "\$CONFIG_FILE" &
}

stop() {
  echo "Trying to stop Xray client..."
  PID=\$(pgrep -f "\$XRAY_BIN -config \$CONFIG_FILE")
  if [ -n "\$PID" ]; then
    $SUDO kill "\$PID"
    echo "Xray client stopped (PID \$PID)."
  else
    echo "Xray client is not running."
  fi
}


restart() {
  echo "🔄 Restarting Xray client..."
  stop
  sleep 1
  start
}

case "\$1" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  restart|"")
    restart
    ;;
  *)
    echo "Usage: \$0 {start|stop|restart}"
    exit 1
    ;;
esac
EOF

# Make it executable
$SUDO chmod +x "$CLIENT_SCRIPT"

echo "✅ Xray client launcher created and made executable: $CLIENT_SCRIPT"
echo "––––––––––––––––––––––––––––––––––––––––––––"
