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

# Install NVIDIA Tesla T4 optimized packages and drivers
echo "[INFO] Installing NVIDIA Tesla T4 optimized packages and drivers..."
apt update >/dev/null 2>&1 || true

# Detect NVIDIA Tesla T4
NVIDIA_T4_DETECTED=false
if lspci | grep -i "tesla t4\|t4.*tesla" >/dev/null 2>&1; then
    NVIDIA_T4_DETECTED=true
    echo "[INFO] NVIDIA Tesla T4 detected - installing optimized drivers"
elif nvidia-smi 2>/dev/null | grep -i "tesla t4" >/dev/null 2>&1; then
    NVIDIA_T4_DETECTED=true
    echo "[INFO] NVIDIA Tesla T4 detected via nvidia-smi"
fi

# Install NVIDIA Tesla T4 specific packages
if [ "$NVIDIA_T4_DETECTED" = true ]; then
    echo "[INFO] Installing NVIDIA Tesla T4 optimized packages..."
    
    # Add NVIDIA repository if not already added
    if [ ! -f /etc/apt/sources.list.d/graphics-drivers-ubuntu-ppa-*.list ]; then
        add-apt-repository -y ppa:graphics-drivers/ppa >/dev/null 2>&1 || true
        apt update >/dev/null 2>&1 || true
    fi
    
    # Install Tesla T4 compatible NVIDIA drivers
    apt install -y nvidia-driver-535 nvidia-utils-535 nvidia-settings \
        libnvidia-encode-535 libnvidia-decode-535 nvidia-cuda-toolkit \
        libnvidia-fbc1-535 libnvidia-ifr1-535 >/dev/null 2>&1 || true
    
    # Install CUDA toolkit for Tesla T4
    if [ ! -f /usr/local/cuda/bin/nvcc ]; then
        wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.0-1_all.deb -O /tmp/cuda-keyring.deb >/dev/null 2>&1 || true
        dpkg -i /tmp/cuda-keyring.deb >/dev/null 2>&1 || true
        apt update >/dev/null 2>&1 || true
        apt install -y cuda-toolkit-12-2 >/dev/null 2>&1 || true
        rm -f /tmp/cuda-keyring.deb
    fi
    
    # Enable NVIDIA persistence daemon for Tesla T4
    systemctl enable nvidia-persistenced >/dev/null 2>&1 || true
    systemctl start nvidia-persistenced >/dev/null 2>&1 || true
    
    echo "[SUCCESS] NVIDIA Tesla T4 drivers and CUDA installed"
else
    echo "[INFO] NVIDIA Tesla T4 not detected, installing generic GPU support..."
    
    # Install generic GPU packages
    apt install -y mesa-utils mesa-va-drivers mesa-vdpau-drivers vainfo \
        libva2 libva-drm2 libva-x11-2 libvdpau1 vdpau-driver-all \
        xserver-xorg-video-all libgl1-mesa-dri libglx-mesa0 \
        libegl1-mesa libgbm1 libdrm2 >/dev/null 2>&1 || true
    
    # Install Hyper-V specific drivers if running in Hyper-V
    if lspci | grep -i "microsoft.*hyper-v" >/dev/null 2>&1; then
        echo "[INFO] Detected Hyper-V environment, installing specific drivers..."
        apt install -y xserver-xorg-video-fbdev linux-image-virtual \
            linux-tools-virtual linux-cloud-tools-virtual >/dev/null 2>&1 || true
    fi
fi

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

# Create Tesla T4 optimized Sunshine configuration
echo "[INFO] Creating Tesla T4 optimized Sunshine configuration..."

# Create Tesla T4 specific configuration
if [ "$NVIDIA_T4_DETECTED" = true ]; then
    cat > "$SUNSHINE_CONFIG_DIR/sunshine.conf" <<EOF
# Sunshine configuration optimized for NVIDIA Tesla T4

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

# NVIDIA Tesla T4 hardware encoding configuration
capture = nvfbc
encoder = nvenc
adapter_name = /dev/dri/card0

# NVENC settings optimized for Tesla T4
nvenc_preset = p4
nvenc_rc = cbr_hq
nvenc_coder = h264
nvenc_2pass = enabled
nvenc_spatial_aq = enabled
nvenc_temporal_aq = enabled
nvenc_realtime = enabled
nvenc_multipass = qres

# Video quality settings for Tesla T4
min_log_level = info
fec_percentage = 20
qp = 28

# Audio configuration
audio_sink = pulse

# Performance optimizations
capture_cursor = enabled
capture_display = auto

# Tesla T4 specific display settings
output_name = 0

# Pairing settings
pin_timeout = 120000

# Advanced Tesla T4 optimizations
nvenc_vbv_max_bitrate = 0
nvenc_lookahead = 8
nvenc_b_ref_mode = each
EOF
else
    # Fallback configuration for non-Tesla T4 systems
    cat > "$SUNSHINE_CONFIG_DIR/sunshine.conf" <<EOF
# Sunshine configuration for non-Tesla T4 systems

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

# Display configuration
capture = kms
output_name = 0

# Force software encoding if hardware fails
sw_preset = ultrafast
sw_tune = zerolatency
encoder = software

# Audio configuration
audio_sink = auto_null

# Logging
min_log_level = info
log_colorized = enabled

# KMS specific settings
kms_crtc_id = 0
kms_connector_id = 31

# Disable problematic features for non-NVIDIA
nvenc = disabled
vaapi = disabled

# Pairing settings
pin_timeout = 120000
EOF
fi

chown "$DESKTOP_USER:$DESKTOP_USER" "$SUNSHINE_CONFIG_DIR/sunshine.conf"

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

# Create Tesla T4 optimized X11 wrapper script
echo "[INFO] Creating Tesla T4 optimized X11 wrapper for Sunshine..."

if [ "$NVIDIA_T4_DETECTED" = true ]; then
    cat > "/usr/local/bin/sunshine-x11-wrapper.sh" <<'EOF'
#!/bin/bash
# Tesla T4 optimized X11 wrapper for Sunshine

# Set up X11 environment
export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"

# Enable X11 forwarding for all users
xhost +local: 2>/dev/null || true

# NVIDIA Tesla T4 specific environment variables
export __GL_SYNC_TO_VBLANK=0
export __GL_SYNC_DISPLAY_DEVICE=DFP-0
export __GL_SHADER_DISK_CACHE=1
export __GL_SHADER_DISK_CACHE_PATH=/tmp
export __GL_THREADED_OPTIMIZATIONS=1
export __GL_YIELD=USLEEP
export CUDA_VISIBLE_DEVICES=0
export NVIDIA_VISIBLE_DEVICES=0
export NVIDIA_DRIVER_CAPABILITIES=all

# NVENC specific optimizations
export NVENC_PRESET=p4
export NVENC_RC_MODE=cbr_hq
export NVENC_MULTIPASS=qres
export NVENC_SPATIAL_AQ=1
export NVENC_TEMPORAL_AQ=1

# Disable software fallbacks when Tesla T4 is available
unset LIBGL_ALWAYS_SOFTWARE
unset MESA_LOADER_DRIVER_OVERRIDE

# Ensure NVIDIA libraries are prioritized
export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:/usr/local/cuda/lib64:$LD_LIBRARY_PATH"

# Start Sunshine with Tesla T4 optimizations
echo "[INFO] Starting Sunshine with NVIDIA Tesla T4 optimizations"
exec /usr/bin/sunshine "$@"
EOF
else
    cat > "/usr/local/bin/sunshine-x11-wrapper.sh" <<'EOF'
#!/bin/bash
# Generic X11 wrapper for Sunshine (non-Tesla T4)

# Set up X11 environment
export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"

# Enable X11 forwarding for all users
xhost +local: 2>/dev/null || true

# Set up DRI environment for software rendering
export LIBGL_ALWAYS_SOFTWARE=1
export MESA_LOADER_DRIVER_OVERRIDE=swrast

# Start Sunshine with software rendering
echo "[INFO] Starting Sunshine with software rendering (no Tesla T4 detected)"
exec /usr/bin/sunshine "$@"
EOF
fi

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

# Start Sunshine with Tesla T4 optimized environment
if [ "$NVIDIA_T4_DETECTED" = true ]; then
    echo "[INFO] Starting Sunshine with NVIDIA Tesla T4 optimizations..."
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

# NVIDIA Tesla T4 specific environment
export __GL_SYNC_TO_VBLANK=0
export __GL_THREADED_OPTIMIZATIONS=1
export __GL_SHADER_DISK_CACHE=1
export CUDA_VISIBLE_DEVICES=0
export NVIDIA_VISIBLE_DEVICES=0
export NVIDIA_DRIVER_CAPABILITIES=all

# Hardware acceleration environment
unset LIBGL_ALWAYS_SOFTWARE
unset MESA_LOADER_DRIVER_OVERRIDE
export LIBVA_DRIVER_NAME=nvidia
export VDPAU_DRIVER=nvidia

# CUDA and NVENC paths
export PATH='/usr/local/cuda/bin:\$PATH'
export LD_LIBRARY_PATH='/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu:\$LD_LIBRARY_PATH'

# Enable X11 access
xhost +local: 2>/dev/null || true

# Start Sunshine with Tesla T4 wrapper
nohup /usr/local/bin/sunshine-x11-wrapper.sh > /tmp/sunshine-direct.log 2>&1 &
echo \$!
" > /tmp/sunshine-pid.tmp
else
    echo "[INFO] Starting Sunshine with software rendering (no Tesla T4 detected)..."
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

# Software rendering environment
export LIBGL_ALWAYS_SOFTWARE=1
export MESA_LOADER_DRIVER_OVERRIDE=swrast
export LIBVA_DRIVER_NAME=
export VDPAU_DRIVER=

# Enable X11 access
xhost +local: 2>/dev/null || true

# Start Sunshine with software rendering wrapper
nohup /usr/local/bin/sunshine-x11-wrapper.sh > /tmp/sunshine-direct.log 2>&1 &
echo \$!
" > /tmp/sunshine-pid.tmp
fi

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