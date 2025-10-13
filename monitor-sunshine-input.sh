#!/bin/bash
# Real-time monitor for Sunshine virtual input device creation

echo "=========================================="
echo "  SUNSHINE INPUT MONITOR"
echo "=========================================="
echo ""

LOGFILE="/tmp/sunshine-input-20251013-163558.log"
DESKTOP_USER="lt4c"

echo "[INFO] Monitoring Sunshine for virtual device creation..."
echo "[INFO] Log file: $LOGFILE"
echo ""

# Check current Sunshine status
if pgrep -x sunshine >/dev/null; then
    SUNSHINE_PID=$(pgrep -x sunshine)
    echo "[INFO] Sunshine is running (PID: $SUNSHINE_PID)"
    echo "[INFO] Running as user: $(ps -o user= -p $SUNSHINE_PID)"
else
    echo "[ERROR] Sunshine is NOT running!"
    echo "[FIX] Start with: sudo -u lt4c sunshine &"
    exit 1
fi
echo ""

# Check if log file exists
if [ ! -f "$LOGFILE" ]; then
    echo "[WARN] Log file not found: $LOGFILE"
    echo "[INFO] Looking for other Sunshine logs..."
    find /tmp -name "sunshine*.log" -mmin -10 2>/dev/null
    echo ""
fi

# Show current log content related to input
echo "=========================================="
echo "  CURRENT LOG ANALYSIS"
echo "=========================================="
echo ""

if [ -f "$LOGFILE" ]; then
    echo "[1] Checking for input-related messages..."
    if grep -qi "input\|keyboard\|mouse\|uinput\|evdev\|virtual" "$LOGFILE"; then
        echo "[FOUND] Input-related messages:"
        grep -i "input\|keyboard\|mouse\|uinput\|evdev\|virtual" "$LOGFILE" | tail -20
    else
        echo "[NOT FOUND] No input-related messages in log"
    fi
    echo ""
    
    echo "[2] Checking for errors..."
    if grep -qi "error\|fail\|cannot\|unable" "$LOGFILE"; then
        echo "[FOUND] Error messages:"
        grep -i "error\|fail\|cannot\|unable" "$LOGFILE" | tail -10
    else
        echo "[OK] No error messages"
    fi
    echo ""
    
    echo "[3] Checking for client connections..."
    if grep -qi "client.*connect\|session.*start" "$LOGFILE"; then
        echo "[FOUND] Client connection messages:"
        grep -i "client.*connect\|session.*start" "$LOGFILE" | tail -5
    else
        echo "[NOT FOUND] No client connections detected yet"
    fi
    echo ""
fi

# Check actual input devices
echo "=========================================="
echo "  CURRENT INPUT DEVICES"
echo "=========================================="
echo ""
echo "[INFO] Current /dev/input devices:"
ls -lt /dev/input/ | head -10
echo ""

# Check if any new virtual devices were created
echo "[INFO] Looking for Sunshine-created devices..."
if ls /dev/input/by-id/*Sunshine* 2>/dev/null; then
    echo "[FOUND] Sunshine virtual devices detected!"
else
    echo "[NOT FOUND] No Sunshine virtual devices found"
fi
echo ""

# Check uinput access in real-time
echo "=========================================="
echo "  UINPUT ACCESS CHECK"
echo "=========================================="
echo ""
echo "[INFO] Testing uinput access as user $DESKTOP_USER..."
sudo -u "$DESKTOP_USER" bash << 'EOF'
if [ -w /dev/uinput ]; then
    echo "[SUCCESS] ✓ /dev/uinput is writable"
else
    echo "[ERROR] ✗ /dev/uinput is NOT writable"
fi

# Try to create a test device
python3 << 'PYTEST'
try:
    from evdev import UInput
    ui = UInput(name="Test-Device")
    print("[SUCCESS] ✓ Can create virtual devices")
    print(f"[INFO] Created device: {ui.device.path}")
    ui.close()
except Exception as e:
    print(f"[ERROR] ✗ Cannot create virtual devices: {e}")
PYTEST
EOF
echo ""

# Monitor in real-time
echo "=========================================="
echo "  REAL-TIME MONITORING"
echo "=========================================="
echo ""
echo "[ACTION] Now connect with Moonlight and watch for messages..."
echo "[INFO] Press Ctrl+C to stop monitoring"
echo ""
echo "Watching for:"
echo "  - Virtual device creation"
echo "  - Input events"
echo "  - Client connections"
echo "  - Errors"
echo ""
echo "---"

# Tail the log and highlight important lines
if [ -f "$LOGFILE" ]; then
    tail -f "$LOGFILE" 2>/dev/null | while IFS= read -r line; do
        # Highlight input-related messages
        if echo "$line" | grep -qi "keyboard\|mouse\|virtual.*device\|uinput\|evdev"; then
            echo "[INPUT] $line"
        elif echo "$line" | grep -qi "client.*connect\|session.*start"; then
            echo "[CLIENT] $line"
        elif echo "$line" | grep -qi "error\|fail\|cannot\|unable"; then
            echo "[ERROR] $line"
        elif echo "$line" | grep -qi "warn"; then
            echo "[WARN] $line"
        else
            echo "$line"
        fi
    done
else
    echo "[ERROR] Cannot monitor - log file not found"
    echo "[INFO] Sunshine may be logging elsewhere"
    echo ""
    echo "Try these commands:"
    echo "  journalctl -u sunshine -f"
    echo "  tail -f ~/.config/sunshine/sunshine.log"
    echo "  dmesg -w | grep -i sunshine"
fi
