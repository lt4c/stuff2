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

# Detect NVIDIA Tesla T4 and Hyper-V environment
NVIDIA_T4_DETECTED=false
HYPERV_DETECTED=false
NVIDIA_CARD=""

# Check for Hyper-V
if lspci | grep -i "microsoft.*hyper-v\|hyperv" >/dev/null 2>&1; then
    HYPERV_DETECTED=true
    echo "[INFO] Hyper-V environment detected"
fi

# Detect NVIDIA GPU
if lspci | grep -i "tesla t4\|t4.*tesla\|nvidia" >/dev/null 2>&1; then
    NVIDIA_T4_DETECTED=true
    echo "[INFO] NVIDIA GPU detected via lspci"
elif nvidia-smi 2>/dev/null | grep -i "tesla t4\|nvidia" >/dev/null 2>&1; then
    NVIDIA_T4_DETECTED=true
    echo "[INFO] NVIDIA GPU detected via nvidia-smi"
fi

# Find the correct NVIDIA card
if [ "$NVIDIA_T4_DETECTED" = true ]; then
    # Find nvidia-drm card
    for card in /dev/dri/card*; do
        if [ -e "$card" ]; then
            DRIVER=$(udevadm info --query=property --name="$card" 2>/dev/null | grep "ID_PATH_TAG" | cut -d= -f2)
            CARD_NAME=$(udevadm info --query=property --name="$card" 2>/dev/null | grep "DRIVER" | cut -d= -f2)
            if echo "$CARD_NAME" | grep -q "nvidia"; then
                NVIDIA_CARD="$card"
                echo "[INFO] Found NVIDIA card: $NVIDIA_CARD"
                break
            fi
        fi
    done
fi

# Install required packages based on detected hardware
echo "[INFO] Installing GPU and display support packages..."
apt update >/dev/null 2>&1 || true

# Install NVIDIA drivers and CUDA if Tesla T4 detected
if [ "$NVIDIA_T4_DETECTED" = true ]; then
    echo "[INFO] Installing NVIDIA Tesla T4 drivers and CUDA toolkit..."
    
    # Add NVIDIA repository
    if [ ! -f /etc/apt/sources.list.d/graphics-drivers-ubuntu-ppa-*.list ]; then
        add-apt-repository -y ppa:graphics-drivers/ppa >/dev/null 2>&1 || true
        apt update >/dev/null 2>&1 || true
    fi
    
    # Install NVIDIA drivers and libraries
    apt install -y nvidia-driver-535 nvidia-utils-535 nvidia-settings \
        libnvidia-encode-535 libnvidia-decode-535 libnvidia-fbc1-535 \
        libnvidia-ifr1-535 libnvidia-gl-535 nvidia-compute-utils-535 >/dev/null 2>&1 || true
    
    # Install CUDA toolkit if not present
    if [ ! -f /usr/local/cuda/bin/nvcc ]; then
        echo "[INFO] Installing CUDA toolkit..."
        wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.0-1_all.deb -O /tmp/cuda-keyring.deb >/dev/null 2>&1 || true
        dpkg -i /tmp/cuda-keyring.deb >/dev/null 2>&1 || true
        apt update >/dev/null 2>&1 || true
        apt install -y cuda-toolkit-12-2 cuda-drivers >/dev/null 2>&1 || true
        rm -f /tmp/cuda-keyring.deb
    fi
    
    # Enable and start NVIDIA persistence daemon
    systemctl enable nvidia-persistenced >/dev/null 2>&1 || true
    systemctl start nvidia-persistenced >/dev/null 2>&1 || true
    
    # Load NVIDIA modules
    modprobe nvidia 2>/dev/null || true
    modprobe nvidia-drm 2>/dev/null || true
    modprobe nvidia-modeset 2>/dev/null || true
    
    # Enable NVIDIA DRM modeset (required for proper KMS support)
    if [ ! -f /etc/modprobe.d/nvidia-drm.conf ]; then
        echo "options nvidia-drm modeset=1" > /etc/modprobe.d/nvidia-drm.conf
        echo "[INFO] Enabled NVIDIA DRM modeset"
    fi
    
    # Configure NVIDIA for Hyper-V if both are detected
    if [ "$HYPERV_DETECTED" = true ]; then
        echo "[INFO] Configuring NVIDIA for Hyper-V environment..."
        
        # Disable Hyper-V synthetic video to prioritize NVIDIA
        if [ -f /etc/modprobe.d/hyperv.conf ]; then
            sed -i '/^blacklist hyperv_fb/d' /etc/modprobe.d/hyperv.conf 2>/dev/null || true
        fi
        echo "blacklist hyperv_fb" >> /etc/modprobe.d/hyperv.conf
        
        # Set NVIDIA as primary GPU
        echo "[INFO] Setting NVIDIA as primary GPU..."
    fi
    
    echo "[SUCCESS] NVIDIA Tesla T4 drivers installed"
fi

# Install Hyper-V specific drivers
if [ "$HYPERV_DETECTED" = true ]; then
    echo "[INFO] Installing Hyper-V specific drivers..."
    apt install -y xserver-xorg-video-fbdev linux-image-virtual \
        linux-tools-virtual linux-cloud-tools-virtual >/dev/null 2>&1 || true
fi

# Install Mesa and VA-API drivers for fallback
apt install -y mesa-utils mesa-va-drivers mesa-vdpau-drivers vainfo \
    libva2 libva-drm2 libva-x11-2 libvdpau1 vdpau-driver-all \
    xserver-xorg-video-all libgl1-mesa-dri libglx-mesa0 \
    libegl1-mesa libgbm1 libdrm2 libdrm-dev >/dev/null 2>&1 || true

# Setup comprehensive uinput permissions for Sunshine virtual input devices
echo "[INFO] Setting up comprehensive uinput permissions for virtual keyboard/mouse..."

# Ensure required kernel modules are loaded
echo "[INFO] Loading required kernel modules..."
REQUIRED_MODULES="uinput evdev"
for module in $REQUIRED_MODULES; do
    if ! lsmod | grep -q "^$module"; then
        echo "[INFO] Loading $module kernel module..."
        if ! modprobe "$module" 2>/dev/null; then
            echo "[WARN] Failed to load $module module"
        else
            echo "[INFO] Successfully loaded $module module"
        fi
    else
        echo "[INFO] $module module already loaded"
    fi
done

# Create required groups
echo "[INFO] Creating required groups for input devices..."
groupadd -f uinput 2>/dev/null || true
groupadd -f input 2>/dev/null || true
groupadd -f video 2>/dev/null || true
groupadd -f render 2>/dev/null || true

# Create uinput device if it doesn't exist
if [ ! -e /dev/uinput ]; then
    echo "[INFO] Creating uinput device node..."
    mknod /dev/uinput c 10 223 2>/dev/null || true
fi

# Set comprehensive permissions on uinput device
echo "[INFO] Setting comprehensive uinput device permissions..."
chmod 666 /dev/uinput 2>/dev/null || echo "[WARN] Failed to set uinput permissions"
chown root:uinput /dev/uinput 2>/dev/null || true

# Add desktop user to all required groups
echo "[INFO] Adding user $DESKTOP_USER to all required groups..."
REQUIRED_GROUPS="uinput input video render audio"
for group in $REQUIRED_GROUPS; do
    if ! groups "$DESKTOP_USER" | grep -q "$group"; then
        echo "[INFO] Adding user $DESKTOP_USER to $group group..."
        usermod -aG "$group" "$DESKTOP_USER" 2>/dev/null || echo "[WARN] Failed to add user to $group group"
    else
        echo "[INFO] User $DESKTOP_USER already in $group group"
    fi
done

# Set permissions on all input devices
echo "[INFO] Setting permissions on input devices..."
if ls /dev/input/event* >/dev/null 2>&1; then
    chmod 664 /dev/input/event* 2>/dev/null || true
    chgrp input /dev/input/event* 2>/dev/null || true
fi

# Set permissions on mouse devices
if ls /dev/input/mouse* >/dev/null 2>&1; then
    chmod 664 /dev/input/mouse* 2>/dev/null || true
    chgrp input /dev/input/mouse* 2>/dev/null || true
fi

# Set permissions on js (joystick) devices
if ls /dev/input/js* >/dev/null 2>&1; then
    chmod 664 /dev/input/js* 2>/dev/null || true
    chgrp input /dev/input/js* 2>/dev/null || true
fi

# Verify uinput access
if [ -w /dev/uinput ]; then
    echo "[SUCCESS] uinput device permissions: OK - Sunshine can create virtual devices"
else
    echo "[ERROR] uinput device still not writable"
    echo "[ERROR] Virtual keyboard/mouse will NOT work in Sunshine"
    
    # Try alternative permission methods
    echo "[INFO] Attempting alternative permission setup..."
    chmod 777 /dev/uinput 2>/dev/null || true
    
    if [ -w /dev/uinput ]; then
        echo "[SUCCESS] Alternative permissions worked"
    else
        echo "[ERROR] All permission attempts failed"
    fi
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

# Create comprehensive udev rules for persistent uinput permissions
echo "[INFO] Creating comprehensive persistent udev rules for Sunshine..."
tee /etc/udev/rules.d/99-sunshine-comprehensive.rules >/dev/null <<'EOF'
# Comprehensive uinput device permissions for Sunshine streaming
# uinput device - allow creation of virtual input devices
KERNEL=="uinput", MODE="0666", GROUP="uinput", OPTIONS+="static_node=uinput"
SUBSYSTEM=="misc", KERNEL=="uinput", MODE="0666", GROUP="uinput", TAG+="uaccess"

# Input event devices - keyboard, mouse, touchpad events
SUBSYSTEM=="input", KERNEL=="event*", MODE="0664", GROUP="input"
SUBSYSTEM=="input", KERNEL=="mouse*", MODE="0664", GROUP="input"
SUBSYSTEM=="input", KERNEL=="js*", MODE="0664", GROUP="input"

# GPU devices for hardware acceleration
SUBSYSTEM=="drm", KERNEL=="card*", MODE="0666", GROUP="video"
SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0666", GROUP="render"

# Additional input devices
SUBSYSTEM=="input", ATTRS{name}=="*", MODE="0664", GROUP="input"
KERNEL=="hidraw*", MODE="0664", GROUP="input"

# Ensure uinput module loads on boot
ACTION=="add", SUBSYSTEM=="misc", KERNEL=="uinput", RUN+="/sbin/modprobe uinput"
EOF

# Also create module loading configuration
echo "[INFO] Creating module loading configuration..."
tee /etc/modules-load.d/sunshine-uinput.conf >/dev/null <<'EOF'
# Load uinput module for Sunshine virtual input devices
uinput
evdev
EOF

# Create systemd service to ensure proper permissions on boot
echo "[INFO] Creating systemd service for persistent permissions..."
tee /etc/systemd/system/sunshine-permissions.service >/dev/null <<EOF
[Unit]
Description=Set Sunshine input device permissions
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'chmod 666 /dev/uinput 2>/dev/null || true'
ExecStart=/bin/bash -c 'chgrp uinput /dev/uinput 2>/dev/null || true'
ExecStart=/bin/bash -c 'chmod 664 /dev/input/event* 2>/dev/null || true'
ExecStart=/bin/bash -c 'chgrp input /dev/input/event* 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable the service
systemctl daemon-reload
systemctl enable sunshine-permissions.service 2>/dev/null || true

# Reload udev rules and trigger events
echo "[INFO] Reloading udev rules and triggering device events..."
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --subsystem-match=misc --action=add 2>/dev/null || true
udevadm trigger --subsystem-match=input --action=change 2>/dev/null || true
udevadm trigger --subsystem-match=drm --action=change 2>/dev/null || true

echo "[SUCCESS] Comprehensive udev rules and persistent permissions configured"

# Fix GPU and display issues for Sunshine
echo "[INFO] Configuring GPU and display settings for Sunshine..."

# Set proper permissions on DRI devices
echo "[INFO] Setting permissions on DRI devices..."
if ls /dev/dri/card* >/dev/null 2>&1; then
    chmod 666 /dev/dri/card* 2>/dev/null || true
    chgrp video /dev/dri/card* 2>/dev/null || true
fi

if ls /dev/dri/renderD* >/dev/null 2>&1; then
    chmod 666 /dev/dri/renderD* 2>/dev/null || true
    chgrp render /dev/dri/renderD* 2>/dev/null || true
fi

# Create Sunshine configuration directory and config
SUNSHINE_CONFIG_DIR="/home/$DESKTOP_USER/.config/sunshine"
mkdir -p "$SUNSHINE_CONFIG_DIR"
chown "$DESKTOP_USER:$DESKTOP_USER" "$SUNSHINE_CONFIG_DIR"

# Create Tesla T4 specific configuration
if [ "$NVIDIA_T4_DETECTED" = true ]; then
    # Determine the correct adapter name
    ADAPTER_NAME="/dev/dri/card0"
    if [ -n "$NVIDIA_CARD" ]; then
        ADAPTER_NAME="$NVIDIA_CARD"
    fi
    
    cat > "$SUNSHINE_CONFIG_DIR/sunshine.conf" <<EOF
# Sunshine configuration optimized for NVIDIA Tesla T4 in Hyper-V

# Network and pairing configuration
address_family = both
bind_address = 0.0.0.0
port = 47989
https_port = 47990
ping_timeout = 30000
channels = 5

# Certificate and SSL configuration
cert = /home/$DESKTOP_USER/.config/sunshine/sunshine.cert
pkey = /home/$DESKTOP_USER/.config/sunshine/sunshine.key

# Display capture configuration - Use X11 instead of KMS for Hyper-V + NVIDIA
capture = x11
encoder = software
adapter_name = $ADAPTER_NAME

# Software encoding settings (fallback for compatibility)
sw_preset = ultrafast
sw_tune = zerolatency

# Video quality settings
min_log_level = info
fec_percentage = 20
qp = 28
bitrate = 20000

# Audio configuration - Fix PulseAudio issues
audio_sink = 
virtual_sink = sunshine-stereo

# Performance optimizations
capture_cursor = enabled

# Display settings
output_name = 0

# Pairing settings
pin_timeout = 120000

# Disable problematic features in Hyper-V
nvenc = disabled
vaapi = disabled
vdpau = disabled
EOF

    # Note: NVENC may not work properly with nvidia-drm in Hyper-V
    # The error "GPU driver doesn't support universal planes" indicates
    # that the NVIDIA driver in Hyper-V passthrough mode has limitations
    echo "[WARN] NVIDIA Tesla T4 detected but may have limited KMS support in Hyper-V"
    echo "[INFO] Using X11 capture mode for better compatibility"
fi

chown "$DESKTOP_USER:$DESKTOP_USER" "$SUNSHINE_CONFIG_DIR/sunshine.conf"

# Configure PulseAudio for Sunshine
echo "[INFO] Configuring PulseAudio for Sunshine..."

# Create PulseAudio configuration for virtual sink
mkdir -p "/home/$DESKTOP_USER/.config/pulse"
cat > "/home/$DESKTOP_USER/.config/pulse/default.pa" <<'EOF'
# Load default PulseAudio configuration
.include /etc/pulse/default.pa

# Create Sunshine virtual sink
load-module module-null-sink sink_name=sunshine-stereo sink_properties=device.description="Sunshine-Virtual-Sink"

# Set sunshine-stereo as default
set-default-sink sunshine-stereo
EOF

chown -R "$DESKTOP_USER:$DESKTOP_USER" "/home/$DESKTOP_USER/.config/pulse"

# Restart PulseAudio for the user
su - "$DESKTOP_USER" -c "
    pulseaudio --kill 2>/dev/null || true
    sleep 1
    pulseaudio --start --log-target=syslog 2>/dev/null || true
" || true

echo "[SUCCESS] PulseAudio configured for Sunshine"

# Generate SSL certificates for Sunshine pairing
echo "[INFO] Generating SSL certificates for Sunshine pairing..."
su - "$DESKTOP_USER" -c "
cd ~/.config/sunshine

# Generate private key
openssl genrsa -out sunshine.key 2048 2>/dev/null

# Generate self-signed certificate
openssl req -new -x509 -key sunshine.key -out sunshine.cert -days 365 -subj '/C=US/ST=State/L=City/O=Sunshine/CN=sunshine' 2>/dev/null

# Set proper permissions
chmod 600 sunshine.key sunshine.cert

echo '[INFO] SSL certificates generated successfully'
" 2>/dev/null || echo "[WARN] Certificate generation failed, Sunshine will create its own"

# Create pairing helper script
echo "[INFO] Creating pairing helper script..."
cat > "/usr/local/bin/sunshine-pair.sh" <<'EOF'
#!/bin/bash
# Sunshine pairing helper script

echo "=== SUNSHINE PAIRING HELPER ==="
echo "This script helps with Moonlight pairing issues"
echo ""

# Check if Sunshine is running
if ! pgrep -x sunshine >/dev/null; then
    echo "[ERROR] Sunshine is not running!"
    echo "Please start Sunshine first with: sudo ./sunshine_direct.sh"
    exit 1
fi

# Get server IP
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "Server IP: $SERVER_IP"
echo "Web UI: https://$SERVER_IP:47990"
echo ""

# Check certificates
CERT_DIR="/home/$(whoami)/.config/sunshine"
if [ -f "$CERT_DIR/sunshine.cert" ] && [ -f "$CERT_DIR/sunshine.key" ]; then
    echo "[OK] SSL certificates found"
else
    echo "[WARN] SSL certificates missing, generating new ones..."
    mkdir -p "$CERT_DIR"
    cd "$CERT_DIR"
    openssl genrsa -out sunshine.key 2048 2>/dev/null
    openssl req -new -x509 -key sunshine.key -out sunshine.cert -days 365 \
        -subj "/C=US/ST=State/L=City/O=Sunshine/CN=$SERVER_IP" 2>/dev/null
    chmod 600 sunshine.key sunshine.cert
    echo "[OK] New certificates generated"
    echo "[INFO] You may need to restart Sunshine for changes to take effect"
fi

echo ""
echo "=== PAIRING INSTRUCTIONS ==="
echo "1. Open Moonlight on your client device"
echo "2. Add PC manually with IP: $SERVER_IP"
echo "3. Accept the SSL certificate warning"
echo "4. Enter the PIN shown in Moonlight"
echo "5. If pairing fails, try these steps:"
echo "   - Restart Sunshine: sudo pkill sunshine && sudo ./sunshine_direct.sh"
echo "   - Clear Moonlight cache/data on client"
echo "   - Try connecting from same network first"
echo "   - Check firewall: sudo ufw status"
echo ""

# Show recent Sunshine logs
echo "=== RECENT SUNSHINE LOGS ==="
tail -20 /tmp/sunshine-direct.log 2>/dev/null || echo "No logs found"
EOF

chmod +x "/usr/local/bin/sunshine-pair.sh"

# Create X11 wrapper script to ensure proper display detection
echo "[INFO] Creating X11 display wrapper for Sunshine..."
cat > "/usr/local/bin/sunshine-x11-wrapper.sh" <<'EOF'
#!/bin/bash
# X11 wrapper for Sunshine to ensure proper display detection

# Set up X11 environment
export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"

# Enable X11 forwarding for all users
xhost +local: 2>/dev/null || true

# Set up DRI environment
export LIBGL_ALWAYS_SOFTWARE=1
export MESA_LOADER_DRIVER_OVERRIDE=swrast

# Start Sunshine with proper environment
exec /usr/bin/sunshine "$@"
EOF

chmod +x "/usr/local/bin/sunshine-x11-wrapper.sh"

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

# Final verification of uinput capabilities for Sunshine
echo "[INFO] Performing final verification of virtual input device capabilities..."

# Test uinput device creation capability
echo "[INFO] Testing uinput device creation capability..."
if [ -w /dev/uinput ]; then
    echo "[SUCCESS] /dev/uinput is writable - virtual devices can be created"
    
    # Test if we can actually create a virtual device (quick test)
    su - "$DESKTOP_USER" -c "
        if command -v python3 >/dev/null 2>&1; then
            python3 -c '
import os
try:
    fd = os.open(\"/dev/uinput\", os.O_WRONLY)
    os.close(fd)
    print(\"[SUCCESS] Virtual input device creation test: PASSED\")
except Exception as e:
    print(f\"[ERROR] Virtual input device creation test: FAILED - {e}\")
' 2>/dev/null || echo '[INFO] Python test skipped'
        fi
    " || true
else
    echo "[ERROR] /dev/uinput is not writable - virtual devices CANNOT be created"
    echo "[ERROR] Sunshine virtual keyboard/mouse will NOT work!"
fi

# Verify user group memberships
echo "[INFO] Verifying user group memberships for $DESKTOP_USER..."
USER_GROUPS=$(groups "$DESKTOP_USER" 2>/dev/null || echo "")
for required_group in uinput input video render audio; do
    if echo "$USER_GROUPS" | grep -q "$required_group"; then
        echo "[SUCCESS] User $DESKTOP_USER is in $required_group group"
    else
        echo "[ERROR] User $DESKTOP_USER is NOT in $required_group group"
    fi
done

# Test input device access
echo "[INFO] Testing input device access..."
INPUT_DEVICES_COUNT=$(ls /dev/input/event* 2>/dev/null | wc -l)
if [ "$INPUT_DEVICES_COUNT" -gt 0 ]; then
    echo "[SUCCESS] Found $INPUT_DEVICES_COUNT input event devices"
    WRITABLE_DEVICES=$(find /dev/input/event* -writable 2>/dev/null | wc -l)
    echo "[INFO] $WRITABLE_DEVICES input devices are writable"
else
    echo "[WARN] No input event devices found"
fi

echo "[INFO] Starting Sunshine as user $DESKTOP_USER to stream KDE Plasma desktop"
echo "[INFO] This will capture the desktop session for Moonlight streaming"
echo "[INFO] Virtual keyboard/mouse should work if all tests above passed"
echo "[INFO] Press Ctrl+C to stop following logs (Sunshine will continue running)"

# Configure network settings for Sunshine
echo "[INFO] Configuring network settings for Sunshine..."

# Open firewall ports for Sunshine
if command -v ufw >/dev/null 2>&1; then
    echo "[INFO] Opening firewall ports for Sunshine..."
    ufw allow 47984:47990/tcp >/dev/null 2>&1 || true
    ufw allow 47998:48010/udp >/dev/null 2>&1 || true
    ufw allow 48100:48200/tcp >/dev/null 2>&1 || true
fi

# Start Sunshine as the desktop user with comprehensive environment
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

# GPU and Mesa environment
export LIBGL_ALWAYS_SOFTWARE=1
export MESA_LOADER_DRIVER_OVERRIDE=swrast
export LIBVA_DRIVER_NAME=
export VDPAU_DRIVER=

# Enable X11 access
xhost +local: 2>/dev/null || true

# Start Sunshine with the X11 wrapper
nohup /usr/local/bin/sunshine-x11-wrapper.sh > /tmp/sunshine-direct.log 2>&1 &
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
echo "=== MOONLIGHT PAIRING ==="
echo "1. Open Moonlight on your client device"
echo "2. Add PC manually with this server's IP address"
echo "3. Accept the SSL certificate warning (self-signed certificate)"
echo "4. Enter the PIN exactly as shown in Moonlight"
echo "5. You should see KDE Plasma desktop (not terminal)"
echo ""
echo "=== PAIRING TROUBLESHOOTING ==="
echo "If pairing fails with 'incorrect PIN' error:"
echo "- Run: /usr/local/bin/sunshine-pair.sh (for detailed help)"
echo "- Clear Moonlight app data/cache on client device"
echo "- Restart Sunshine: sudo pkill sunshine && sudo ./sunshine_direct.sh"
echo "- Try pairing from the same network first"
echo "- Check that SSL certificates were generated correctly"
echo ""
echo "If you see 'Couldn't find monitor' errors:"
echo "- This is normal in virtual environments (Hyper-V/VMware)"
echo "- Sunshine will fall back to software encoding (libx264)"
echo "- Performance may be lower but streaming should still work"
echo ""
echo "If you see 'Ping Timeout' errors:"
echo "- Check firewall settings: sudo ufw status"
echo "- Ensure ports 47984-47990 (TCP) and 47998-48010 (UDP) are open"
echo "- Try connecting from the same network first"
echo ""
echo "If virtual input doesn't work:"
echo "- Check that uinput permissions were set correctly above"
echo "- You may need to log out and back in for group changes"
echo ""
echo "=== QUICK COMMANDS ==="
echo "Pairing help: /usr/local/bin/sunshine-pair.sh"
echo "Restart Sunshine: sudo pkill sunshine && sudo ./sunshine_direct.sh"
echo "Check logs: tail -f /tmp/sunshine-direct.log"
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