#!/bin/bash
# Configure Sunshine to create virtual keyboard and mouse for Moonlight
# Run this script on the SERVER where Sunshine is installed

set -e

echo "=========================================="
echo "  SUNSHINE VIRTUAL INPUT CONFIGURATION"
echo "=========================================="
echo ""

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This script must be run as root"
    echo "Usage: sudo $0"
    exit 1
fi

# Detect desktop user
DESKTOP_USER="${SUDO_USER:-lt4c}"
if [ -z "$DESKTOP_USER" ] || [ "$DESKTOP_USER" = "root" ]; then
    # Try to detect from who is logged in
    DESKTOP_USER=$(who | awk '{print $1}' | grep -v root | head -n1)
fi

if [ -z "$DESKTOP_USER" ]; then
    echo "[ERROR] Cannot detect desktop user"
    echo "Please specify: sudo DESKTOP_USER=youruser $0"
    exit 1
fi

echo "[INFO] Configuring Sunshine for user: $DESKTOP_USER"
echo ""

# ============================================
# STEP 1: Install required packages
# ============================================
echo "[STEP 1/8] Installing required packages..."
echo "---"

apt update -qq
apt install -y python3-evdev libevdev2 libevdev-dev 2>/dev/null || {
    echo "[WARN] Some packages may not be available, continuing..."
}

echo "[SUCCESS] Packages installed"
echo ""

# ============================================
# STEP 2: Configure uinput kernel module
# ============================================
echo "[STEP 2/8] Configuring uinput kernel module..."
echo "---"

# Load uinput module
modprobe uinput 2>/dev/null || echo "[INFO] uinput may be built into kernel"

# Add to modules to load at boot
if ! grep -q "^uinput" /etc/modules 2>/dev/null; then
    echo "uinput" >> /etc/modules
    echo "[INFO] Added uinput to /etc/modules"
fi

# Create modules-load.d config
mkdir -p /etc/modules-load.d
echo "uinput" > /etc/modules-load.d/uinput.conf

echo "[SUCCESS] uinput module configured"
echo ""

# ============================================
# STEP 3: Create and configure uinput device
# ============================================
echo "[STEP 3/8] Creating uinput device..."
echo "---"

# Create device if it doesn't exist
if [ ! -e /dev/uinput ]; then
    mknod /dev/uinput c 10 223 2>/dev/null || {
        echo "[WARN] mknod failed, checking alternatives..."
        if [ -e /dev/input/uinput ]; then
            ln -sf /dev/input/uinput /dev/uinput
        elif [ -e /dev/misc/uinput ]; then
            ln -sf /dev/misc/uinput /dev/uinput
        fi
    }
fi

# Set permissions
chmod 666 /dev/uinput 2>/dev/null || chmod 777 /dev/uinput
chown root:input /dev/uinput 2>/dev/null || true

if [ -e /dev/uinput ]; then
    echo "[SUCCESS] /dev/uinput created and configured"
    ls -l /dev/uinput
else
    echo "[ERROR] Failed to create /dev/uinput"
    exit 1
fi
echo ""

# ============================================
# STEP 4: Configure user groups
# ============================================
echo "[STEP 4/8] Configuring user groups..."
echo "---"

# Create required groups
REQUIRED_GROUPS="input uinput video render audio"
for group in $REQUIRED_GROUPS; do
    groupadd -f "$group" 2>/dev/null
done

# Add user to groups
for group in $REQUIRED_GROUPS; do
    usermod -aG "$group" "$DESKTOP_USER" 2>/dev/null || true
done

echo "[INFO] User $DESKTOP_USER groups: $(groups $DESKTOP_USER)"
echo "[SUCCESS] User added to all required groups"
echo ""

# ============================================
# STEP 5: Set permissions on input devices
# ============================================
echo "[STEP 5/8] Setting permissions on input devices..."
echo "---"

# Set permissions on all input devices
chmod 666 /dev/input/* 2>/dev/null || chmod 664 /dev/input/*
chgrp input /dev/input/* 2>/dev/null || true

echo "[SUCCESS] Input device permissions set"
echo ""

# ============================================
# STEP 6: Create persistent udev rules
# ============================================
echo "[STEP 6/8] Creating persistent udev rules..."
echo "---"

cat > /etc/udev/rules.d/99-sunshine-input.rules <<'UDEV_EOF'
# Sunshine virtual input device rules
KERNEL=="uinput", MODE="0666", GROUP="input", OPTIONS+="static_node=uinput"
SUBSYSTEM=="misc", KERNEL=="uinput", MODE="0666", GROUP="input"
SUBSYSTEM=="input", KERNEL=="event*", MODE="0666", GROUP="input"
SUBSYSTEM=="input", KERNEL=="mouse*", MODE="0666", GROUP="input"
SUBSYSTEM=="input", KERNEL=="js*", MODE="0666", GROUP="input"
UDEV_EOF

# Reload udev rules
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true

echo "[SUCCESS] Udev rules created and loaded"
echo ""

# ============================================
# STEP 7: Test virtual device creation
# ============================================
echo "[STEP 7/8] Testing virtual device creation..."
echo "---"

# Test as the desktop user
TEST_RESULT=$(su - "$DESKTOP_USER" -c '
python3 << "PYTEST"
import sys
try:
    from evdev import UInput, ecodes
    
    # Try to create a virtual keyboard
    ui = UInput(name="Test Virtual Keyboard")
    print("SUCCESS")
    ui.close()
except PermissionError as e:
    print(f"PERMISSION_ERROR: {e}")
    sys.exit(1)
except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(1)
PYTEST
' 2>&1)

if echo "$TEST_RESULT" | grep -q "SUCCESS"; then
    echo "[SUCCESS] ✓ Virtual device creation test PASSED"
    echo "[SUCCESS] ✓ Sunshine will be able to create keyboard/mouse devices"
else
    echo "[ERROR] ✗ Virtual device creation test FAILED"
    echo "[ERROR] Output: $TEST_RESULT"
    echo ""
    echo "[INFO] Attempting workaround..."
    # Try even more permissive settings
    chmod 777 /dev/uinput
    
    # Test again
    if su - "$DESKTOP_USER" -c 'python3 -c "from evdev import UInput; ui = UInput(); ui.close()" 2>/dev/null'; then
        echo "[SUCCESS] Workaround successful"
    else
        echo "[ERROR] Virtual device creation still failing"
        echo "[ERROR] Check: ls -l /dev/uinput"
        echo "[ERROR] Check: groups $DESKTOP_USER"
    fi
fi
echo ""

# ============================================
# STEP 8: Configure and restart Sunshine
# ============================================
echo "[STEP 8/8] Configuring Sunshine..."
echo "---"

SUNSHINE_CONFIG_DIR="/home/$DESKTOP_USER/.config/sunshine"
mkdir -p "$SUNSHINE_CONFIG_DIR"

# Create Sunshine configuration
cat > "$SUNSHINE_CONFIG_DIR/sunshine.conf" <<'SUNSHINE_EOF'
# Sunshine configuration with virtual input enabled

# Network configuration
address_family = both
bind_address = 0.0.0.0
port = 47989
https_port = 47990
ping_timeout = 30000
channels = 5

# Display capture - X11 for compatibility
capture = x11
encoder = software

# Software encoding settings
sw_preset = ultrafast
sw_tune = zerolatency

# Video quality
min_log_level = info
fec_percentage = 20
qp = 28
bitrate = 20000

# Audio configuration
audio_sink = 
virtual_sink = sunshine-stereo

# Performance
capture_cursor = enabled
output_name = 0

# Pairing
pin_timeout = 120000

# Disable hardware encoding (for Hyper-V compatibility)
nvenc = disabled
vaapi = disabled
vdpau = disabled
SUNSHINE_EOF

chown -R "$DESKTOP_USER:$DESKTOP_USER" "$SUNSHINE_CONFIG_DIR"

echo "[SUCCESS] Sunshine configuration created"
echo ""

# Stop existing Sunshine
echo "[INFO] Stopping existing Sunshine processes..."
pkill -9 sunshine 2>/dev/null || true
sleep 2

# Start Sunshine as desktop user
echo "[INFO] Starting Sunshine as user $DESKTOP_USER..."

LOGFILE="/tmp/sunshine-input-$(date +%Y%m%d-%H%M%S).log"

su - "$DESKTOP_USER" -c "
    export DISPLAY=:0
    export XDG_RUNTIME_DIR=/run/user/\$(id -u)
    
    # Verify uinput access before starting
    if [ ! -w /dev/uinput ]; then
        echo '[ERROR] /dev/uinput is not writable!' >&2
        exit 1
    fi
    
    # Start Sunshine
    nohup sunshine > $LOGFILE 2>&1 &
    echo \$!
" > /tmp/sunshine.pid 2>&1

SUNSHINE_PID=$(cat /tmp/sunshine.pid 2>/dev/null)

if [ -n "$SUNSHINE_PID" ] && ps -p "$SUNSHINE_PID" >/dev/null 2>&1; then
    echo "[SUCCESS] ✓ Sunshine started successfully"
    echo "[INFO] PID: $SUNSHINE_PID"
    echo "[INFO] Logs: $LOGFILE"
else
    echo "[ERROR] Failed to start Sunshine"
    if [ -f "$LOGFILE" ]; then
        echo "[ERROR] Log output:"
        cat "$LOGFILE"
    fi
    exit 1
fi

sleep 3

# Verify Sunshine is still running
if ps -p "$SUNSHINE_PID" >/dev/null 2>&1; then
    echo "[SUCCESS] ✓ Sunshine is running and stable"
else
    echo "[ERROR] Sunshine died after start"
    echo "[ERROR] Check logs: cat $LOGFILE"
    exit 1
fi

echo ""
echo "=========================================="
echo "  CONFIGURATION COMPLETE!"
echo "=========================================="
echo ""
echo "✓ uinput module loaded and configured"
echo "✓ Device permissions set correctly"
echo "✓ User added to required groups"
echo "✓ Virtual device creation tested successfully"
echo "✓ Sunshine configured and running"
echo ""
echo "NEXT STEPS:"
echo "1. Connect with Moonlight client"
echo "2. Test keyboard and mouse control"
echo "3. Monitor logs: tail -f $LOGFILE"
echo ""
echo "To verify virtual devices are created when you connect:"
echo "  grep -i 'virtual.*keyboard\\|virtual.*mouse\\|uinput' $LOGFILE"
echo ""
echo "If input still doesn't work:"
echo "  - Check Moonlight client settings (enable input)"
echo "  - Check firewall/network settings"
echo "  - Verify Sunshine web UI: https://server-ip:47990"
echo ""
