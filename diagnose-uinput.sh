#!/bin/bash
# Comprehensive uinput diagnostic

echo "=========================================="
echo "  UINPUT DIAGNOSTIC TOOL"
echo "=========================================="
echo ""

# System info
echo "[SYSTEM INFO]"
echo "Kernel: $(uname -r)"
echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
echo ""

# Check 1: Kernel module
echo "[1] CHECKING KERNEL MODULE"
echo "---"
if lsmod | grep -q "^uinput"; then
    echo "✓ uinput module is LOADED"
    lsmod | grep uinput
else
    echo "✗ uinput module is NOT loaded"
    echo ""
    echo "Attempting to load..."
    if sudo modprobe uinput 2>&1; then
        echo "✓ Module loaded successfully"
    else
        echo "✗ Failed to load module"
        echo ""
        echo "Checking if built into kernel..."
        if grep -q "CONFIG_INPUT_UINPUT=y" /boot/config-$(uname -r) 2>/dev/null; then
            echo "✓ uinput is built into kernel (not a module)"
        elif grep -q "CONFIG_INPUT_UINPUT=m" /boot/config-$(uname -r) 2>/dev/null; then
            echo "! uinput is configured as module but not loading"
        else
            echo "✗ uinput not found in kernel config"
            echo ""
            echo "Kernel config check:"
            if [ -f /boot/config-$(uname -r) ]; then
                grep "CONFIG_INPUT_UINPUT" /boot/config-$(uname -r) || echo "CONFIG_INPUT_UINPUT not found"
            else
                echo "Kernel config file not found"
            fi
        fi
    fi
fi
echo ""

# Check 2: Device node
echo "[2] CHECKING DEVICE NODE"
echo "---"
UINPUT_LOCATIONS="/dev/uinput /dev/input/uinput /dev/misc/uinput"
FOUND_DEVICE=""

for location in $UINPUT_LOCATIONS; do
    if [ -e "$location" ]; then
        echo "✓ Found: $location"
        ls -l "$location"
        FOUND_DEVICE="$location"
    fi
done

if [ -z "$FOUND_DEVICE" ]; then
    echo "✗ No uinput device found in standard locations"
    echo ""
    echo "Searching entire /dev..."
    find /dev -name "*uinput*" 2>/dev/null || echo "No uinput device found anywhere"
    echo ""
    echo "Attempting to create device node..."
    if sudo mknod /dev/uinput c 10 223 2>/dev/null; then
        echo "✓ Created /dev/uinput"
        FOUND_DEVICE="/dev/uinput"
    else
        echo "✗ Failed to create device node"
    fi
else
    echo ""
    echo "Primary device: $FOUND_DEVICE"
fi
echo ""

# Check 3: Permissions
echo "[3] CHECKING PERMISSIONS"
echo "---"
if [ -n "$FOUND_DEVICE" ]; then
    PERMS=$(stat -c "%a %U:%G" "$FOUND_DEVICE" 2>/dev/null)
    echo "Current permissions: $PERMS"
    
    if [ -w "$FOUND_DEVICE" ]; then
        echo "✓ Device is writable by current user"
    else
        echo "✗ Device is NOT writable by current user"
        echo ""
        echo "Fixing permissions..."
        sudo chmod 666 "$FOUND_DEVICE"
        sudo chown root:input "$FOUND_DEVICE"
        
        if [ -w "$FOUND_DEVICE" ]; then
            echo "✓ Permissions fixed"
        else
            echo "✗ Still not writable - may need to add user to groups"
        fi
    fi
else
    echo "✗ No device to check permissions on"
fi
echo ""

# Check 4: User groups
echo "[4] CHECKING USER GROUPS"
echo "---"
CURRENT_USER="${SUDO_USER:-$(whoami)}"
echo "User: $CURRENT_USER"
echo "Groups: $(groups $CURRENT_USER)"
echo ""

REQUIRED_GROUPS="input uinput video render"
MISSING_GROUPS=""

for grp in $REQUIRED_GROUPS; do
    if groups "$CURRENT_USER" | grep -q "$grp"; then
        echo "✓ In $grp group"
    else
        echo "✗ NOT in $grp group"
        MISSING_GROUPS="$MISSING_GROUPS $grp"
    fi
done

if [ -n "$MISSING_GROUPS" ]; then
    echo ""
    echo "Adding user to missing groups..."
    for grp in $MISSING_GROUPS; do
        sudo groupadd -f "$grp" 2>/dev/null
        sudo usermod -aG "$grp" "$CURRENT_USER"
        echo "Added to $grp"
    done
    echo ""
    echo "⚠ NOTE: You may need to log out and back in for group changes to take effect"
fi
echo ""

# Check 5: Test write access
echo "[5] TESTING WRITE ACCESS"
echo "---"
if [ -n "$FOUND_DEVICE" ]; then
    if [ -w "$FOUND_DEVICE" ]; then
        echo "✓ Can write to $FOUND_DEVICE"
        
        # Try to actually write (test)
        if timeout 1 bash -c "echo -n > $FOUND_DEVICE" 2>/dev/null; then
            echo "✓ Write test successful"
        else
            echo "! Write test failed (may be normal if device is busy)"
        fi
    else
        echo "✗ Cannot write to $FOUND_DEVICE"
    fi
else
    echo "✗ No device to test"
fi
echo ""

# Check 6: Python evdev test
echo "[6] TESTING PYTHON EVDEV (optional)"
echo "---"
if command -v python3 >/dev/null 2>&1; then
    python3 << 'PYEOF'
import sys
try:
    import evdev
    print("✓ evdev library installed")
    
    try:
        from evdev import UInput, ecodes
        ui = UInput()
        ui.close()
        print("✓ Can create virtual input devices!")
    except PermissionError as e:
        print(f"✗ Permission denied: {e}")
    except Exception as e:
        print(f"✗ Error creating virtual device: {e}")
        
except ImportError:
    print("! evdev library not installed (optional)")
    print("  Install with: pip3 install evdev")
PYEOF
else
    echo "! Python3 not found"
fi
echo ""

# Summary
echo "=========================================="
echo "  SUMMARY & RECOMMENDATIONS"
echo "=========================================="
echo ""

if [ -n "$FOUND_DEVICE" ] && [ -w "$FOUND_DEVICE" ]; then
    echo "✓ GOOD: uinput device exists and is writable"
    echo ""
    echo "If Sunshine still can't control input, try:"
    echo "1. Restart Sunshine: pkill sunshine && sudo /home/red/Documents/sunshine_direct.sh"
    echo "2. Check Sunshine logs: tail -f /tmp/sunshine-direct.log"
    echo "3. Verify Sunshine is running as correct user"
else
    echo "✗ PROBLEM: uinput device not accessible"
    echo ""
    echo "Quick fix commands:"
    echo ""
    echo "sudo modprobe uinput"
    echo "sudo mknod /dev/uinput c 10 223 2>/dev/null"
    echo "sudo chmod 666 /dev/uinput"
    echo "sudo usermod -aG input,uinput,video,render $CURRENT_USER"
    echo ""
    echo "Then run: sudo /home/red/Documents/fix-sunshine-input.sh"
fi

echo ""
echo "For more help, check: /home/red/Documents/SUNSHINE_FIXES.md"
