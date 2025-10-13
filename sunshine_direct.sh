#!/usr/bin/env bash
# Direct Sunshine launcher for RDP testing - sets up permissions then runs as desktop user
# Usage: sudo ./sunshine_direct.sh

echo "[INFO] Direct Sunshine launcher for KDE Plasma streaming"

# Detect the desktop user (the user who owns the X session)
DESKTOP_USER=""
if [ -n "${SUDO_USER:-}" ]; then
    # Script was run with sudo, use the original user
    DESKTOP_USER="$SUDO_USER"
elif [ "$(id -u)" -eq 0 ]; then
    # Running as root but no SUDO_USER, try to detect desktop user
    for user in lt4c $(users | tr ' ' '\n' | sort -u); do
        if id "$user" >/dev/null 2>&1 && [ "$user" != "root" ]; then
            DESKTOP_USER="$user"
            break
        fi
    done
else
    # Not running as root, use current user
    DESKTOP_USER="$(whoami)"
fi

if [ -z "$DESKTOP_USER" ]; then
    echo "[ERROR] Cannot detect desktop user. Please run as: sudo -u lt4c $0"
    exit 1
fi

echo "[INFO] Desktop user detected: $DESKTOP_USER"
echo "[INFO] Setting up permissions as root, then switching to $DESKTOP_USER for Sunshine"

# Ensure we have root privileges for permission setup
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This script needs root privileges to set up permissions"
    echo "[ERROR] Please run: sudo $0"
    exit 1
fi

# Get desktop user's UID for environment setup
DESKTOP_UID=$(id -u "$DESKTOP_USER")
DESKTOP_GID=$(id -g "$DESKTOP_USER")

echo "[INFO] Desktop user UID: $DESKTOP_UID"

# Detect display for the desktop user
DETECTED_DISPLAY=":0"
for display in /tmp/.X11-unix/X*; do
    if [ -S "$display" ]; then
        display_num="${display##*/X}"
        DETECTED_DISPLAY=":${display_num}"
        echo "[INFO] Found X11 socket: $display -> $DETECTED_DISPLAY"
        break
    fi
done

echo "[INFO] Will stream DISPLAY=$DETECTED_DISPLAY"

# Setup environment variables for the desktop user
DESKTOP_HOME="/home/$DESKTOP_USER"
DESKTOP_XDG_RUNTIME_DIR="/run/user/$DESKTOP_UID"

# Create runtime directory for desktop user
mkdir -p "$DESKTOP_XDG_RUNTIME_DIR" 2>/dev/null || true
chown "$DESKTOP_UID:$DESKTOP_GID" "$DESKTOP_XDG_RUNTIME_DIR" 2>/dev/null || true

# Check X11 access (don't modify permissions as regular user)
X11_SOCKET="/tmp/.X11-unix/X${DETECTED_DISPLAY#:}"
if [ -S "$X11_SOCKET" ]; then
    echo "[INFO] X11 socket found: $X11_SOCKET"
    if ! xdpyinfo >/dev/null 2>&1; then
        echo "[WARN] Cannot access X11 display. You may need to run:"
        echo "       xhost +local: "
    fi
else
    echo "[WARN] X11 socket not found: $X11_SOCKET"
fi

# Setup uinput permissions for Sunshine
echo "[INFO] Setting up uinput permissions for virtual input..."

# Check if uinput module is loaded
if ! lsmod | grep -q uinput; then
    echo "[INFO] Loading uinput kernel module..."
    if ! modprobe uinput 2>/dev/null; then
        echo "[WARN] Failed to load uinput module, you may need to install kernel headers"
    fi
fi

# Create uinput device if it doesn't exist
if [ ! -e /dev/uinput ]; then
    echo "[INFO] Creating uinput device node..."
    mknod /dev/uinput c 10 223 2>/dev/null || true
fi

# Set proper permissions on uinput device
echo "[INFO] Setting uinput device permissions..."
chmod 666 /dev/uinput 2>/dev/null || echo "[WARN] Failed to set uinput permissions"

# Add desktop user to uinput group if not already a member
if ! groups "$DESKTOP_USER" | grep -q uinput; then
    echo "[INFO] Adding user $DESKTOP_USER to uinput group..."
    usermod -aG uinput "$DESKTOP_USER" 2>/dev/null || echo "[WARN] Failed to add user to uinput group"
fi

# Verify uinput access
if [ -w /dev/uinput ]; then
    echo "[INFO] uinput device permissions: OK"
else
    echo "[WARN] uinput device still not writable"
    echo "[WARN] Virtual keyboard/mouse may not work in Sunshine"
fi

# Setup additional input device permissions
echo "[INFO] Setting up additional input device permissions..."

# Add desktop user to input group for event devices
if ! groups "$DESKTOP_USER" | grep -q input; then
    echo "[INFO] Adding user $DESKTOP_USER to input group..."
    usermod -aG input "$DESKTOP_USER" 2>/dev/null || echo "[WARN] Failed to add user to input group"
fi

# Set permissions on input event devices
if ls /dev/input/event* >/dev/null 2>&1; then
    echo "[INFO] Setting permissions on input event devices..."
    chmod 664 /dev/input/event* 2>/dev/null || true
    chgrp input /dev/input/event* 2>/dev/null || true
fi

# Create udev rule for persistent uinput permissions
if [ ! -f /etc/udev/rules.d/99-sunshine-uinput.rules ]; then
    echo "[INFO] Creating persistent udev rule for uinput..."
    tee /etc/udev/rules.d/99-sunshine-uinput.rules >/dev/null <<'EOF'
# uinput device permissions for Sunshine streaming
KERNEL=="uinput", MODE="0666", GROUP="uinput", OPTIONS+="static_node=uinput"
SUBSYSTEM=="misc", KERNEL=="uinput", MODE="0666", GROUP="uinput", TAG+="uaccess"
SUBSYSTEM=="input", KERNEL=="event*", MODE="0664", GROUP="input"
EOF
    
    # Reload udev rules
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=misc --action=add 2>/dev/null || true
    echo "[INFO] Persistent udev rules created"
fi

# Verify KDE Plasma session is running
if ! pgrep -x plasmashell >/dev/null; then
    echo "[WARN] KDE Plasma (plasmashell) not detected!"
    echo "[WARN] Sunshine may only capture a black screen or terminal"
    echo "[INFO] Make sure you're running this from within a KDE Plasma session"
fi

# Test X11 display access
echo "[INFO] Testing X11 display access..."
if command -v xwininfo >/dev/null 2>&1; then
    if xwininfo -root >/dev/null 2>&1; then
        echo "[INFO] X11 display access: OK"
    else
        echo "[WARN] Cannot access X11 display"
        echo "[INFO] Try running: xhost +local:"
    fi
fi

# Check if Sunshine is already running
if pgrep -x sunshine >/dev/null; then
    echo "[WARN] Sunshine is already running. Stopping existing processes..."
    pkill -x sunshine
    sleep 2
fi

echo "[INFO] Starting Sunshine as user $DESKTOP_USER to stream KDE Plasma desktop"
echo "[INFO] This will capture the desktop session for Moonlight streaming"
echo "[INFO] Press Ctrl+C to stop following logs (Sunshine will continue running)"

# Start Sunshine as the desktop user with proper environment
su - "$DESKTOP_USER" -c "
export DISPLAY='$DETECTED_DISPLAY'
export XDG_RUNTIME_DIR='$DESKTOP_XDG_RUNTIME_DIR'
export XDG_SESSION_TYPE='x11'
export XDG_CURRENT_DESKTOP='KDE'
export DESKTOP_SESSION='plasma'
export KDE_FULL_SESSION='true'
export QT_QPA_PLATFORM='xcb'
export QT_QPA_PLATFORMTHEME='kde'
export SYSTEMD_IGNORE_CHROOT=1
export NO_AT_BRIDGE=1
export DBUS_FATAL_WARNINGS=0
nohup /usr/bin/sunshine > /tmp/sunshine-direct.log 2>&1 &
echo \$!
" > /tmp/sunshine-pid.tmp

SUNSHINE_PID=$(cat /tmp/sunshine-pid.tmp)
rm -f /tmp/sunshine-pid.tmp

echo ""
echo "=== SUNSHINE STARTED ==="
echo "PID: $SUNSHINE_PID"
echo "Log: /tmp/sunshine-direct.log"
echo "Web UI: https://localhost:47990"
echo "To stop: kill $SUNSHINE_PID"
echo ""
echo "=== MOONLIGHT SETUP ==="
echo "1. Open Moonlight on your client device"
echo "2. Add PC manually with this IP"
echo "3. Use the Web UI above to pair devices"
echo "4. You should see KDE Plasma desktop (not terminal)"
echo ""

# Wait a moment for Sunshine to start
sleep 3

# Check if Sunshine started successfully
if ! kill -0 $SUNSHINE_PID 2>/dev/null; then
    echo "[ERROR] Sunshine failed to start! Check the log:"
    cat /tmp/sunshine-direct.log
    exit 1
fi

echo "[INFO] Sunshine is running successfully!"
echo "[INFO] Following log output..."
echo "========================"

# Follow the log
tail -f /tmp/sunshine-direct.log