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
WATCHDOG_SCRIPT="$INIT_DIR/S99xray-watchdog"
FILES="xray-access.log xray-error.log"
MAX_SIZE=512000

# Ensure directories exist
$SUDO mkdir -p "$LOG_DIR"
$SUDO mkdir -p "$INIT_DIR"

# Create S99xray-loglimit
cat <<EOF | $SUDO tee "$LOG_LIMIT_SCRIPT" >/dev/null
#!/bin/sh

FILES="\$FILES"
LOG_DIR="\$LOG_DIR"
MAX_SIZE=\$MAX_SIZE

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

# Kill existing watchdog processes safely
if ps aux >/dev/null 2>&1; then
  EXISTING_PIDS=$(ps aux | grep '[/]opt/etc/init.d/S99xray-watchdog' | awk '{print $2}')
else
  EXISTING_PIDS=$(ps | grep '[S]99xray-watchdog' | awk '{print $1}')
fi

KILLED=0

for pid in \$EXISTING_PIDS; do
  if [ "\$pid" != "\$\$" ]; then
    kill "\$pid" 2>/dev/null
    echo "🧹 Killed previous watchdog process with PID: \$pid"
    KILLED=\$((KILLED+1))
  fi
done

if [ "\$KILLED" -eq 0 ]; then
  echo "ℹ️  No previous watchdog processes found."
fi

# Background loop to call the log limiter every 60 seconds
while true; do
  /opt/etc/init.d/S99xray-loglimit
  sleep 60
done &

exit 0

EOF

# Make both executable
$SUDO chmod +x "$LOG_LIMIT_SCRIPT" "$WATCHDOG_SCRIPT"

echo "✅ Created and configured: $LOG_LIMIT_SCRIPT and $WATCHDOG_SCRIPT"
echo "––––––––––––––––––––––––––––––––––––––––––––"