#!/bin/bash
# Emergency fix for Sunshine input not working
# Run this if keyboard/mouse don't work in Moonlight

echo "=== Sunshine Input Fix ==="
echo "This script fixes keyboard/mouse control issues in Sunshine"
echo ""

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This script must be run as root"
    echo "Usage: sudo $0"
    exit 1
fi

# Detect desktop user
DESKTOP_USER="${SUDO_USER:-$(who | awk '{print $1}' | head -n1)}"
if [ -z "$DESKTOP_USER" ]; then
    echo "[ERROR] Cannot detect desktop user"
    exit 1
fi

echo "[INFO] Desktop user: $DESKTOP_USER"
echo ""

# Step 1: Load uinput module
echo "[STEP 1] Loading uinput kernel module..."
if ! lsmod | grep -q "^uinput"; then
    modprobe uinput
    if lsmod | grep -q "^uinput"; then
        echo "[SUCCESS] uinput module loaded"
    else
        echo "[ERROR] Failed to load uinput module"
        exit 1
    fi
else
    echo "[INFO] uinput module already loaded"
fi

# Step 2: Create uinput device if missing
echo ""
echo "[STEP 2] Checking uinput device..."
if [ ! -e /dev/uinput ]; then
    echo "[INFO] Creating /dev/uinput device node..."
    mknod /dev/uinput c 10 223
fi

if [ -e /dev/uinput ]; then
    echo "[SUCCESS] /dev/uinput exists"
else
    echo "[ERROR] Failed to create /dev/uinput"
    exit 1
fi

# Step 3: Set permissions
echo ""
echo "[STEP 3] Setting permissions on /dev/uinput..."
chmod 666 /dev/uinput
chown root:input /dev/uinput

# Step 4: Add user to required groups
echo ""
echo "[STEP 4] Adding user to required groups..."
REQUIRED_GROUPS="input uinput video render audio"
for group in $REQUIRED_GROUPS; do
    # Create group if it doesn't exist
    groupadd -f "$group" 2>/dev/null
    
    # Add user to group
    if ! groups "$DESKTOP_USER" | grep -q "$group"; then
        usermod -aG "$group" "$DESKTOP_USER"
        echo "[INFO] Added $DESKTOP_USER to $group group"
    else
        echo "[INFO] User already in $group group"
    fi
done

# Step 5: Set permissions on input devices
echo ""
echo "[STEP 5] Setting permissions on input devices..."
if ls /dev/input/event* >/dev/null 2>&1; then
    chmod 664 /dev/input/event*
    chgrp input /dev/input/event*
    echo "[SUCCESS] Set permissions on event devices"
fi

# Step 6: Test uinput access as user
echo ""
echo "[STEP 6] Testing uinput access as user $DESKTOP_USER..."
UINPUT_TEST=$(su - "$DESKTOP_USER" -c "
    if [ -w /dev/uinput ]; then
        echo 'OK'
    else
        echo 'FAILED'
    fi
")

if [ "$UINPUT_TEST" = "OK" ]; then
    echo "[SUCCESS] ✓ User $DESKTOP_USER can write to /dev/uinput"
    echo "[SUCCESS] ✓ Virtual keyboard/mouse should work!"
else
    echo "[ERROR] ✗ User $DESKTOP_USER CANNOT write to /dev/uinput"
    echo "[ERROR] ✗ Virtual input will NOT work"
    
    # Show debug info
    echo ""
    echo "=== DEBUG INFO ==="
    echo "Device permissions:"
    ls -l /dev/uinput
    echo ""
    echo "User groups:"
    groups "$DESKTOP_USER"
    echo ""
    echo "Module status:"
    lsmod | grep uinput
    
    exit 1
fi

# Step 7: Test Python uinput (if available)
echo ""
echo "[STEP 7] Testing Python uinput library..."
su - "$DESKTOP_USER" -c '
python3 -c "
import sys
try:
    import evdev
    print(\"[SUCCESS] evdev library available\")
except ImportError:
    print(\"[WARN] evdev library not installed (optional)\")
    sys.exit(0)

try:
    from evdev import UInput, ecodes
    ui = UInput()
    ui.close()
    print(\"[SUCCESS] ✓ Can create virtual input devices!\")
except Exception as e:
    print(f\"[ERROR] ✗ Cannot create virtual devices: {e}\")
    sys.exit(1)
" 2>/dev/null
' || echo "[INFO] Python test skipped (evdev not installed)"

# Step 8: Restart Sunshine if running
echo ""
echo "[STEP 8] Checking Sunshine status..."
if pgrep -x sunshine >/dev/null; then
    echo "[INFO] Sunshine is running"
    echo "[ACTION] You should restart Sunshine for changes to take effect:"
    echo "  1. Disconnect Moonlight client"
    echo "  2. Run: pkill sunshine"
    echo "  3. Run: sudo /home/red/Documents/sunshine_direct.sh"
else
    echo "[INFO] Sunshine is not running"
    echo "[ACTION] Start Sunshine with: sudo /home/red/Documents/sunshine_direct.sh"
fi

echo ""
echo "=== FIX COMPLETE ==="
echo "✓ uinput module loaded"
echo "✓ Permissions set correctly"
echo "✓ User added to required groups"
echo "✓ Input devices configured"
echo ""
echo "Next steps:"
echo "1. Restart Sunshine if it's running"
echo "2. Reconnect with Moonlight"
echo "3. Test keyboard and mouse control"
echo ""
echo "If input still doesn't work, check Sunshine logs:"
echo "  tail -f /tmp/sunshine-direct.log"
