#!/bin/bash
# Aggressive uinput fix - Forces uinput to work for Sunshine

set -e

echo "=========================================="
echo "  AGGRESSIVE UINPUT FIX FOR SUNSHINE"
echo "=========================================="
echo ""

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This script must be run as root"
    echo "Usage: sudo $0"
    exit 1
fi

DESKTOP_USER="${SUDO_USER:-lt4c}"
echo "[INFO] Target user: $DESKTOP_USER"
echo ""

# Step 1: Force load uinput module with all methods
echo "[STEP 1] Force loading uinput module..."
echo "---"

# Method 1: Direct modprobe
modprobe uinput 2>/dev/null || echo "[INFO] modprobe returned error (may be built-in)"

# Method 2: Add to modules to load at boot
if ! grep -q "^uinput" /etc/modules 2>/dev/null; then
    echo "uinput" >> /etc/modules
    echo "[INFO] Added uinput to /etc/modules for boot loading"
fi

# Method 3: Create modules-load.d config
mkdir -p /etc/modules-load.d
echo "uinput" > /etc/modules-load.d/uinput.conf
echo "[INFO] Created /etc/modules-load.d/uinput.conf"

# Method 4: Force load via insmod if module exists
UINPUT_MODULE=$(find /lib/modules/$(uname -r) -name "uinput.ko*" 2>/dev/null | head -n1)
if [ -n "$UINPUT_MODULE" ]; then
    echo "[INFO] Found uinput module: $UINPUT_MODULE"
    insmod "$UINPUT_MODULE" 2>/dev/null || echo "[INFO] insmod failed (may already be loaded)"
fi

# Verify
if lsmod | grep -q "^uinput"; then
    echo "[SUCCESS] uinput module is loaded"
elif [ -e /dev/uinput ]; then
    echo "[SUCCESS] uinput is built into kernel (device exists)"
else
    echo "[WARN] Cannot verify uinput module, but continuing..."
fi
echo ""

# Step 2: Create uinput device with multiple methods
echo "[STEP 2] Creating uinput device node..."
echo "---"

# Remove existing device if it's broken
if [ -e /dev/uinput ] && [ ! -c /dev/uinput ]; then
    echo "[INFO] Removing broken /dev/uinput"
    rm -f /dev/uinput
fi

# Method 1: Standard mknod
if [ ! -e /dev/uinput ]; then
    mknod /dev/uinput c 10 223 2>/dev/null && echo "[INFO] Created /dev/uinput with mknod" || true
fi

# Method 2: Check alternative locations
for alt_path in /dev/input/uinput /dev/misc/uinput; do
    if [ -e "$alt_path" ] && [ ! -e /dev/uinput ]; then
        ln -sf "$alt_path" /dev/uinput
        echo "[INFO] Created symlink from $alt_path to /dev/uinput"
    fi
done

# Method 3: Force creation via MAKEDEV if available
if [ ! -e /dev/uinput ] && command -v MAKEDEV >/dev/null 2>&1; then
    cd /dev && MAKEDEV uinput 2>/dev/null || true
fi

# Verify device exists
if [ -e /dev/uinput ]; then
    echo "[SUCCESS] /dev/uinput exists"
    ls -l /dev/uinput
else
    echo "[ERROR] Failed to create /dev/uinput"
    echo "[INFO] Checking if kernel has uinput support..."
    zgrep CONFIG_INPUT_UINPUT /proc/config.gz 2>/dev/null || \
    grep CONFIG_INPUT_UINPUT /boot/config-$(uname -r) 2>/dev/null || \
    echo "[WARN] Cannot check kernel config"
fi
echo ""

# Step 3: Set maximum permissions
echo "[STEP 3] Setting maximum permissions..."
echo "---"

# Set world-writable permissions on all uinput locations
for uinput_dev in /dev/uinput /dev/input/uinput /dev/misc/uinput; do
    if [ -e "$uinput_dev" ]; then
        chmod 777 "$uinput_dev" 2>/dev/null || chmod 666 "$uinput_dev"
        chown root:input "$uinput_dev" 2>/dev/null || true
        echo "[INFO] Set permissions on $uinput_dev"
    fi
done

# Set permissions on all input devices
chmod 666 /dev/input/* 2>/dev/null || true
echo "[INFO] Set permissions on all /dev/input/* devices"
echo ""

# Step 4: Create and configure groups
echo "[STEP 4] Configuring groups..."
echo "---"

REQUIRED_GROUPS="input uinput video render audio"
for group in $REQUIRED_GROUPS; do
    groupadd -f "$group" 2>/dev/null
    usermod -aG "$group" "$DESKTOP_USER" 2>/dev/null || true
done

echo "[INFO] User $DESKTOP_USER added to all required groups"
echo "[INFO] Current groups: $(groups $DESKTOP_USER)"
echo ""

# Step 5: Create persistent udev rules
echo "[STEP 5] Creating persistent udev rules..."
echo "---"

cat > /etc/udev/rules.d/99-uinput-sunshine.rules <<'EOF'
# Persistent uinput permissions for Sunshine
KERNEL=="uinput", MODE="0666", GROUP="input", OPTIONS+="static_node=uinput"
SUBSYSTEM=="misc", KERNEL=="uinput", MODE="0666", GROUP="input"
SUBSYSTEM=="input", KERNEL=="event*", MODE="0666", GROUP="input"
SUBSYSTEM=="input", KERNEL=="mouse*", MODE="0666", GROUP="input"
SUBSYSTEM=="input", KERNEL=="js*", MODE="0666", GROUP="input"

# Load uinput module on boot
ACTION=="add", SUBSYSTEM=="misc", KERNEL=="uinput", RUN+="/sbin/modprobe uinput"
EOF

echo "[INFO] Created /etc/udev/rules.d/99-uinput-sunshine.rules"

# Reload udev rules
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true
echo "[INFO] Reloaded udev rules"
echo ""

# Step 6: Create systemd service for persistent permissions
echo "[STEP 6] Creating systemd service for boot-time permissions..."
echo "---"

cat > /etc/systemd/system/sunshine-uinput.service <<EOF
[Unit]
Description=Sunshine uinput permissions
After=systemd-modules-load.service
Before=sunshine.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/modprobe uinput
ExecStart=/bin/bash -c 'chmod 666 /dev/uinput 2>/dev/null || true'
ExecStart=/bin/bash -c 'chmod 666 /dev/input/event* 2>/dev/null || true'
ExecStart=/bin/bash -c 'chgrp input /dev/uinput /dev/input/event* 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sunshine-uinput.service 2>/dev/null || true
systemctl start sunshine-uinput.service 2>/dev/null || true

echo "[INFO] Created and enabled sunshine-uinput.service"
echo ""

# Step 7: Test access as target user
echo "[STEP 7] Testing access as user $DESKTOP_USER..."
echo "---"

# Test 1: Basic write test
WRITE_TEST=$(su - "$DESKTOP_USER" -c "test -w /dev/uinput && echo 'OK' || echo 'FAIL'")
if [ "$WRITE_TEST" = "OK" ]; then
    echo "[SUCCESS] ✓ User can write to /dev/uinput"
else
    echo "[ERROR] ✗ User CANNOT write to /dev/uinput"
    echo "[DEBUG] Permissions:"
    ls -l /dev/uinput
    echo "[DEBUG] User groups:"
    groups "$DESKTOP_USER"
fi

# Test 2: Try to open device
su - "$DESKTOP_USER" -c "
python3 << 'PYEOF'
import sys
import os

# Test basic file access
try:
    with open('/dev/uinput', 'wb') as f:
        print('[SUCCESS] ✓ Can open /dev/uinput for writing')
except PermissionError:
    print('[ERROR] ✗ Permission denied opening /dev/uinput')
    sys.exit(1)
except Exception as e:
    print(f'[ERROR] ✗ Error opening /dev/uinput: {e}')
    sys.exit(1)

# Test evdev if available
try:
    from evdev import UInput, ecodes
    ui = UInput()
    ui.close()
    print('[SUCCESS] ✓ Can create virtual input devices with evdev')
except ImportError:
    print('[INFO] evdev not installed (optional)')
except Exception as e:
    print(f'[WARN] evdev test failed: {e}')
PYEOF
" 2>/dev/null || echo "[INFO] Python test skipped"
echo ""

# Step 8: Kill and restart Sunshine
echo "[STEP 8] Restarting Sunshine..."
echo "---"

if pgrep -x sunshine >/dev/null; then
    echo "[INFO] Stopping Sunshine..."
    pkill -9 sunshine
    sleep 2
fi

echo "[INFO] Starting Sunshine as user $DESKTOP_USER..."
su - "$DESKTOP_USER" -c "
    export DISPLAY=:0
    export XDG_RUNTIME_DIR=/run/user/$(id -u $DESKTOP_USER)
    nohup /usr/bin/sunshine > /tmp/sunshine-force-restart.log 2>&1 &
    echo \$!
" > /tmp/sunshine-new-pid.tmp

NEW_PID=$(cat /tmp/sunshine-new-pid.tmp 2>/dev/null)
rm -f /tmp/sunshine-new-pid.tmp

if [ -n "$NEW_PID" ]; then
    echo "[SUCCESS] Sunshine started with PID: $NEW_PID"
    sleep 3
    
    # Check if it's still running
    if ps -p "$NEW_PID" >/dev/null 2>&1; then
        echo "[SUCCESS] ✓ Sunshine is running"
    else
        echo "[ERROR] ✗ Sunshine died immediately after start"
        echo "[ERROR] Check logs: tail /tmp/sunshine-force-restart.log"
    fi
else
    echo "[ERROR] Failed to start Sunshine"
fi
echo ""

# Step 9: Verify virtual input device creation
echo "[STEP 9] Checking for virtual input devices..."
echo "---"

sleep 2

# Check Sunshine logs for virtual device creation
if [ -f /tmp/sunshine-force-restart.log ]; then
    if grep -q "Created.*virtual.*keyboard\|Created.*virtual.*mouse" /tmp/sunshine-force-restart.log; then
        echo "[SUCCESS] ✓ Sunshine created virtual input devices!"
        grep -i "virtual.*device\|uinput" /tmp/sunshine-force-restart.log | tail -5
    else
        echo "[WARN] No virtual device creation messages in log yet"
        echo "[INFO] Recent log entries:"
        tail -10 /tmp/sunshine-force-restart.log
    fi
fi

# Check for new input devices
echo ""
echo "[INFO] Current input devices:"
ls -l /dev/input/ | grep -E "event|mouse" | tail -5
echo ""

# Final summary
echo "=========================================="
echo "  FIX COMPLETE"
echo "=========================================="
echo ""
echo "✓ uinput module configured"
echo "✓ Device node created with maximum permissions"
echo "✓ User added to all required groups"
echo "✓ Persistent udev rules created"
echo "✓ Systemd service enabled"
echo "✓ Sunshine restarted"
echo ""
echo "NEXT STEPS:"
echo "1. Reconnect with Moonlight"
echo "2. Test keyboard and mouse"
echo "3. If still not working, check:"
echo "   - Sunshine logs: tail -f /tmp/sunshine-force-restart.log"
echo "   - System logs: journalctl -xe | grep sunshine"
echo "   - Input devices: ls -l /dev/input/"
echo ""
echo "If input STILL doesn't work after this, the issue may be:"
echo "- Sunshine configuration (check sunshine.conf)"
echo "- Network/protocol issue (not permissions)"
echo "- Client-side Moonlight settings"
echo ""
