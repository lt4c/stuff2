#!/usr/bin/env bash
# Direct Sunshine launcher for RDP testing - bypasses session management
# Usage: ./sunshine_direct.sh

echo "[INFO] Direct Sunshine launcher for RDP display testing"

# Detect RDP display
DETECTED_DISPLAY=":0"
for display in /tmp/.X11-unix/X*; do
    if [ -S "$display" ]; then
        display_num="${display##*/X}"
        DETECTED_DISPLAY=":${display_num}"
        echo "[INFO] Found X11 socket: $display -> $DETECTED_DISPLAY"
        break
    fi
done

export DISPLAY="$DETECTED_DISPLAY"
echo "[INFO] Using DISPLAY=$DISPLAY"

# Set minimal required environment
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_SESSION_TYPE="x11"
export XDG_CURRENT_DESKTOP="KDE"
export DESKTOP_SESSION="plasma"

# Disable all session management
export SYSTEMD_IGNORE_CHROOT=1
export NO_AT_BRIDGE=1
export DBUS_FATAL_WARNINGS=0
unset SESSION_MANAGER
unset GNOME_DESKTOP_SESSION_ID

# Create runtime dir
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true

# Set X11 permissions
X11_SOCKET="/tmp/.X11-unix/X${DETECTED_DISPLAY#:}"
if [ -S "$X11_SOCKET" ]; then
    chmod 777 "$X11_SOCKET" 2>/dev/null || true
    echo "[INFO] Set permissions on $X11_SOCKET"
fi

# Check uinput
if [ ! -w /dev/uinput ]; then
    echo "[WARN] /dev/uinput not writable, input may not work"
    echo "[INFO] Try: sudo chmod 666 /dev/uinput"
fi

# Check if Sunshine is already running
if pgrep -x sunshine >/dev/null; then
    echo "[WARN] Sunshine is already running. Stopping existing processes..."
    pkill -x sunshine
    sleep 2
fi

echo "[INFO] Starting Sunshine directly (no session management)"
echo "[INFO] Press Ctrl+C to stop"

# Start Sunshine with nohup to completely detach from terminal session
nohup /usr/bin/sunshine > /tmp/sunshine-direct.log 2>&1 &
SUNSHINE_PID=$!

echo "[INFO] Sunshine started with PID $SUNSHINE_PID"
echo "[INFO] Log file: /tmp/sunshine-direct.log"
echo "[INFO] To stop: kill $SUNSHINE_PID"
echo "[INFO] Web UI: https://localhost:47990"
echo ""

# Follow the log
echo "[INFO] Following log output (Ctrl+C to stop following, Sunshine will continue):"
tail -f /tmp/sunshine-direct.log