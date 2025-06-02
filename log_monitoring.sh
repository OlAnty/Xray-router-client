#!/bin/sh
# setup/log_monitoring.sh

if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
else
  SUDO=""
fi

echo ""
echo "Configuring log monitoring..."

set -e

LOG_DIR="/opt/var/log"
INIT_DIR="/opt/etc/init.d"
LOG_LIMIT_SCRIPT="$INIT_DIR/S99xray-loglimit"
ROUTES_SCRIPT="$INIT_DIR/S99xray-routes"
WATCHDOG_SCRIPT="$INIT_DIR/S99xray-watchdog"
FILES="xray-access.log xray-error.log"
MAX_SIZE=512000

# Ensure directories exist
$SUDO mkdir -p "$LOG_DIR"
$SUDO mkdir -p "$INIT_DIR"

# Create S99xray-loglimit
cat <<EOF | $SUDO tee "$LOG_LIMIT_SCRIPT" >/dev/null
#!/bin/sh

FILES="$FILES"
LOG_DIR="$LOG_DIR"
MAX_SIZE=$MAX_SIZE

for FILE in \$FILES; do
  FULL_PATH="\$LOG_DIR/\$FILE"
  if [ -f "\$FULL_PATH" ]; then
    SIZE=\$(du -b "\$FULL_PATH" | cut -f1)
    if [ "\$SIZE" -gt "\$MAX_SIZE" ]; then
      echo "🔁 Truncating \$FILE (too big)..."
      : > "\$FULL_PATH"
    fi
  fi
done
EOF

# Create S99xray-watchdog
cat <<EOF | $SUDO tee "$WATCHDOG_SCRIPT" > /dev/null
#!/bin/sh

LOG_LIMIT_SCRIPT="$LOG_LIMIT_SCRIPT"
SUDO="$SUDO"

if ps aux >/dev/null 2>&1; then
  EXISTING_PIDS=\$(ps aux | grep '[/]opt/etc/init.d/S99xray-watchdog' | grep -v '^USER' | awk '{print \$2}' | grep '^[0-9]\+$')
else
  EXISTING_PIDS=\$(ps | grep '[S]99xray-watchdog' | awk '{print \$1}' | grep '^[0-9]\+$')
fi

for pid in \$EXISTING_PIDS; do
  if [ "\$pid" != "\$\$" ]; then
    \$SUDO kill "\$pid" 2>/dev/null
    echo "🧹 Killed previous watchdog process with PID: \$pid"
  fi
done

# Background loop to call the log limiter every 60 seconds
  while true; do
    \$LOG_LIMIT_SCRIPT

      # Check if any PREROUTING rule points to XRAY_REDIRECT
    if ! iptables -t nat -S PREROUTING | grep -q 'XRAY_REDIRECT'; then
      logger -t xray-watchdog "⚠️ PREROUTING rules missing — restoring now"
      echo "\$(date) — restoring PREROUTING rules" >> /opt/var/log/xray-prerouting-resets.log
      \$ROUTES_SCRIPT start
    fi

    sleep 60
  done

EOF

# Make both executable
$SUDO chmod +x "$LOG_LIMIT_SCRIPT" "$WATCHDOG_SCRIPT"

echo "✅ Created and configured:"
echo "$LOG_LIMIT_SCRIPT"
echo "$WATCHDOG_SCRIPT"
echo "––––––––––––––––––––––––––––––––––––––––––––"