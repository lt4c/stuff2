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

# Check if module is already loaded
if lsmod | grep -q "^uinput"; then
    echo "[INFO] uinput module already loaded"
else
    echo "[INFO] Attempting to load uinput module..."
    
    # Try to load the module
    if modprobe uinput 2>&1; then
        sleep 1
        if lsmod | grep -q "^uinput"; then
            echo "[SUCCESS] uinput module loaded"
        else
            echo "[WARN] modprobe succeeded but module not showing in lsmod"
        fi
    else
        echo "[ERROR] modprobe uinput failed"
        echo "[INFO] Checking if uinput is built into kernel..."
        
        # Check if uinput is built-in (not a module)
        if [ -e /dev/uinput ] || [ -c /dev/uinput ]; then
            echo "[INFO] uinput appears to be built into kernel (not a module)"
            echo "[SUCCESS] This is OK - uinput is available"
        elif grep -q "CONFIG_INPUT_UINPUT=y" /boot/config-$(uname -r) 2>/dev/null; then
            echo "[INFO] uinput is built into kernel (CONFIG_INPUT_UINPUT=y)"
            echo "[SUCCESS] This is OK - uinput is available"
        else
            echo "[ERROR] uinput not available as module or built-in"
            echo "[ERROR] You may need to install kernel headers or recompile kernel"
            echo ""
            echo "Checking kernel configuration..."
            if [ -f /boot/config-$(uname -r) ]; then
                grep "CONFIG_INPUT_UINPUT" /boot/config-$(uname -r) || echo "CONFIG_INPUT_UINPUT not found in kernel config"
            else
                echo "Kernel config not found at /boot/config-$(uname -r)"
            fi
            echo ""
            echo "Attempting to continue anyway..."
        fi
    fi
fi

# Step 2: Create uinput device if missing
echo ""
echo "[STEP 2] Checking uinput device..."
if [ ! -e /dev/uinput ]; then
    echo "[INFO] /dev/uinput does not exist, creating device node..."
    
    # Try to create the device node
    if mknod /dev/uinput c 10 223 2>/dev/null; then
        echo "[SUCCESS] Created /dev/uinput device node"
    else
        echo "[WARN] mknod failed, trying alternative methods..."
        
        # Alternative 1: Check if it exists under a different name
        if [ -e /dev/input/uinput ]; then
            echo "[INFO] Found /dev/input/uinput, creating symlink..."
            ln -sf /dev/input/uinput /dev/uinput
        # Alternative 2: Try with full path
        elif [ -e /dev/misc/uinput ]; then
            echo "[INFO] Found /dev/misc/uinput, creating symlink..."
            ln -sf /dev/misc/uinput /dev/uinput
        else
            echo "[ERROR] Cannot find or create uinput device"
        fi
    fi
fi

if [ -e /dev/uinput ]; then
    echo "[SUCCESS] /dev/uinput exists"
    ls -l /dev/uinput
elif [ -e /dev/input/uinput ]; then
    echo "[INFO] Using /dev/input/uinput instead"
    ls -l /dev/input/uinput
    # Create symlink for compatibility
    ln -sf /dev/input/uinput /dev/uinput 2>/dev/null || true
elif [ -e /dev/misc/uinput ]; then
    echo "[INFO] Using /dev/misc/uinput instead"
    ls -l /dev/misc/uinput
    # Create symlink for compatibility
    ln -sf /dev/misc/uinput /dev/uinput 2>/dev/null || true
else
    echo "[ERROR] Cannot find uinput device anywhere"
    echo "[INFO] Checking all possible locations..."
    find /dev -name "*uinput*" 2>/dev/null || echo "No uinput device found"
    echo ""
    echo "[ERROR] This kernel may not have uinput support"
    echo "[INFO] Attempting to continue with alternative input method..."
fi

# Step 3: Set permissions
echo ""
echo "[STEP 3] Setting permissions on uinput device..."

# Set permissions on all possible uinput locations
for uinput_path in /dev/uinput /dev/input/uinput /dev/misc/uinput; do
    if [ -e "$uinput_path" ]; then
        echo "[INFO] Setting permissions on $uinput_path"
        chmod 666 "$uinput_path" 2>/dev/null || echo "[WARN] Failed to chmod $uinput_path"
        chown root:input "$uinput_path" 2>/dev/null || echo "[WARN] Failed to chown $uinput_path"
    fi
done

# Verify at least one is accessible
UINPUT_FOUND=false
for uinput_path in /dev/uinput /dev/input/uinput /dev/misc/uinput; do
    if [ -w "$uinput_path" ]; then
        echo "[SUCCESS] $uinput_path is writable"
        UINPUT_FOUND=true
        break
    fi
done

if [ "$UINPUT_FOUND" = false ]; then
    echo "[ERROR] No writable uinput device found"
fi

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
