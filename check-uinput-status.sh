#!/bin/bash
# Quick diagnostic for Sunshine input issues

echo "=== Sunshine Input Diagnostic ==="
echo ""

# Detect user
USER="${SUDO_USER:-$(whoami)}"
echo "Checking for user: $USER"
echo ""

# Check 1: uinput module
echo "[1] uinput kernel module:"
if lsmod | grep -q "^uinput"; then
    echo "    ✓ Loaded"
else
    echo "    ✗ NOT loaded - Run: sudo modprobe uinput"
fi

# Check 2: uinput device
echo ""
echo "[2] /dev/uinput device:"
if [ -e /dev/uinput ]; then
    echo "    ✓ Exists"
    ls -l /dev/uinput | awk '{print "    Permissions: " $1 " " $3 ":" $4}'
else
    echo "    ✗ Does NOT exist - Run: sudo mknod /dev/uinput c 10 223"
fi

# Check 3: Write access
echo ""
echo "[3] Write access for user $USER:"
if [ -w /dev/uinput ]; then
    echo "    ✓ CAN write to /dev/uinput"
else
    echo "    ✗ CANNOT write to /dev/uinput"
    echo "    FIX: sudo chmod 666 /dev/uinput"
fi

# Check 4: User groups
echo ""
echo "[4] User groups:"
GROUPS_OUTPUT=$(groups "$USER" 2>/dev/null || groups)
echo "    $GROUPS_OUTPUT"
REQUIRED="input uinput video render"
for grp in $REQUIRED; do
    if echo "$GROUPS_OUTPUT" | grep -q "$grp"; then
        echo "    ✓ In $grp group"
    else
        echo "    ✗ NOT in $grp group - Run: sudo usermod -aG $grp $USER"
    fi
done

# Check 5: Input devices
echo ""
echo "[5] Input device permissions:"
if ls /dev/input/event* >/dev/null 2>&1; then
    EVENT_COUNT=$(ls /dev/input/event* | wc -l)
    echo "    Found $EVENT_COUNT event devices"
    WRITABLE=$(find /dev/input/event* -writable 2>/dev/null | wc -l)
    echo "    Writable: $WRITABLE/$EVENT_COUNT"
    if [ "$WRITABLE" -eq 0 ]; then
        echo "    ✗ No writable event devices"
        echo "    FIX: sudo chmod 664 /dev/input/event* && sudo chgrp input /dev/input/event*"
    fi
else
    echo "    ✗ No event devices found"
fi

# Check 6: Sunshine process
echo ""
echo "[6] Sunshine status:"
if pgrep -x sunshine >/dev/null; then
    SUNSHINE_PID=$(pgrep -x sunshine)
    SUNSHINE_USER=$(ps -o user= -p "$SUNSHINE_PID")
    echo "    ✓ Running (PID: $SUNSHINE_PID, User: $SUNSHINE_USER)"
else
    echo "    ✗ Not running"
fi

# Summary
echo ""
echo "=== QUICK FIX ==="
echo "If input doesn't work, run these commands:"
echo ""
echo "sudo modprobe uinput"
echo "sudo chmod 666 /dev/uinput"
echo "sudo usermod -aG input,uinput,video,render $USER"
echo "sudo chmod 664 /dev/input/event*"
echo "sudo chgrp input /dev/input/event*"
echo ""
echo "Then restart Sunshine:"
echo "pkill sunshine"
echo "sudo /home/red/Documents/sunshine_direct.sh"
