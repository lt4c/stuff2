#!/bin/bash
# Check Sunshine configuration for input device issues

echo "=========================================="
echo "  SUNSHINE CONFIGURATION CHECKER"
echo "=========================================="
echo ""

DESKTOP_USER="lt4c"
SUNSHINE_CONFIG="/home/$DESKTOP_USER/.config/sunshine/sunshine.conf"

# Check if Sunshine binary has input support
echo "[1] Checking Sunshine binary capabilities..."
echo "---"

SUNSHINE_BIN=$(which sunshine 2>/dev/null)
if [ -z "$SUNSHINE_BIN" ]; then
    echo "[ERROR] Sunshine binary not found in PATH"
    echo "[INFO] Searching for sunshine..."
    SUNSHINE_BIN=$(find /usr -name sunshine -type f 2>/dev/null | head -1)
fi

if [ -n "$SUNSHINE_BIN" ]; then
    echo "[INFO] Sunshine binary: $SUNSHINE_BIN"
    
    # Check if it's linked with evdev
    echo "[INFO] Checking library dependencies..."
    if ldd "$SUNSHINE_BIN" 2>/dev/null | grep -q "libevdev"; then
        echo "[SUCCESS] ✓ Sunshine is linked with libevdev (input support enabled)"
    else
        echo "[WARN] Sunshine is NOT linked with libevdev"
        echo "[INFO] This may mean input support is not compiled in"
    fi
    
    # Check for input-related symbols
    if nm "$SUNSHINE_BIN" 2>/dev/null | grep -qi "uinput\|evdev\|input"; then
        echo "[SUCCESS] ✓ Sunshine binary has input-related symbols"
    else
        echo "[WARN] No input-related symbols found in binary"
    fi
else
    echo "[ERROR] Cannot find Sunshine binary"
fi
echo ""

# Check Sunshine configuration
echo "[2] Checking Sunshine configuration..."
echo "---"

if [ -f "$SUNSHINE_CONFIG" ]; then
    echo "[INFO] Configuration file: $SUNSHINE_CONFIG"
    echo ""
    
    # Show input-related config
    echo "[INFO] Input-related settings:"
    grep -E "keyboard|mouse|gamepad|input|virtual" "$SUNSHINE_CONFIG" 2>/dev/null || echo "  (none found)"
    echo ""
    
    # Check for problematic settings
    if grep -q "keyboard.*=.*disabled" "$SUNSHINE_CONFIG" 2>/dev/null; then
        echo "[ERROR] ✗ Keyboard is DISABLED in config!"
        echo "[FIX] Remove or change: keyboard = disabled"
    fi
    
    if grep -q "mouse.*=.*disabled" "$SUNSHINE_CONFIG" 2>/dev/null; then
        echo "[ERROR] ✗ Mouse is DISABLED in config!"
        echo "[FIX] Remove or change: mouse = disabled"
    fi
    
    # Show full config
    echo "[INFO] Full configuration:"
    cat "$SUNSHINE_CONFIG"
else
    echo "[WARN] Configuration file not found: $SUNSHINE_CONFIG"
    echo "[INFO] Sunshine may be using default configuration"
fi
echo ""

# Check Sunshine apps configuration
echo "[3] Checking Sunshine apps.json..."
echo "---"

APPS_JSON="/home/$DESKTOP_USER/.config/sunshine/apps.json"
if [ -f "$APPS_JSON" ]; then
    echo "[INFO] Apps configuration: $APPS_JSON"
    cat "$APPS_JSON"
else
    echo "[WARN] No apps.json found"
    echo "[INFO] Creating default Desktop app..."
    
    mkdir -p "$(dirname "$APPS_JSON")"
    cat > "$APPS_JSON" << 'EOF'
{
  "env": {
    "PATH": "$(PATH):$(HOME)/.local/bin"
  },
  "apps": [
    {
      "name": "Desktop",
      "output": "",
      "cmd": "",
      "exclude-global-prep-cmd": "false",
      "elevated": "false",
      "auto-detach": "true",
      "image-path": ""
    }
  ]
}
EOF
    chown "$DESKTOP_USER:$DESKTOP_USER" "$APPS_JSON"
    echo "[SUCCESS] Created default apps.json"
fi
echo ""

# Check if Sunshine is actually receiving input from Moonlight
echo "[4] Checking network connectivity for input..."
echo "---"

if pgrep -x sunshine >/dev/null; then
    SUNSHINE_PID=$(pgrep -x sunshine)
    echo "[INFO] Sunshine PID: $SUNSHINE_PID"
    echo ""
    
    # Check what ports Sunshine is listening on
    echo "[INFO] Sunshine listening ports:"
    netstat -tulpn 2>/dev/null | grep "$SUNSHINE_PID" || ss -tulpn 2>/dev/null | grep "$SUNSHINE_PID"
    echo ""
    
    # Check if control ports are open
    echo "[INFO] Checking critical control ports (48100-48200)..."
    if netstat -tulpn 2>/dev/null | grep "$SUNSHINE_PID" | grep -E "481[0-9]{2}"; then
        echo "[SUCCESS] ✓ Sunshine is listening on control ports"
    else
        echo "[WARN] Sunshine may not be listening on control ports"
        echo "[INFO] This could prevent input from working"
    fi
else
    echo "[ERROR] Sunshine is not running"
fi
echo ""

# Check system logs for Sunshine errors
echo "[5] Checking system logs for Sunshine errors..."
echo "---"

echo "[INFO] Recent Sunshine-related errors in syslog:"
grep -i sunshine /var/log/syslog 2>/dev/null | grep -i "error\|fail\|cannot" | tail -5 || echo "  (none found)"
echo ""

echo "[INFO] Recent dmesg errors related to input:"
dmesg | grep -i "uinput\|evdev\|input" | grep -i "error\|fail" | tail -5 || echo "  (none found)"
echo ""

# Final recommendations
echo "=========================================="
echo "  DIAGNOSIS & RECOMMENDATIONS"
echo "=========================================="
echo ""

# Test if we can manually create a virtual device while Sunshine is running
echo "[TEST] Attempting to create virtual device while Sunshine runs..."
sudo -u "$DESKTOP_USER" python3 << 'PYTEST'
try:
    from evdev import UInput, ecodes
    
    ui = UInput({
        ecodes.EV_KEY: [ecodes.KEY_A, ecodes.BTN_LEFT]
    }, name="Manual-Test-Device")
    
    print("[SUCCESS] ✓ Can create virtual device while Sunshine runs")
    print(f"[INFO] Device created: {ui.device.path}")
    
    # Check if it appears in /dev/input
    import os
    print(f"[INFO] Device exists: {os.path.exists(ui.device.path)}")
    
    ui.close()
    
except Exception as e:
    print(f"[ERROR] ✗ Cannot create virtual device: {e}")
PYTEST
echo ""

echo "POSSIBLE ISSUES:"
echo ""
echo "1. Sunshine binary may not have input support compiled in"
echo "   - Check: ldd $(which sunshine) | grep evdev"
echo "   - Fix: Reinstall Sunshine with input support"
echo ""
echo "2. Sunshine may be configured to not use virtual input"
echo "   - Check: $SUNSHINE_CONFIG"
echo "   - Fix: Ensure keyboard/mouse not disabled"
echo ""
echo "3. Moonlight client may not be sending input"
echo "   - Check Moonlight settings: Enable input capture"
echo "   - Try: Restart Moonlight client"
echo ""
echo "4. Network/firewall blocking control stream"
echo "   - Check: Ports 48100-48200 TCP/UDP"
echo "   - Fix: sudo ufw allow 48100:48200/tcp && sudo ufw allow 48100:48200/udp"
echo ""
echo "NEXT STEPS:"
echo "1. Run: bash /home/red/Documents/monitor-sunshine-input.sh"
echo "2. Connect with Moonlight"
echo "3. Watch for virtual device creation messages"
echo "4. If no messages appear, Sunshine may need to be recompiled with input support"
echo ""
