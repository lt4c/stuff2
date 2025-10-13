#!/usr/bin/env bash
# lt4c_full_tigervnc_sunshine_autoapps_deb.sh
# KDE Plasma + XRDP (tuned) + TigerVNC (:0) + Sunshine (.deb + auto-add apps) + Steam (Flatpak) + Chromium (Flatpak)
# Patched: refresh flatpak/user env without force-restarting VNC; ensure RDP (xrdp) ready for Windows clients

set -Eeuo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "[ERROR] Please run this script as root." >&2
  exit 1
fi

# ======================= CONFIG =======================
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none
LOG="/var/log/a_sh_install.log"

USER_NAME="${USER_NAME:-lt4c}"
USER_PASS="${USER_PASS:-lt4c@2025}"
VNC_PASS="${VNC_PASS:-lt4c}"
GEOM="${GEOM:-1920x1080}"
VNC_PORT="${VNC_PORT:-5900}"
SUN_HTTP_TLS_PORT="${SUN_HTTP_TLS_PORT:-47990}"

# Multi-session configuration
MAX_SESSIONS="${MAX_SESSIONS:-5}"
ENABLE_MULTI_SESSION="${ENABLE_MULTI_SESSION:-true}"

# NVIDIA Tesla T4 optimization flags
NVIDIA_T4_OPTIMIZATIONS="${NVIDIA_T4_OPTIMIZATIONS:-true}"

ENABLE_VIGEM="${ENABLE_VIGEM:-false}"
SUN_DEB_URL="${SUN_DEB_URL:-}"

step(){ echo "[BƯỚC] $*"; }

# =================== PREPARE ===================
: >"$LOG"
apt update -qq >>"$LOG" 2>&1 || true
apt -y install tmux iproute2 >>"$LOG" 2>&1 || true

step "0/11 Chuẩn bị môi trường & công cụ cơ bản"
mkdir -p /etc/needrestart/conf.d
echo '$nrconf{restart} = "a";' >/etc/needrestart/conf.d/zzz-auto.conf || true
apt -y purge needrestart >>"$LOG" 2>&1 || true
systemctl stop unattended-upgrades >>"$LOG" 2>&1 || true
systemctl disable unattended-upgrades >>"$LOG" 2>&1 || true
apt -y -o Dpkg::Use-Pty=0 install \
  curl wget jq ca-certificates gnupg gnupg2 lsb-release apt-transport-https software-properties-common \
  sudo dbus-x11 xdg-utils desktop-file-utils dconf-cli binutils >>"$LOG" 2>&1

step "0.1/11 Đảm bảo libstdc++6 có GLIBCXX_3.4.32"
GLIBCXX_REQUIRED="GLIBCXX_3.4.32"
LIBSTDCXX_PATH="$(ldconfig -p 2>/dev/null | awk '/libstdc\\+\\+\\.so\\.6/ {print $4; exit}')"
check_glibcxx() {
  local lib_path="$1"
  [[ -z "$lib_path" ]] && return 1
  if strings "$lib_path" 2>/dev/null | grep -q "$GLIBCXX_REQUIRED"; then
    return 0
  fi
  return 1
}

if ! check_glibcxx "$LIBSTDCXX_PATH"; then
  step "0.1.1/11 Cập nhật libstdc++6 từ PPA ubuntu-toolchain-r/test"
  add-apt-repository -y ppa:ubuntu-toolchain-r/test >>"$LOG" 2>&1 || true
  apt update >>"$LOG" 2>&1
  apt -y install libstdc++6 >>"$LOG" 2>&1
  LIBSTDCXX_PATH="$(ldconfig -p 2>/dev/null | awk '/libstdc\\+\\+\\.so\\.6/ {print $4; exit}')"
fi

if ! check_glibcxx "$LIBSTDCXX_PATH"; then
  echo "[CẢNH BÁO] Không tìm thấy biểu tượng ${GLIBCXX_REQUIRED} trong libstdc++6 sau khi cập nhật. Sunshine có thể không chạy đúng." | tee -a "$LOG"
else
  echo "[INFO] libstdc++6 đã có ${GLIBCXX_REQUIRED}." >>"$LOG"
fi

# Verify GLIBCXX availability for user lt4c specifically
step "0.1.2/11 Kiểm tra GLIBCXX cho user ${USER_NAME}"
if id -u "$USER_NAME" >/dev/null 2>&1; then
  # Test GLIBCXX availability as the target user
  su - "$USER_NAME" -c "
    echo '[INFO] Testing GLIBCXX availability for user $USER_NAME...'
    LIBSTDCXX_USER_PATH=\"\$(ldconfig -p 2>/dev/null | awk '/libstdc\\\\+\\\\+\\.so\\.6/ {print \$4; exit}')\"
    if [ -n \"\$LIBSTDCXX_USER_PATH\" ] && strings \"\$LIBSTDCXX_USER_PATH\" 2>/dev/null | grep -q '$GLIBCXX_REQUIRED'; then
      echo '[INFO] GLIBCXX_3.4.32 available for user $USER_NAME'
    else
      echo '[WARN] GLIBCXX_3.4.32 not found for user $USER_NAME'
      echo '[INFO] Updating library cache for user...'
      ldconfig 2>/dev/null || true
    fi
  " >>"$LOG" 2>&1 || true
  
  # Ensure user has access to updated libraries
  echo "[INFO] Ensuring user ${USER_NAME} has access to updated GLIBCXX libraries" >>"$LOG"
  
  # Update library cache and environment for the user
  su - "$USER_NAME" -c "
    # Update user library cache
    ldconfig 2>/dev/null || true
    
    # Add library paths to user environment if needed
    if [ ! -f ~/.bashrc ] || ! grep -q 'LD_LIBRARY_PATH' ~/.bashrc 2>/dev/null; then
      echo '# Ensure access to updated libraries' >> ~/.bashrc
      echo 'export LD_LIBRARY_PATH=\"/usr/lib/x86_64-linux-gnu:\$LD_LIBRARY_PATH\"' >> ~/.bashrc
    fi
    
    # Test if Sunshine can find required symbols
    if command -v sunshine >/dev/null 2>&1; then
      echo '[INFO] Testing Sunshine GLIBCXX compatibility...'
      timeout 5 sunshine --help >/dev/null 2>&1 && echo '[INFO] Sunshine GLIBCXX test: OK' || echo '[WARN] Sunshine GLIBCXX test: FAILED'
    fi
  " >>"$LOG" 2>&1 || true
else
  echo "[WARN] User ${USER_NAME} not found, skipping user-specific GLIBCXX verification" >>"$LOG"
fi

# Cleanup nếu trước đó đã có code/x11vnc
apt -y purge code x11vnc >>"$LOG" 2>&1 || true
systemctl disable --now x11vnc.service >>"$LOG" 2>&1 || true
rm -f /etc/systemd/system/x11vnc.service

# =================== USER ===================
step "1/11 Tạo user ${USER_NAME}"
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "LT4C" "$USER_NAME" >>"$LOG" 2>&1
  echo "${USER_NAME}:${USER_PASS}" | chpasswd
  usermod -aG sudo "$USER_NAME"
fi
# Add user to essential groups for Sunshine streaming
usermod -aG video,render,audio,input,uinput "$USER_NAME" 2>/dev/null || true
USER_UID="$(id -u "$USER_NAME")"

# =================== DESKTOP + XRDP + TigerVNC ===================
step "2/11 Cài KDE Plasma + XRDP + TigerVNC + NVIDIA Tesla T4"

# Install NVIDIA drivers and CUDA for Tesla T4
if [[ "$NVIDIA_T4_OPTIMIZATIONS" == "true" ]]; then
  step "2.1/11 Cài NVIDIA Tesla T4 drivers và CUDA"
  
  # Add NVIDIA repository
  apt -y install software-properties-common >>"$LOG" 2>&1 || true
  add-apt-repository -y ppa:graphics-drivers/ppa >>"$LOG" 2>&1 || true
  
  # Install NVIDIA driver (Tesla T4 compatible)
  apt update >>"$LOG" 2>&1 || true
  apt -y install nvidia-driver-535 nvidia-utils-535 >>"$LOG" 2>&1 || true
  
  # Install CUDA toolkit for Tesla T4
  wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.0-1_all.deb -O /tmp/cuda-keyring.deb >>"$LOG" 2>&1 || true
  dpkg -i /tmp/cuda-keyring.deb >>"$LOG" 2>&1 || true
  apt update >>"$LOG" 2>&1 || true
  apt -y install cuda-toolkit-12-2 nvidia-gds >>"$LOG" 2>&1 || true
  
  # Install additional NVIDIA libraries for streaming
  apt -y install libnvidia-encode1 libnvidia-decode1 nvidia-cuda-toolkit >>"$LOG" 2>&1 || true
  
  # Configure NVIDIA persistence daemon
  systemctl enable nvidia-persistenced >>"$LOG" 2>&1 || true
  
  echo "[INFO] NVIDIA Tesla T4 drivers installed. Reboot may be required." >>"$LOG"
fi

apt -y install \
  kde-standard sddm xorg \
  xrdp xorgxrdp pulseaudio \
  tigervnc-standalone-server \
  remmina remmina-plugin-rdp remmina-plugin-vnc flatpak \
  mesa-vulkan-drivers libgl1-mesa-dri libasound2 libpulse0 libxkbcommon0 \
  vainfo vdpauinfo nvidia-vaapi-driver >>"$LOG" 2>&1

# Ensure xrdp is enabled and uses our startwm (Plasma session)
systemctl enable --now xrdp >>"$LOG" 2>&1 || true

# Configure XRDP for better reconnection handling
XRDP_INI="/etc/xrdp/xrdp.ini"
if [[ -f "$XRDP_INI" ]]; then
  # Backup original config
  cp "$XRDP_INI" "$XRDP_INI.backup" 2>/dev/null || true
  
  # Configure global XRDP settings for better reconnection
  sed -i 's/^fork=.*/fork=true/' "$XRDP_INI" 2>/dev/null || true
  sed -i 's/^tcp_nodelay=.*/tcp_nodelay=true/' "$XRDP_INI" 2>/dev/null || true
  sed -i 's/^tcp_keepalive=.*/tcp_keepalive=true/' "$XRDP_INI" 2>/dev/null || true
  sed -i 's/^use_fastpath=.*/use_fastpath=both/' "$XRDP_INI" 2>/dev/null || true
  sed -i 's/^security_layer=.*/security_layer=negotiate/' "$XRDP_INI" 2>/dev/null || true
  sed -i 's/^certificate=.*/certificate=/' "$XRDP_INI" 2>/dev/null || true
  sed -i 's/^key_file=.*/key_file=/' "$XRDP_INI" 2>/dev/null || true
  sed -i 's/^autorun=.*/autorun=Plasma Shared TigerVNC/' "$XRDP_INI" 2>/dev/null || true
  
  # Add reconnection-friendly VNC session configuration
  if ! grep -q 'Plasma Shared TigerVNC' "$XRDP_INI" 2>/dev/null; then
    cat <<EOF >>"$XRDP_INI"

[Plasma Shared TigerVNC]
name=Plasma Shared TigerVNC
lib=libvnc.so
username=ask
password=ask
ip=127.0.0.1
port=${VNC_PORT}
chansrvport=ask
code=20
EOF
  fi
  
  # Add direct Plasma session as fallback
  if ! grep -q 'Plasma Direct' "$XRDP_INI" 2>/dev/null; then
    cat <<EOF >>"$XRDP_INI"

[Plasma Direct]
name=Plasma Direct
lib=libxup.so
username=ask
password=ask
ip=127.0.0.1
port=-1
code=10
EOF
  fi
fi

# Configure XRDP session manager for better cleanup
SESMAN_INI="/etc/xrdp/sesman.ini"
if [[ -f "$SESMAN_INI" ]]; then
  # Backup original config
  cp "$SESMAN_INI" "$SESMAN_INI.backup" 2>/dev/null || true
  
  # Configure session management for reconnection
  sed -i 's/^EnableUserWindowManager=.*/EnableUserWindowManager=true/' "$SESMAN_INI" 2>/dev/null || true
  sed -i 's/^KillDisconnected=.*/KillDisconnected=false/' "$SESMAN_INI" 2>/dev/null || true
  sed -i 's/^DisconnectedTimeLimit=.*/DisconnectedTimeLimit=0/' "$SESMAN_INI" 2>/dev/null || true
  sed -i 's/^IdleTimeLimit=.*/IdleTimeLimit=0/' "$SESMAN_INI" 2>/dev/null || true
  sed -i 's/^Policy=.*/Policy=Default/' "$SESMAN_INI" 2>/dev/null || true
  sed -i 's/^MaxSessions=.*/MaxSessions=10/' "$SESMAN_INI" 2>/dev/null || true
fi

# =================== Steam/Chromium (Flatpak) + Heroic ===================
step "3/11 Cài Chromium + Steam (Flatpak --system) & Heroic (user)"
flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo >>"$LOG" 2>&1 || true
# Cài Chromium + Steam (hệ thống)
flatpak -y --system install flathub org.chromium.Chromium com.valvesoftware.Steam >>"$LOG" 2>&1 || true
# Shims tiện gọi nhanh
printf '%s\n' '#!/bin/sh' 'exec flatpak run org.chromium.Chromium "$@"' >/usr/local/bin/chromium && chmod +x /usr/local/bin/chromium
printf '%s\n' '#!/bin/sh' 'exec flatpak run com.valvesoftware.Steam "$@"' >/usr/local/bin/steam && chmod +x /usr/local/bin/steam
# Heroic (cài theo user)
su - "$USER_NAME" -c 'flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo' >>"$LOG" 2>&1 || true
su - "$USER_NAME" -c 'flatpak -y install flathub com.heroicgameslauncher.hgl' >>"$LOG" 2>&1 || true
# Bảo đảm XDG paths có Flatpak exports
cat >/etc/profile.d/flatpak-xdg.sh <<'EOF'
export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:/var/lib/flatpak/exports/share:$HOME/.local/share/flatpak/exports/share"
EOF
chmod +x /etc/profile.d/flatpak-xdg.sh

# --- Refresh user environment so flatpak apps become available without reboot ---
step "3.1/11 Refresh user ${USER_NAME} environment for Flatpak (no reboot)"

# Ensure systemd user services can run even when not logged in
if command -v loginctl >/dev/null 2>&1; then
  loginctl enable-linger "$USER_NAME" >>"$LOG" 2>&1 || true
fi

# Ensure /etc/profile.d/flatpak-xdg.sh is sourced for interactive/logged-in shells
USER_PROFILE="/home/${USER_NAME}/.profile"
if ! grep -Fxq "source /etc/profile.d/flatpak-xdg.sh" "$USER_PROFILE" 2>/dev/null; then
  {
    echo ""
    echo "# Source system-wide Flatpak XDG paths"
    echo "if [ -f /etc/profile.d/flatpak-xdg.sh ]; then"
    echo "  . /etc/profile.d/flatpak-xdg.sh"
    echo "fi"
  } >> "$USER_PROFILE"
  chown "$USER_NAME:$USER_NAME" "$USER_PROFILE" || true
fi

# Trigger a flatpak repair/update under the user's DBus session (best-effort)
# Use dbus-run-session so Flatpak has a valid session DBUS even when no GUI session exists
su - "$USER_NAME" -c 'if command -v flatpak >/dev/null 2>&1; then
  echo "[INFO] Running flatpak repair/update for user..."
  dbus-run-session -- flatpak --system repair || true
  dbus-run-session -- flatpak --system update -y || true
fi' || true

# Reload user systemd --user units lightly (no global restart)
su - "$USER_NAME" -c 'systemctl --user daemon-reload 2>/dev/null || true'

# Reload Plasma session environment (best-effort)
su - "$USER_NAME" -c 'pkill -HUP plasmashell || true'
su - "$USER_NAME" -c 'pkill -HUP kded5 || true'
# Update desktop database for user
su - "$USER_NAME" -c 'update-desktop-database ~/.local/share/applications || true'

step "3.2/11 Refresh complete (flatpak env attempted for ${USER_NAME})"

# ---------------- Disable KDE animations (reduce lag) ----------------
step "4/11 Tinh chỉnh KDE Plasma giảm hiệu ứng (best-effort)"
su - "$USER_NAME" -c 'dbus-run-session -- kwriteconfig5 --file kwinrc --group Compositing --key Enabled false' || true
su - "$USER_NAME" -c 'dbus-run-session -- kwriteconfig5 --file kdeglobals --group KDE --key AnimationDurationFactor 0.2' || true

# ---------------- TigerVNC :0 ----------------
step "5/11 Configure TigerVNC :0 (${GEOM})"
install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.vnc"
su - "$USER_NAME" -c "printf '%s\n' '$VNC_PASS' | vncpasswd -f > ~/.vnc/passwd"
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.vnc/passwd"
chmod 600 "/home/$USER_NAME/.vnc/passwd"

cat >"/home/$USER_NAME/.vnc/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_SESSION_TYPE=x11
export DESKTOP_SESSION=plasma
export XDG_CURRENT_DESKTOP=KDE
export KDE_FULL_SESSION=true
[ -x /usr/bin/dbus-launch ] && eval $(/usr/bin/dbus-launch --exit-with-session)
exec /usr/bin/startplasma-x11
EOF
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.vnc/xstartup"
chmod +x "/home/$USER_NAME/.vnc/xstartup"

# Create multi-session VNC configuration
if [[ "$ENABLE_MULTI_SESSION" == "true" ]]; then
  # Create VNC service template for multiple sessions
  cat >/etc/systemd/system/vncserver@.service <<EOF
[Unit]
Description=TigerVNC server on display :%i (user ${USER_NAME})
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=${USER_NAME}
Group=${USER_NAME}
WorkingDirectory=/home/${USER_NAME}
Environment=HOME=/home/${USER_NAME}
Environment=XDG_RUNTIME_DIR=/run/user/${USER_UID}
Environment=DISPLAY=:%i
ExecStartPre=/bin/bash -c 'rm -f /tmp/.X%i-lock /tmp/.X11-unix/X%i'
ExecStart=/usr/bin/vncserver -fg -localhost no -geometry ${GEOM} -AlwaysShared -AcceptKeyEvents -AcceptPointerEvents -AcceptCutText -SendCutText -SecurityTypes None :%i
ExecStop=/usr/bin/vncserver -kill :%i
ExecStopPost=/bin/bash -c 'rm -f /tmp/.X%i-lock /tmp/.X11-unix/X%i'
Restart=always
RestartSec=3
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=10
[Install]
WantedBy=multi-user.target
EOF

  # Create multi-session startup script
  cat >/usr/local/bin/start-multi-vnc.sh <<EOF
#!/bin/bash
# Start multiple VNC sessions

echo "[INFO] Starting \$MAX_SESSIONS VNC sessions..."

for i in \$(seq 0 \$((MAX_SESSIONS-1))); do
    echo "[INFO] Starting VNC session :\$i on port \$((5900+i))"
    systemctl enable vncserver@\$i.service
    systemctl start vncserver@\$i.service
    sleep 2
done

echo "[INFO] VNC sessions started:"
systemctl list-units --type=service --state=running | grep vncserver@ || echo "No VNC sessions running"
EOF
  chmod +x /usr/local/bin/start-multi-vnc.sh

else
  # Single session VNC (original configuration)
  cat >/etc/systemd/system/vncserver@.service <<EOF
[Unit]
Description=TigerVNC server on display :%i (user ${USER_NAME})
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=${USER_NAME}
Group=${USER_NAME}
WorkingDirectory=/home/${USER_NAME}
Environment=HOME=/home/${USER_NAME}
Environment=XDG_RUNTIME_DIR=/run/user/${USER_UID}
ExecStartPre=/bin/bash -c 'rm -f /tmp/.X%i-lock /tmp/.X11-unix/X%i'
ExecStart=/usr/bin/vncserver -fg -localhost no -geometry ${GEOM} -AlwaysShared -AcceptKeyEvents -AcceptPointerEvents -AcceptCutText -SendCutText :%i
ExecStop=/usr/bin/vncserver -kill :%i
ExecStopPost=/bin/bash -c 'rm -f /tmp/.X%i-lock /tmp/.X11-unix/X%i'
Restart=always
RestartSec=3
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=10
[Install]
WantedBy=multi-user.target
EOF
fi

# Create cleanup service for stale VNC/RDP sessions
cat >/etc/systemd/system/vnc-rdp-cleanup.service <<EOF
[Unit]
Description=Cleanup stale VNC/RDP sessions and lock files
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '
# Clean up stale X11 lock files
rm -f /tmp/.X*-lock
# Clean up stale X11 sockets
find /tmp/.X11-unix -name "X*" -type s -mtime +1 -delete 2>/dev/null || true
# Clean up stale VNC processes
pkill -f "Xvnc.*:0" 2>/dev/null || true
# Clean up stale XRDP sessions
pkill -f "xrdp-sesman" 2>/dev/null || true
sleep 2
# Restart services if needed
systemctl is-active --quiet vncserver@0 || systemctl start vncserver@0
systemctl is-active --quiet xrdp || systemctl start xrdp
'
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

# Create timer for periodic cleanup
cat >/etc/systemd/system/vnc-rdp-cleanup.timer <<EOF
[Unit]
Description=Run VNC/RDP cleanup every 5 minutes
Requires=vnc-rdp-cleanup.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now vnc-rdp-cleanup.timer >>"$LOG" 2>&1 || true

# Start VNC sessions based on configuration
if [[ "$ENABLE_MULTI_SESSION" == "true" ]]; then
  echo "[INFO] Starting $MAX_SESSIONS VNC sessions..." >>"$LOG"
  for i in $(seq 0 $((MAX_SESSIONS-1))); do
    systemctl enable --now vncserver@$i.service >>"$LOG" 2>&1 || true
    sleep 1
  done
else
  systemctl enable --now vncserver@0.service >>"$LOG" 2>&1 || true
fi

# Create VNC/RDP reconnection helper script
cat >/usr/local/bin/vnc-rdp-reconnect.sh <<'EOF'
#!/bin/bash
# VNC/RDP reconnection helper script

echo "=== VNC/RDP Reconnection Helper ==="
echo "This script fixes common reconnection issues"
echo ""

# Function to restart VNC service
restart_vnc() {
    echo "[INFO] Restarting VNC service..."
    systemctl stop vncserver@0 2>/dev/null || true
    sleep 2
    
    # Clean up stale files
    rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null || true
    
    # Kill any remaining VNC processes
    pkill -f "Xvnc.*:0" 2>/dev/null || true
    sleep 1
    
    systemctl start vncserver@0
    sleep 3
    
    if systemctl is-active --quiet vncserver@0; then
        echo "[SUCCESS] VNC service restarted successfully"
        echo "VNC available on port 5900"
    else
        echo "[ERROR] Failed to restart VNC service"
        systemctl status vncserver@0 --no-pager -l
    fi
}

# Function to restart XRDP service
restart_xrdp() {
    echo "[INFO] Restarting XRDP service..."
    systemctl stop xrdp 2>/dev/null || true
    sleep 2
    
    # Clean up stale XRDP sessions
    pkill -f xrdp-sesman 2>/dev/null || true
    pkill -f xrdp 2>/dev/null || true
    sleep 1
    
    systemctl start xrdp
    sleep 3
    
    if systemctl is-active --quiet xrdp; then
        echo "[SUCCESS] XRDP service restarted successfully"
        echo "RDP available on port 3389"
    else
        echo "[ERROR] Failed to restart XRDP service"
        systemctl status xrdp --no-pager -l
    fi
}

# Function to show connection status
show_status() {
    echo "=== CONNECTION STATUS ==="
    echo "VNC Service: $(systemctl is-active vncserver@0)"
    echo "XRDP Service: $(systemctl is-active xrdp)"
    echo ""
    
    echo "=== LISTENING PORTS ==="
    ss -tlnp | grep -E ':(5900|3389)' || echo "No VNC/RDP ports found listening"
    echo ""
    
    echo "=== ACTIVE X11 DISPLAYS ==="
    ls -la /tmp/.X11-unix/ 2>/dev/null || echo "No X11 sockets found"
    echo ""
    
    echo "=== LOCK FILES ==="
    ls -la /tmp/.X*-lock 2>/dev/null || echo "No X11 lock files found"
}

# Main menu
case "${1:-menu}" in
    vnc)
        restart_vnc
        ;;
    rdp|xrdp)
        restart_xrdp
        ;;
    both|all)
        restart_vnc
        echo ""
        restart_xrdp
        ;;
    status)
        show_status
        ;;
    clean)
        echo "[INFO] Cleaning up stale sessions..."
        systemctl stop vncserver@0 xrdp 2>/dev/null || true
        sleep 2
        rm -f /tmp/.X*-lock /tmp/.X11-unix/X* 2>/dev/null || true
        pkill -f "Xvnc\|xrdp" 2>/dev/null || true
        sleep 2
        systemctl start vncserver@0 xrdp
        echo "[INFO] Cleanup complete"
        ;;
    *)
        echo "Usage: $0 {vnc|rdp|both|status|clean}"
        echo ""
        echo "Commands:"
        echo "  vnc    - Restart VNC service only"
        echo "  rdp    - Restart XRDP service only"  
        echo "  both   - Restart both VNC and XRDP services"
        echo "  status - Show connection status"
        echo "  clean  - Clean up and restart all services"
        echo ""
        show_status
        ;;
esac
EOF

chmod +x /usr/local/bin/vnc-rdp-reconnect.sh

# ---------------- Sunshine (.deb) + apps ----------------
step "6/11 Install Sunshine (.deb) + auto-add Steam & Chromium"
SUN_API_URL="https://api.github.com/repos/LizardByte/Sunshine/releases/latest"
if [[ -z "$SUN_DEB_URL" ]]; then
  SUN_TMP_JSON="$(mktemp)"
  if curl -fsSL "$SUN_API_URL" -o "$SUN_TMP_JSON"; then
    SUN_ASSET_URL="$(jq -r '.assets[] | select(.name | test("ubuntu.*22\\.04.*amd64.*\\.deb$")) | .browser_download_url' "$SUN_TMP_JSON" 2>/dev/null | head -n1 || true)"
    if [[ -n "$SUN_ASSET_URL" && "$SUN_ASSET_URL" != "null" ]]; then
      SUN_DEB_URL="$SUN_ASSET_URL"
    fi
  fi
  rm -f "$SUN_TMP_JSON"
fi
if [[ -z "$SUN_DEB_URL" ]]; then
  SUN_DEB_URL="https://github.com/LizardByte/Sunshine/releases/latest/download/sunshine-ubuntu-22.04-amd64.deb"
fi
TMP_DEB="$(mktemp /tmp/sunshine.XXXXXX.deb)"
step "6.1/11 Tải Sunshine từ ${SUN_DEB_URL}"
curl -fL "$SUN_DEB_URL" -o "$TMP_DEB"
if ! dpkg -i "$TMP_DEB"; then
  apt -f install -y >>"$LOG" 2>&1 || true
  dpkg -i "$TMP_DEB"
fi
rm -f "$TMP_DEB"

# Configure Sunshine for NVIDIA Tesla T4 and multi-session support
step "6.1.0/11 Cấu hình Sunshine cho NVIDIA Tesla T4 và multi-session"

# Create Sunshine configuration directory
SUNSHINE_CONFIG_DIR="/home/$USER_NAME/.config/sunshine"
mkdir -p "$SUNSHINE_CONFIG_DIR"
chown "$USER_NAME:$USER_NAME" "$SUNSHINE_CONFIG_DIR"

# Create optimized Sunshine configuration for Tesla T4
cat > "$SUNSHINE_CONFIG_DIR/sunshine.conf" <<EOF
# Sunshine configuration optimized for NVIDIA Tesla T4 and multi-session

# Network configuration
address_family = both
bind_address = 0.0.0.0
port = 47989
https_port = 47990
ping_timeout = 30000

# NVIDIA Tesla T4 hardware encoding configuration
capture = nvfbc
encoder = nvenc
adapter_name = /dev/dri/card0

# NVENC settings for Tesla T4
nvenc_preset = p4
nvenc_rc = cbr_hq
nvenc_coder = h264
nvenc_2pass = enabled

# Video quality settings optimized for Tesla T4
min_log_level = info
channels = 5
fec_percentage = 20
qp = 28

# Multi-session support
upnp = disabled
lan_encryption_mode = 1

# Audio configuration
audio_sink = pulse

# Performance optimizations for Tesla T4
sw_preset = ultrafast
sw_tune = zerolatency

# Display configuration
output_name = 0
EOF

# Create Tesla T4 specific environment setup
if [[ "$NVIDIA_T4_OPTIMIZATIONS" == "true" ]]; then
  cat >> "$SUNSHINE_CONFIG_DIR/sunshine.conf" <<EOF

# Tesla T4 specific optimizations
nvenc_spatial_aq = enabled
nvenc_temporal_aq = enabled
nvenc_realtime = enabled
nvenc_multipass = qres
nvenc_coder = auto

# GPU memory and performance settings
capture_cursor = enabled
capture_display = auto
EOF
fi

chown "$USER_NAME:$USER_NAME" "$SUNSHINE_CONFIG_DIR/sunshine.conf"

# Create multi-session Sunshine launcher
if [[ "$ENABLE_MULTI_SESSION" == "true" ]]; then
  cat > /usr/local/bin/sunshine-multi-session.sh <<EOF
#!/bin/bash
# Multi-session Sunshine launcher for Tesla T4

echo "[INFO] Starting Sunshine multi-session support..."

# Create session-specific configurations
for i in \$(seq 0 \$((MAX_SESSIONS-1))); do
    SESSION_DIR="/home/$USER_NAME/.config/sunshine-session-\$i"
    mkdir -p "\$SESSION_DIR"
    
    # Copy base configuration
    cp "$SUNSHINE_CONFIG_DIR/sunshine.conf" "\$SESSION_DIR/sunshine.conf"
    
    # Modify ports for each session
    sed -i "s/port = 47989/port = \$((47989+i))/" "\$SESSION_DIR/sunshine.conf"
    sed -i "s/https_port = 47990/https_port = \$((47990+i))/" "\$SESSION_DIR/sunshine.conf"
    
    # Set display for each session
    sed -i "s/output_name = 0/output_name = \$i/" "\$SESSION_DIR/sunshine.conf"
    
    chown -R "$USER_NAME:$USER_NAME" "\$SESSION_DIR"
    
    echo "[INFO] Created Sunshine configuration for session \$i (ports \$((47989+i))/\$((47990+i)))"
done

echo "[INFO] Multi-session Sunshine configurations created"
echo "[INFO] Sessions available on ports:"
for i in \$(seq 0 \$((MAX_SESSIONS-1))); do
    echo "  Session \$i: HTTP \$((47989+i)), HTTPS \$((47990+i))"
done
EOF
  chmod +x /usr/local/bin/sunshine-multi-session.sh
  
  # Run the multi-session setup
  /usr/local/bin/sunshine-multi-session.sh >>"$LOG" 2>&1 || true
fi

# Post-installation GLIBCXX verification for Sunshine and user lt4c
step "6.1.1/11 Kiểm tra GLIBCXX sau khi cài Sunshine cho user ${USER_NAME}"
echo "[INFO] Verifying Sunshine GLIBCXX compatibility for user ${USER_NAME}" >>"$LOG"

# Test Sunshine execution as the target user
su - "$USER_NAME" -c "
  echo '[INFO] Testing Sunshine execution with GLIBCXX for user $USER_NAME...'
  
  # Set up library environment
  export LD_LIBRARY_PATH=\"/usr/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu:\$LD_LIBRARY_PATH\"
  
  # Test basic Sunshine functionality
  if command -v sunshine >/dev/null 2>&1; then
    echo '[INFO] Sunshine binary found, testing GLIBCXX compatibility...'
    
    # Try to run sunshine with version check (should not crash on GLIBCXX)
    if timeout 10 sunshine --version 2>&1 | grep -i sunshine >/dev/null; then
      echo '[SUCCESS] Sunshine GLIBCXX compatibility: OK'
    else
      echo '[ERROR] Sunshine GLIBCXX compatibility: FAILED'
      echo '[INFO] Attempting to fix library paths...'
      
      # Add library paths to user profile
      if [ -f ~/.profile ]; then
        if ! grep -q 'LD_LIBRARY_PATH.*usr/lib/x86_64-linux-gnu' ~/.profile; then
          echo 'export LD_LIBRARY_PATH=\"/usr/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu:\$LD_LIBRARY_PATH\"' >> ~/.profile
        fi
      fi
      
      # Try again with explicit library path
      export LD_LIBRARY_PATH=\"/usr/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu\"
      if timeout 10 sunshine --version 2>&1 | grep -i sunshine >/dev/null; then
        echo '[SUCCESS] Sunshine GLIBCXX compatibility: FIXED'
      else
        echo '[ERROR] Sunshine GLIBCXX compatibility: STILL FAILED'
      fi
    fi
  else
    echo '[ERROR] Sunshine binary not found in PATH'
  fi
" >>"$LOG" 2>&1 || true

# Ensure system-wide library cache is updated
ldconfig >>"$LOG" 2>&1 || true

# apps.json (stream targets)
read -r -d '' APPS_JSON_CONTENT <<JSON
{
  "apps": [
    {
      "name": "Steam",
      "cmd": ["/usr/bin/flatpak", "run", "com.valvesoftware.Steam"],
      "working_dir": "/home/${USER_NAME}",
      "image_path": "",
      "auto_detect": false
    },
    {
      "name": "Chromium",
      "cmd": ["/usr/bin/flatpak", "run", "org.chromium.Chromium"],
      "working_dir": "/home/${USER_NAME}",
      "image_path": "",
      "auto_detect": false
    }
  ]
}
JSON

install -d -m 0755 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.config/sunshine"
printf '%s\n' "$APPS_JSON_CONTENT" >"/home/$USER_NAME/.config/sunshine/apps.json"
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.config/sunshine/apps.json"
chmod 644 "/home/$USER_NAME/.config/sunshine/apps.json"
install -d -m 0750 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.local/share/sunshine"

install -d -m 0755 /var/lib/sunshine
printf '%s\n' "$APPS_JSON_CONTENT" > /var/lib/sunshine/apps.json
chown sunshine:sunshine /var/lib/sunshine/apps.json 2>/dev/null || true
chmod 644 /var/lib/sunshine/apps.json

# Ensure Sunshine waits for input devices to become writable
cat >/usr/local/bin/sunshine-wait-uinput.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for _ in $(seq 1 30); do
  if [ -w /dev/uinput ]; then
    exit 0
  fi
  sleep 1
done
echo "[WARN] /dev/uinput not ready for Sunshine" >&2
exit 1
EOF
chmod +x /usr/local/bin/sunshine-wait-uinput.sh

# Override systemd: run Sunshine as user lt4c with dynamic display detection
install -d /etc/systemd/system/sunshine.service.d
cat >/etc/systemd/system/sunshine.service.d/override.conf <<EOF
[Service]
User=${USER_NAME}
Group=${USER_NAME}
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/${USER_UID}
ExecStartPre=/usr/local/bin/sunshine-wait-uinput.sh
ExecStartPre=/usr/local/bin/sunshine-display-setup.sh
EOF

install -d -m 0700 -o "$USER_UID" -g "$USER_UID" "/run/user/${USER_UID}" || true
systemctl daemon-reload

if [[ -f /home/red/Documents/sunshine_perm.sh ]]; then
  bash /home/red/Documents/sunshine_perm.sh "$USER_NAME"
fi

# =================== Sunshine as USER service + input perms ===================
step "7/11 Sunshine: user service + input permissions"

# Disable system-wide service to avoid seat/session issues
systemctl disable --now sunshine >>"$LOG" 2>&1 || true

# Enable lingering so user services can run without interactive login
loginctl enable-linger "${USER_NAME}" >>"$LOG" 2>&1 || true

USR_UNIT_DIR="/home/${USER_NAME}/.config/systemd/user"
install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "$USR_UNIT_DIR"

cat >"$USR_UNIT_DIR/sunshine.service" <<EOF
[Unit]
Description=Sunshine Remote Play (user)
After=graphical-session.target network-online.target
Wants=network-online.target

[Service]
Type=exec
ExecStartPre=/usr/local/bin/sunshine-wait-uinput.sh
ExecStart=/usr/local/bin/sunshine-wrapper.sh
Restart=on-failure
RestartSec=5
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/${USER_UID}
Environment=SYSTEMD_IGNORE_CHROOT=1
SupplementaryGroups=input uinput video render audio
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30
NoNewPrivileges=true

[Install]
WantedBy=default.target
EOF
chown "${USER_NAME}:${USER_NAME}" "$USR_UNIT_DIR/sunshine.service"

# Start as user
su - "${USER_NAME}" -c 'systemctl --user daemon-reload' || true
su - "${USER_NAME}" -c 'systemctl --user enable --now sunshine' || true

# Input stack and comprehensive permissions setup
apt -y install evtest joystick >>"$LOG" 2>&1 || true

# Ensure required kernel modules are loaded
MODULE_CONF="/etc/modules-load.d/uinput.conf"
if [[ -f "$MODULE_CONF" ]]; then
  if ! grep -qxF 'uinput' "$MODULE_CONF"; then
    echo 'uinput' >>"$MODULE_CONF"
  fi
else
  echo 'uinput' >"$MODULE_CONF"
fi

# Load uinput module immediately
modprobe uinput || true

# Create necessary groups
groupadd -f input
groupadd -f uinput
groupadd -f video
groupadd -f render
groupadd -f audio

# Add user to all required groups
usermod -aG input,uinput,video,render,audio "${USER_NAME}"

# Comprehensive udev rules for input devices
cat >/etc/udev/rules.d/60-sunshine-input.rules <<'EOF'
# uinput device permissions
KERNEL=="uinput", MODE="0666", GROUP="uinput", OPTIONS+="static_node=uinput"
SUBSYSTEM=="misc", KERNEL=="uinput", MODE="0666", GROUP="uinput", TAG+="uaccess"

# Input event devices
SUBSYSTEM=="input", KERNEL=="event*", MODE="0664", GROUP="input"
SUBSYSTEM=="input", KERNEL=="mouse*", MODE="0664", GROUP="input"
SUBSYSTEM=="input", KERNEL=="js*", MODE="0664", GROUP="input"

# GPU devices for hardware acceleration
SUBSYSTEM=="drm", KERNEL=="card*", MODE="0666", GROUP="video"
SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0666", GROUP="render"
EOF

chmod 644 /etc/udev/rules.d/60-sunshine-input.rules

# Force create uinput device node if it doesn't exist
if [[ ! -e /dev/uinput ]]; then
  mknod /dev/uinput c 10 223 || true
fi

# Set immediate permissions
chmod 666 /dev/uinput 2>/dev/null || true
chgrp uinput /dev/uinput 2>/dev/null || true

# Reload and trigger udev rules
udevadm control --reload-rules || true
udevadm trigger --subsystem-match=misc --action=add || true
udevadm trigger --subsystem-match=input --action=change || true
udevadm trigger --subsystem-match=drm --action=change || true

# Ensure Sunshine service has input supplementary group
cat >/etc/systemd/system/sunshine.service.d/10-input.conf <<'EOF'
[Service]
SupplementaryGroups=input uinput video render audio
EOF

# Additional uinput permissions for Sunshine streaming
# Create udev rule to ensure uinput device has proper permissions
cat >/etc/udev/rules.d/99-sunshine-uinput.rules <<'EOF'
KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput", MODE="0660", GROUP="uinput"
EOF

# Ensure the uinput group exists and user is added
groupadd -f uinput
usermod -aG uinput "${USER_NAME}"

# Set proper permissions on /dev/uinput
chmod 660 /dev/uinput 2>/dev/null || true
chgrp uinput /dev/uinput 2>/dev/null || true

# Reload udev rules and trigger
udevadm control --reload-rules
udevadm trigger --subsystem-match=misc --action=add

systemctl daemon-reload
systemctl restart sunshine || true

# =================== Sunshine RDP display permissions & autostart ===================
step "7.3/11 Cấu hình Sunshine cho RDP displays + tự khởi động"

# Create enhanced script to detect display and prevent Sunshine shutdown issues
cat >/usr/local/bin/sunshine-display-setup.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Function to detect current display
detect_display() {
    # Check for RDP display first
    if [ -n "${XRDP_SESSION:-}" ] || [ "${DESKTOP_SESSION:-}" = "xrdp" ]; then
        # RDP session - find the display
        for display in /tmp/.X11-unix/X*; do
            if [ -S "$display" ]; then
                display_num="${display##*/X}"
                echo ":${display_num}"
                return 0
            fi
        done
        # Fallback for RDP
        echo ":10"
    elif [ -n "${DISPLAY:-}" ]; then
        echo "$DISPLAY"
    else
        # Default fallback
        echo ":0"
    fi
}

# Set display and permissions
DETECTED_DISPLAY="$(detect_display)"
export DISPLAY="$DETECTED_DISPLAY"

# Ensure X11 socket permissions for RDP
X11_SOCKET="/tmp/.X11-unix/X${DETECTED_DISPLAY#:}"
if [ -S "$X11_SOCKET" ]; then
    chmod 777 "$X11_SOCKET" 2>/dev/null || true
fi

# Set XAUTHORITY for RDP sessions
if [ -z "${XAUTHORITY:-}" ]; then
    if [ -f "$HOME/.Xauthority" ]; then
        export XAUTHORITY="$HOME/.Xauthority"
    elif [ -f "/home/$USER/.Xauth" ]; then
        export XAUTHORITY="/home/$USER/.Xauth"
    fi
fi

# Prevent premature shutdown by setting up proper session environment
export XDG_SESSION_TYPE="x11"
export XDG_SESSION_CLASS="user"
export XDG_SESSION_DESKTOP="${XDG_SESSION_DESKTOP:-plasma}"

# Ensure dbus session is available
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    if [ -f "$HOME/.dbus/session-bus/*" ]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$(ls $HOME/.dbus/session-bus/* | head -1)"
    fi
fi

# Set up systemd user session environment
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user import-environment DISPLAY XAUTHORITY XDG_SESSION_TYPE XDG_SESSION_CLASS XDG_SESSION_DESKTOP DBUS_SESSION_BUS_ADDRESS 2>/dev/null || true
fi

echo "Sunshine display setup: DISPLAY=$DISPLAY, XAUTHORITY=${XAUTHORITY:-none}, SESSION_TYPE=${XDG_SESSION_TYPE:-none}"
EOF
chmod +x /usr/local/bin/sunshine-display-setup.sh

# Create enhanced Sunshine wrapper script to prevent RDP shutdown issues
cat >/usr/local/bin/sunshine-wrapper.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Source display setup
source /usr/local/bin/sunshine-display-setup.sh

# Comprehensive signal handling to prevent RDP session shutdown
trap 'echo "[INFO] Ignoring TERM signal, Sunshine continues running..."' TERM
trap 'echo "[INFO] Ignoring HUP signal, Sunshine continues running..."' HUP
trap 'echo "[INFO] Ignoring INT signal, Sunshine continues running..."' INT
trap 'echo "[INFO] Ignoring QUIT signal, Sunshine continues running..."' QUIT

# Ensure we're in a proper session context
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

# Create runtime directory if it doesn't exist
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true

# Disable various session management systems that might cause shutdown
export SYSTEMD_IGNORE_CHROOT=1
export NO_AT_BRIDGE=1
export DBUS_FATAL_WARNINGS=0

# RDP-specific environment fixes
export XDG_SESSION_TYPE="x11"
export XDG_SESSION_CLASS="user" 
export XDG_CURRENT_DESKTOP="KDE"
export DESKTOP_SESSION="plasma"

# Prevent session manager interference
unset SESSION_MANAGER
unset GNOME_DESKTOP_SESSION_ID

# Start Sunshine in a new process group to isolate from session signals
echo "[INFO] Starting Sunshine with DISPLAY=$DISPLAY (PID=$$)"
setsid /usr/bin/sunshine "$@" &
SUNSHINE_PID=$!

# Monitor Sunshine and restart if it exits unexpectedly
while true; do
    if ! kill -0 $SUNSHINE_PID 2>/dev/null; then
        echo "[WARN] Sunshine process $SUNSHINE_PID exited, restarting..."
        sleep 2
        setsid /usr/bin/sunshine "$@" &
        SUNSHINE_PID=$!
    fi
    sleep 5
done
EOF
chmod +x /usr/local/bin/sunshine-wrapper.sh

# Create direct Sunshine launcher for manual testing (bypasses all session management)
cat >/usr/local/bin/sunshine-direct.sh <<'EOF'
#!/usr/bin/env bash
# Direct Sunshine launcher for RDP testing - bypasses session management

echo "[INFO] Direct Sunshine launcher for RDP display testing"

# Detect RDP display
DETECTED_DISPLAY=":0"
for display in /tmp/.X11-unix/X*; do
    if [ -S "$display" ]; then
        display_num="${display##*/X}"
        DETECTED_DISPLAY=":${display_num}"
        echo "[INFO] Found X11 socket: $display -> $DETECTED_DISPLAY"
        break
    fi
done

export DISPLAY="$DETECTED_DISPLAY"
echo "[INFO] Using DISPLAY=$DISPLAY"

# Set minimal required environment
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_SESSION_TYPE="x11"
export XDG_CURRENT_DESKTOP="KDE"
export DESKTOP_SESSION="plasma"

# Disable all session management
export SYSTEMD_IGNORE_CHROOT=1
export NO_AT_BRIDGE=1
export DBUS_FATAL_WARNINGS=0
unset SESSION_MANAGER
unset GNOME_DESKTOP_SESSION_ID

# Create runtime dir
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true

# Set X11 permissions
X11_SOCKET="/tmp/.X11-unix/X${DETECTED_DISPLAY#:}"
if [ -S "$X11_SOCKET" ]; then
    chmod 777 "$X11_SOCKET" 2>/dev/null || true
    echo "[INFO] Set permissions on $X11_SOCKET"
fi

# Check uinput
if [ ! -w /dev/uinput ]; then
    echo "[WARN] /dev/uinput not writable, input may not work"
fi

echo "[INFO] Starting Sunshine directly (no session management)"
echo "[INFO] Press Ctrl+C to stop"

# Start Sunshine with nohup to completely detach from terminal session
nohup /usr/bin/sunshine > /tmp/sunshine-direct.log 2>&1 &
SUNSHINE_PID=$!

echo "[INFO] Sunshine started with PID $SUNSHINE_PID"
echo "[INFO] Log file: /tmp/sunshine-direct.log"
echo "[INFO] To stop: kill $SUNSHINE_PID"

# Follow the log
tail -f /tmp/sunshine-direct.log
EOF
chmod +x /usr/local/bin/sunshine-direct.sh

# Enhanced user session configuration for RDP
USER_XSESSION="/home/${USER_NAME}/.xsessionrc"
if [[ ! -f "$USER_XSESSION" ]]; then
  install -m 0644 -o "${USER_NAME}" -g "${USER_NAME}" /dev/null "$USER_XSESSION"
fi

if ! grep -q 'SUNSHINE_XRDP_AUTOSTART' "$USER_XSESSION" 2>/dev/null; then
  cat <<'EOF' >>"$USER_XSESSION"

# >>> SUNSHINE_XRDP_AUTOSTART >>>
# Enhanced Sunshine startup for RDP sessions
if ! pgrep -u "$USER" -x sunshine >/dev/null; then
    # Set up display environment
    source /usr/local/bin/sunshine-display-setup.sh
    
    # Wait for input devices
    if /usr/local/bin/sunshine-wait-uinput.sh; then
        # Start Sunshine with proper environment
        /usr/bin/sunshine >>"$HOME/.local/share/sunshine/session.log" 2>&1 &
        echo "[INFO] Sunshine started for display $DISPLAY" >>"$HOME/.local/share/sunshine/session.log"
    else
        echo "[WARN] Sunshine skipped (uinput not ready)" >>"$HOME/.local/share/sunshine/session.log"
    fi
fi
# <<< SUNSHINE_XRDP_AUTOSTART <<<
EOF
  chown "${USER_NAME}:${USER_NAME}" "$USER_XSESSION"
fi

# Add RDP-specific X11 permissions
cat >/etc/X11/Xwrapper.config <<'EOF'
# Allow anybody to start X server
allowed_users=anybody
needs_root_rights=yes
EOF

# Ensure proper permissions for X11 sockets in RDP sessions
cat >/etc/systemd/system/x11-rdp-permissions.service <<EOF
[Unit]
Description=Set X11 RDP permissions
After=xrdp.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'chmod 777 /tmp/.X11-unix/X* 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable x11-rdp-permissions.service || true

if [[ "$ENABLE_VIGEM" == "true" ]]; then
  # =================== ViGEm/vgamepad via DKMS (optional) ===================
  step "7.2/11 Cài Virtual Gamepad (ViGEm/vgamepad) - optional"
  apt -y install dkms build-essential linux-headers-$(uname -r) git >>"$LOG" 2>&1 || true
  if ! lsmod | grep -q '^vgamepad'; then
    TMP_VGP="/tmp/vgamepad_$(date +%s)"
    rm -rf "$TMP_VGP"
    git clone --depth=1 https://github.com/ViGEm/vgamepad.git "$TMP_VGP" >>"$LOG" 2>&1 || true
    if [ -f "$TMP_VGP/dkms.conf" ] || [ -f "$TMP_VGP/Makefile" ]; then
      VGP_VER="$(grep -Eo 'PACKAGE_VERSION.?=.+' "$TMP_VGP/dkms.conf" 2>/dev/null | awk -F= '{print $2}' | tr -d ' "' || echo 0.1)"
      VGP_VER="${VGP_VER:-0.1}"
      DEST="/usr/src/vgamepad-${VGP_VER}"
      rm -rf "$DEST"
      mkdir -p "$DEST"
      cp -a "$TMP_VGP/"* "$DEST/"
      dkms add "vgamepad/${VGP_VER}" >>"$LOG" 2>&1 || true
      dkms build "vgamepad/${VGP_VER}" >>"$LOG" 2>&1 || true
      dkms install "vgamepad/${VGP_VER}" >>"$LOG" 2>&1 || true
    fi
    modprobe vgamepad || true
  fi
  cat >/etc/udev/rules.d/61-vgamepad.rules <<'EOF'
KERNEL=="vgamepad*", MODE="0660", GROUP="input"
EOF
  udevadm control --reload-rules || true
  udevadm trigger || true
fi

# =================== Shortcuts ra Desktop ===================
step "8/11 Tạo shortcut Steam, Moonlight (Sunshine Web UI), Chromium ra Desktop"

DESKTOP_DIR="/home/$USER_NAME/Desktop"
install -d -m 0755 -o "$USER_NAME" -g "$USER_NAME" "$DESKTOP_DIR"

cat >"$DESKTOP_DIR/steam.desktop" <<'EOF'
[Desktop Entry]
Name=Steam
Comment=Steam (Flatpak)
Exec=flatpak run com.valvesoftware.Steam
Icon=com.valvesoftware.Steam
Terminal=false
Type=Application
Categories=Game;
EOF

cat >"$DESKTOP_DIR/moonlight.desktop" <<EOF
[Desktop Entry]
Name=Moonlight (Sunshine Web UI)
Comment=Open Sunshine pairing UI for Moonlight
Exec=flatpak run org.chromium.Chromium https://localhost:${SUN_HTTP_TLS_PORT}
Icon=sunshine
Terminal=false
Type=Application
Categories=Network;Game;Settings;
EOF

cat >"$DESKTOP_DIR/chromium.desktop" <<'EOF'
[Desktop Entry]
Name=Chromium
Exec=flatpak run org.chromium.Chromium
Icon=org.chromium.Chromium
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF

chown -R "$USER_NAME:$USER_NAME" "$DESKTOP_DIR"
chmod +x "$DESKTOP_DIR"/*.desktop
update-desktop-database /usr/share/applications || true
su - "$USER_NAME" -c 'update-desktop-database ~/.local/share/applications || true' >>"$LOG" 2>&1 || true
pkill -HUP plasmashell || true

# =================== TCP low latency + ufw firewall setup ===================
step "9/11 Bật TCP low latency + cài ufw + mở cổng"
cat >/etc/sysctl.d/90-remote-desktop.conf <<'EOF'
net.ipv4.tcp_low_latency = 1
EOF
sysctl --system >/dev/null 2>&1 || true

# Install ufw (Uncomplicated Firewall)
apt -y install ufw >>"$LOG" 2>&1 || true

# Configure ufw firewall rules
if command -v ufw >/dev/null 2>&1; then
  ufw allow 3389/tcp || true        # RDP port for Windows clients
  ufw allow ${VNC_PORT}/tcp || true
  ufw allow ${SUN_HTTP_TLS_PORT}/tcp || true
  ufw allow 47984:47990/tcp || true
  ufw allow 47998:48010/udp || true
fi

# Ensure xrdp is restarted to pick up config and be ready for Windows connections
systemctl restart xrdp || true

# Improve xrdp performance / compatibility (best-effort)
# Set low color depth/crypt for older clients if file exists (safe to overwrite)
if [ -f /etc/xrdp/xrdp.ini ]; then
  sed -i 's/^crypt_level=.*/crypt_level=low/' /etc/xrdp/xrdp.ini || true
  sed -i 's/^max_bpp=.*/max_bpp=16/' /etc/xrdp/xrdp.ini || true
  systemctl reload xrdp || true
fi

# =================== DONE + PRINT IP ===================
step "10/11 Hoàn tất (log: $LOG)"
get_ip() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}
IP="$(get_ip)"
if [ -z "$IP" ]; then
  IP="$(ip -o -4 addr show up scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)"
fi
if [ -z "$IP" ] && command -v hostname >/dev/null 2>&1; then
  IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
IP="${IP:-<no-ip-detected>}"

if [[ "$ENABLE_MULTI_SESSION" == "true" ]]; then
  echo "=== MULTI-SESSION CONFIGURATION ==="
  echo "VNC Sessions:"
  for i in $(seq 0 $((MAX_SESSIONS-1))); do
    echo "  Session $i: ${IP}:$((5900+i))  (pass: ${VNC_PASS})"
  done
  echo ""
  echo "XRDP: ${IP}:3389 (user ${USER_NAME} / ${USER_PASS})"
  echo ""
  echo "Sunshine Sessions:"
  for i in $(seq 0 $((MAX_SESSIONS-1))); do
    echo "  Session $i: https://${IP}:$((47990+i))"
  done
else
  echo "TigerVNC : ${IP}:${VNC_PORT}  (pass: ${VNC_PASS})"
  echo "XRDP     : ${IP}:3389        (user ${USER_NAME} / ${USER_PASS})"
  echo "Sunshine : https://${IP}:${SUN_HTTP_TLS_PORT}  (UI tự ký; auto-add Steam & Chromium)"
fi

echo "Moonlight: Mở shortcut 'Moonlight (Sunshine Web UI)' trên Desktop để pair"
echo ""

if [[ "$NVIDIA_T4_OPTIMIZATIONS" == "true" ]]; then
  echo "=== NVIDIA TESLA T4 OPTIMIZATIONS ==="
  echo "- Hardware encoding: NVENC enabled"
  echo "- Capture method: NVFBC (NVIDIA Frame Buffer Capture)"
  echo "- Preset: P4 (balanced quality/performance)"
  echo "- Rate control: CBR HQ (Constant Bitrate High Quality)"
  echo "- Advanced features: Spatial/Temporal AQ, 2-pass encoding"
  echo "- Check GPU status: nvidia-smi"
  echo ""
fi

if [[ "$ENABLE_MULTI_SESSION" == "true" ]]; then
  echo "=== MULTI-SESSION MANAGEMENT ==="
  echo "Start all VNC sessions: /usr/local/bin/start-multi-vnc.sh"
  echo "Configure Sunshine sessions: /usr/local/bin/sunshine-multi-session.sh"
  echo "Check VNC sessions: systemctl status 'vncserver@*.service'"
  echo ""
fi

echo "=== VNC/RDP RECONNECTION FIXES ==="
echo "If you can't reconnect after disconnecting VNC/RDP:"
echo "- Run: /usr/local/bin/vnc-rdp-reconnect.sh"
echo "- Or restart services: /usr/local/bin/vnc-rdp-reconnect.sh both"
echo "- Check status: /usr/local/bin/vnc-rdp-reconnect.sh status"
echo "- Clean all sessions: /usr/local/bin/vnc-rdp-reconnect.sh clean"
echo ""
echo "=== SUNSHINE RDP TESTING ==="
echo "For RDP display testing, run: sudo -u ${USER_NAME} /usr/local/bin/sunshine-direct.sh"
echo "This bypasses session management and should prevent shutdown issues."

echo "---- DEBUG ----"
ip -o -4 addr show up | awk '{print $2, $4}' || true
ip route || true
ss -ltnp | awk 'NR==1 || /:3389|:5900|:47990/' || true
systemctl --no-pager --full status vncserver@0 | sed -n '1,25p' || true
systemctl --no-pager --full status xrdp | sed -n '1,25p' || true
systemctl --no-pager --full status sunshine | sed -n '1,25p' || true
echo "--------------"

gzip -f "$LOG" 2>/dev/null || true

step "11/11 DONE"
