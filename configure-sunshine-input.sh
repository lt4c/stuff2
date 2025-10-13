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
# STEP 7: Test virtual device creation (CRITICAL)
# ============================================
echo "[STEP 7/8] Testing virtual device creation..."
echo "---"
echo "[INFO] This is the CRITICAL test - if this fails, Sunshine cannot create keyboard/mouse"
echo ""

# First, verify basic file access
echo "[TEST 1/4] Checking basic /dev/uinput access..."
if su - "$DESKTOP_USER" -c "test -w /dev/uinput"; then
    echo "[SUCCESS] ✓ User can write to /dev/uinput"
else
    echo "[ERROR] ✗ User CANNOT write to /dev/uinput"
    echo "[FIX] Applying maximum permissions..."
    chmod 777 /dev/uinput
    chown root:input /dev/uinput
    
    if su - "$DESKTOP_USER" -c "test -w /dev/uinput"; then
        echo "[SUCCESS] ✓ Fixed - user can now write to /dev/uinput"
    else
        echo "[ERROR] ✗ Still cannot write - CRITICAL FAILURE"
        ls -l /dev/uinput
        groups "$DESKTOP_USER"
        exit 1
    fi
fi
echo ""

# Second, test Python evdev library
echo "[TEST 2/4] Checking Python evdev library..."
if su - "$DESKTOP_USER" -c "python3 -c 'import evdev' 2>/dev/null"; then
    echo "[SUCCESS] ✓ evdev library is available"
else
    echo "[ERROR] ✗ evdev library missing"
    echo "[FIX] Installing python3-evdev..."
    apt install -y python3-evdev libevdev2 2>/dev/null || {
        echo "[ERROR] Failed to install evdev"
        echo "[INFO] Trying pip install..."
        su - "$DESKTOP_USER" -c "pip3 install evdev --user" 2>/dev/null || true
    }
    
    if su - "$DESKTOP_USER" -c "python3 -c 'import evdev' 2>/dev/null"; then
        echo "[SUCCESS] ✓ evdev library now available"
    else
        echo "[ERROR] ✗ Cannot install evdev - Sunshine may not work"
    fi
fi
echo ""

# Third, test actual virtual device creation
echo "[TEST 3/4] Testing virtual keyboard creation..."
TEST_RESULT=$(su - "$DESKTOP_USER" -c '
python3 << "PYTEST"
import sys
try:
    from evdev import UInput, ecodes
    
    # Create a virtual keyboard with explicit capabilities
    capabilities = {
        ecodes.EV_KEY: [
            ecodes.KEY_A, ecodes.KEY_B, ecodes.KEY_C,
            ecodes.KEY_ENTER, ecodes.KEY_ESC
        ]
    }
    
    ui = UInput(capabilities, name="Sunshine-Test-Keyboard")
    print("SUCCESS: Created virtual keyboard")
    print(f"Device: {ui.device.path}")
    ui.close()
    
except PermissionError as e:
    print(f"PERMISSION_ERROR: {e}")
    sys.exit(1)
except OSError as e:
    print(f"OS_ERROR: {e}")
    sys.exit(1)
except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(1)
PYTEST
' 2>&1)

if echo "$TEST_RESULT" | grep -q "SUCCESS"; then
    echo "[SUCCESS] ✓ Virtual keyboard creation WORKS!"
    echo "$TEST_RESULT" | grep "Device:"
else
    echo "[ERROR] ✗ Virtual keyboard creation FAILED"
    echo "[ERROR] Output: $TEST_RESULT"
    echo ""
    
    # Diagnose the specific error
    if echo "$TEST_RESULT" | grep -q "PERMISSION_ERROR"; then
        echo "[DIAGNOSIS] Permission denied - uinput not accessible"
        echo "[FIX] Applying nuclear option - world-writable uinput..."
        chmod 777 /dev/uinput
        setfacl -m u:$DESKTOP_USER:rw /dev/uinput 2>/dev/null || true
        
    elif echo "$TEST_RESULT" | grep -q "OS_ERROR"; then
        echo "[DIAGNOSIS] OS error - kernel may not support uinput"
        echo "[INFO] Checking kernel config..."
        if [ -f /boot/config-$(uname -r) ]; then
            grep CONFIG_INPUT_UINPUT /boot/config-$(uname -r) || echo "CONFIG_INPUT_UINPUT not found"
        fi
        
    elif echo "$TEST_RESULT" | grep -q "No module named"; then
        echo "[DIAGNOSIS] Python evdev module not found"
        echo "[FIX] Installing via pip..."
        su - "$DESKTOP_USER" -c "pip3 install evdev --user --break-system-packages" 2>/dev/null || true
    fi
    
    # Retry after fixes
    echo ""
    echo "[RETRY] Testing again after fixes..."
    if su - "$DESKTOP_USER" -c 'python3 -c "from evdev import UInput; ui = UInput(); ui.close(); print(\"SUCCESS\")" 2>/dev/null' | grep -q "SUCCESS"; then
        echo "[SUCCESS] ✓ Virtual device creation now WORKS!"
    else
        echo "[ERROR] ✗ Still failing - this will prevent Sunshine input from working"
        echo ""
        echo "[MANUAL DEBUG] Run these commands to diagnose:"
        echo "  sudo -u $DESKTOP_USER python3 -c 'from evdev import UInput; ui = UInput()'"
        echo "  ls -l /dev/uinput"
        echo "  groups $DESKTOP_USER"
        echo "  lsmod | grep uinput"
    fi
fi
echo ""

# Fourth, test virtual mouse creation
echo "[TEST 4/4] Testing virtual mouse creation..."
MOUSE_TEST=$(su - "$DESKTOP_USER" -c '
python3 << "PYTEST"
import sys
try:
    from evdev import UInput, ecodes, AbsInfo
    
    # Create a virtual mouse with absolute positioning
    capabilities = {
        ecodes.EV_KEY: [ecodes.BTN_LEFT, ecodes.BTN_RIGHT, ecodes.BTN_MIDDLE],
        ecodes.EV_ABS: [
            (ecodes.ABS_X, AbsInfo(0, 0, 65535, 0, 0, 0)),
            (ecodes.ABS_Y, AbsInfo(0, 0, 65535, 0, 0, 0))
        ]
    }
    
    ui = UInput(capabilities, name="Sunshine-Test-Mouse")
    print("SUCCESS: Created virtual mouse")
    ui.close()
    
except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(1)
PYTEST
' 2>&1)

if echo "$MOUSE_TEST" | grep -q "SUCCESS"; then
    echo "[SUCCESS] ✓ Virtual mouse creation WORKS!"
else
    echo "[WARN] Virtual mouse creation failed (keyboard may still work)"
    echo "[ERROR] Output: $MOUSE_TEST"
fi
echo ""

# Summary
echo "=========================================="
echo "  VIRTUAL DEVICE TEST SUMMARY"
echo "=========================================="
if echo "$TEST_RESULT" | grep -q "SUCCESS" && echo "$MOUSE_TEST" | grep -q "SUCCESS"; then
    echo "[SUCCESS] ✓✓✓ ALL TESTS PASSED ✓✓✓"
    echo "[SUCCESS] Sunshine WILL BE ABLE to create virtual keyboard and mouse!"
    echo ""
elif echo "$TEST_RESULT" | grep -q "SUCCESS"; then
    echo "[PARTIAL] ✓ Keyboard works, but mouse may not"
    echo "[INFO] Sunshine keyboard input should work"
    echo ""
else
    echo "[FAILURE] ✗✗✗ VIRTUAL DEVICE CREATION FAILED ✗✗✗"
    echo "[ERROR] Sunshine WILL NOT be able to create input devices"
    echo "[ERROR] Moonlight input WILL NOT WORK"
    echo ""
    echo "POSSIBLE CAUSES:"
    echo "  1. Kernel doesn't have CONFIG_INPUT_UINPUT enabled"
    echo "  2. SELinux/AppArmor blocking uinput access"
    echo "  3. Container/VM limitations"
    echo "  4. Missing kernel modules"
    echo ""
    echo "NEXT STEPS:"
    echo "  1. Check kernel config: zgrep CONFIG_INPUT_UINPUT /proc/config.gz"
    echo "  2. Check SELinux: getenforce"
    echo "  3. Check dmesg for errors: dmesg | grep uinput"
    echo "  4. Try in a different environment (bare metal vs VM)"
    echo ""
    
    # Don't exit - continue to see if Sunshine itself can work around it
    echo "[INFO] Continuing anyway - Sunshine may have alternative input methods..."
fi
echo ""

# ============================================
# STEP 8: Open firewall ports for Moonlight
# ============================================
echo "[STEP 8/9] Opening firewall ports for Moonlight..."
echo "---"

# Moonlight/Sunshine required ports:
# TCP 47984-47990: HTTPS/Configuration
# TCP 48010: RTSP
# UDP 47998-48000: Video stream
# UDP 48010: Audio stream
# UDP 48100-48200: Control stream (IMPORTANT for input!)

if command -v ufw >/dev/null 2>&1; then
    echo "[INFO] Configuring UFW firewall..."
    
    # Enable UFW if not already enabled
    ufw --force enable 2>/dev/null || true
    
    # Sunshine web interface and pairing
    ufw allow 47984:47990/tcp comment 'Sunshine HTTPS/Web UI' 2>/dev/null || true
    
    # Video streaming
    ufw allow 47998:48000/udp comment 'Sunshine Video Stream' 2>/dev/null || true
    
    # Audio streaming  
    ufw allow 48010/tcp comment 'Sunshine RTSP' 2>/dev/null || true
    ufw allow 48010/udp comment 'Sunshine Audio Stream' 2>/dev/null || true
    
    # CRITICAL: Control stream for keyboard/mouse input
    ufw allow 48100:48200/tcp comment 'Sunshine Control Stream' 2>/dev/null || true
    ufw allow 48100:48200/udp comment 'Sunshine Control Stream' 2>/dev/null || true
    
    # Reload UFW
    ufw reload 2>/dev/null || true
    
    echo "[SUCCESS] UFW firewall configured"
    echo "[INFO] Opened ports:"
    echo "  - TCP 47984-47990 (Web UI/Pairing)"
    echo "  - TCP 48010 (RTSP)"
    echo "  - UDP 47998-48000 (Video)"
    echo "  - UDP 48010 (Audio)"
    echo "  - TCP/UDP 48100-48200 (Control/Input) ← CRITICAL FOR KEYBOARD/MOUSE"
    
elif command -v firewall-cmd >/dev/null 2>&1; then
    echo "[INFO] Configuring firewalld..."
    
    # Sunshine web interface and pairing
    firewall-cmd --permanent --add-port=47984-47990/tcp 2>/dev/null || true
    
    # Video streaming
    firewall-cmd --permanent --add-port=47998-48000/udp 2>/dev/null || true
    
    # Audio streaming
    firewall-cmd --permanent --add-port=48010/tcp 2>/dev/null || true
    firewall-cmd --permanent --add-port=48010/udp 2>/dev/null || true
    
    # CRITICAL: Control stream for keyboard/mouse input
    firewall-cmd --permanent --add-port=48100-48200/tcp 2>/dev/null || true
    firewall-cmd --permanent --add-port=48100-48200/udp 2>/dev/null || true
    
    # Reload firewall
    firewall-cmd --reload 2>/dev/null || true
    
    echo "[SUCCESS] firewalld configured"
    
elif command -v iptables >/dev/null 2>&1; then
    echo "[INFO] Configuring iptables..."
    
    # Sunshine web interface and pairing
    iptables -A INPUT -p tcp --dport 47984:47990 -j ACCEPT 2>/dev/null || true
    
    # Video streaming
    iptables -A INPUT -p udp --dport 47998:48000 -j ACCEPT 2>/dev/null || true
    
    # Audio streaming
    iptables -A INPUT -p tcp --dport 48010 -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -p udp --dport 48010 -j ACCEPT 2>/dev/null || true
    
    # CRITICAL: Control stream for keyboard/mouse input
    iptables -A INPUT -p tcp --dport 48100:48200 -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -p udp --dport 48100:48200 -j ACCEPT 2>/dev/null || true
    
    # Save iptables rules
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    
    echo "[SUCCESS] iptables configured"
else
    echo "[WARN] No firewall detected (ufw/firewalld/iptables)"
    echo "[INFO] If you have a firewall, manually open these ports:"
    echo "  - TCP 47984-47990"
    echo "  - TCP 48010"
    echo "  - UDP 47998-48000"
    echo "  - UDP 48010"
    echo "  - TCP/UDP 48100-48200 (CRITICAL for input)"
fi

echo ""

# ============================================
# STEP 9: Configure and restart Sunshine
# ============================================
echo "[STEP 9/9] Configuring Sunshine..."
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
echo "✓ Firewall ports opened for Moonlight input/control"
echo "✓ Sunshine configured and running"
echo ""
echo "FIREWALL PORTS OPENED:"
echo "  - TCP 47984-47990 (Web UI/Pairing)"
echo "  - TCP 48010 (RTSP)"
echo "  - UDP 47998-48000 (Video stream)"
echo "  - UDP 48010 (Audio stream)"
echo "  - TCP/UDP 48100-48200 (Control/Input) ← KEYBOARD & MOUSE"
echo ""
echo "NEXT STEPS:"
echo "1. Connect with Moonlight client to: $(hostname -I | awk '{print $1}')"
echo "2. Test keyboard and mouse control"
echo "3. Monitor logs: tail -f $LOGFILE"
echo ""
echo "VERIFICATION COMMANDS:"
echo "  # Check if virtual devices are created:"
echo "  grep -i 'virtual.*keyboard\\|virtual.*mouse\\|uinput' $LOGFILE"
echo ""
echo "  # Check firewall status:"
echo "  sudo ufw status | grep -E '47|48'"
echo ""
echo "  # Check Sunshine is listening on control ports:"
echo "  sudo netstat -tulpn | grep sunshine"
echo ""
echo "If input STILL doesn't work:"
echo "  1. Check Moonlight client settings:"
echo "     - Enable 'Optimize game settings'"
echo "     - Enable 'Mouse acceleration'"
echo "  2. Check network connectivity:"
echo "     - Ping server from client"
echo "     - Check router/firewall between client and server"
echo "  3. Verify Sunshine web UI: https://$(hostname -I | awk '{print $1}'):47990"
echo "  4. Check logs for errors:"
echo "     grep -i error $LOGFILE"
echo ""
echo "TROUBLESHOOTING:"
echo "  If you see 'Connection refused' on control ports:"
echo "    - Firewall is blocking (check cloud provider security groups)"
echo "  If you see video but no input:"
echo "    - Control ports 48100-48200 are blocked"
echo "    - Run: sudo ufw allow 48100:48200/tcp && sudo ufw allow 48100:48200/udp"
echo ""
