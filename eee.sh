#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none

USER_NAME="lt4c"
USER_PASS="lt4c@2025"
VNC_PASS="lt4c"
GEOM="1280x720"
VNC_DISPLAY=0
VNC_PORT=$((5900 + VNC_DISPLAY))
RDP_PORT="3389"

apt update -qq
apt install -y \
  kde-standard sddm xorg \
  xrdp xorgxrdp tigervnc-standalone-server \
  curl wget jq ca-certificates gnupg2 software-properties-common lsb-release \
  xserver-xorg-core xserver-xorg-input-all xserver-xorg-video-dummy \
  sudo dbus-x11 xdg-utils desktop-file-utils dconf-cli binutils \
  flatpak remmina remmina-plugin-rdp remmina-plugin-vnc \
  mesa-vulkan-drivers libgl1-mesa-dri libasound2 libpulse0 libxkbcommon0 ufw
apt --fix-broken install -y || true

GLIBCXX_REQUIRED=("GLIBCXX_3.4.31" "GLIBCXX_3.4.32")
LIBSTDCXX_PATH="$(ldconfig -p 2>/dev/null | awk '/libstdc\+\+\.so\.6/ {print $4; exit}')"

needs_glibcxx_update=false
for sym in "${GLIBCXX_REQUIRED[@]}"; do
  if [[ -z "$LIBSTDCXX_PATH" ]] || ! strings "$LIBSTDCXX_PATH" 2>/dev/null | grep -q "$sym"; then
    needs_glibcxx_update=true
    break
  fi
done

if $needs_glibcxx_update; then
  add-apt-repository -y ppa:ubuntu-toolchain-r/test || true
  apt update -qq
  apt install -y libstdc++6
  LIBSTDCXX_PATH="$(ldconfig -p 2>/dev/null | awk '/libstdc\+\+\.so\.6/ {print $4; exit}')"
  for sym in "${GLIBCXX_REQUIRED[@]}"; do
    if [[ -z "$LIBSTDCXX_PATH" ]] || ! strings "$LIBSTDCXX_PATH" 2>/dev/null | grep -q "$sym"; then
      echo "Warning: ${sym} still missing from libstdc++6; Sunshine may fail." >&2
    fi
  done
fi

if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$USER_NAME"
fi
echo "${USER_NAME}:${USER_PASS}" | chpasswd
usermod -aG sudo "$USER_NAME"
USER_UID="$(id -u "$USER_NAME")"

loginctl enable-linger "$USER_NAME" || true
systemctl disable --now sddm || true
systemctl enable --now xrdp || true

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

cat >"/home/$USER_NAME/.xsession" <<'EOF'
#!/bin/sh
export DESKTOP_SESSION=plasma
export XDG_CURRENT_DESKTOP=KDE
export XDG_SESSION_TYPE=x11
exec dbus-run-session -- /usr/bin/startplasma-x11
EOF
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.xsession"
chmod 755 "/home/$USER_NAME/.xsession"

cat >"/home/$USER_NAME/.xsessionrc" <<'EOF'
export DESKTOP_SESSION=plasma
export XDG_CURRENT_DESKTOP=KDE
EOF
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.xsessionrc"
chmod 644 "/home/$USER_NAME/.xsessionrc"

# Create VNC configuration for shared display
cat >"/home/$USER_NAME/.vnc/config" <<EOF
geometry=${GEOM}
depth=24
desktopname=KDE-Plasma
alwaysshared=1
securitytypes=vncauth
localhost=no
EOF
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.vnc/config"
chmod 600 "/home/$USER_NAME/.vnc/config"

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
ExecStart=/usr/bin/vncserver -fg -localhost no -geometry ${GEOM} :%i
ExecStop=/usr/bin/vncserver -kill :%i
Restart=on-failure
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF

# Stop any existing VNC services
systemctl stop vncserver@*.service 2>/dev/null || true
systemctl disable vncserver@*.service 2>/dev/null || true

# Clean up any existing VNC processes
su - "$USER_NAME" -c 'vncserver -kill :* 2>/dev/null || true'
killall Xvnc 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now vncserver@${VNC_DISPLAY}.service || true

# Wait for VNC service to start and verify
sleep 5
echo "VNC service status:"
systemctl status vncserver@${VNC_DISPLAY}.service --no-pager -l || true

# Force restart VNC if not working
if ! ss -tlnp | grep -q ":${VNC_PORT}"; then
    echo "VNC not listening, attempting restart..."
    systemctl stop vncserver@${VNC_DISPLAY}.service || true
    su - "$USER_NAME" -c 'vncserver -kill :* 2>/dev/null || true'
    killall Xvnc 2>/dev/null || true
    rm -f /tmp/.X11-unix/X${VNC_DISPLAY} /tmp/.X${VNC_DISPLAY}-lock 2>/dev/null || true
    sleep 2
    systemctl start vncserver@${VNC_DISPLAY}.service || true
    sleep 3
fi

# Verify VNC is listening and display is available
echo "Checking VNC display :${VNC_DISPLAY}..."
if ss -tlnp | grep -q ":${VNC_PORT}"; then
    echo "✓ VNC server listening on port ${VNC_PORT}"
else
    echo "✗ VNC server not listening on port ${VNC_PORT}"
    echo "Attempting manual VNC start..."
    su - "$USER_NAME" -c "vncserver :${VNC_DISPLAY} -geometry ${GEOM} -depth 24 -localhost no" || true
fi

# Check if X display is running
if su - "$USER_NAME" -c "DISPLAY=:${VNC_DISPLAY} xdpyinfo >/dev/null 2>&1"; then
    echo "✓ X display :${VNC_DISPLAY} is accessible"
else
    echo "✗ X display :${VNC_DISPLAY} is not accessible"
fi

# Test VNC connection locally
echo "Testing VNC connection..."
if command -v vncviewer >/dev/null 2>&1; then
    timeout 5s vncviewer -passwd /home/${USER_NAME}/.vnc/passwd localhost:${VNC_DISPLAY} -ViewOnly -Shared >/dev/null 2>&1 && \
        echo "✓ VNC connection test successful" || echo "✗ VNC connection test failed"
else
    echo "vncviewer not available for connection test"
fi

# Configure XRDP with Plasma Shared TigerVNC session
XRDP_INI="/etc/xrdp/xrdp.ini"
echo "Configuring XRDP for Plasma Shared TigerVNC..."
if [[ -f "$XRDP_INI" ]]; then
  # Remove any existing VNC sections to avoid conflicts
  sed -i '/^\[.*VNC.*\]/,/^\[/{/^\[.*VNC.*\]/d; /^\[/!d;}' "$XRDP_INI" 2>/dev/null || true
  sed -i '/^\[Plasma.*\]/,/^\[/{/^\[Plasma.*\]/d; /^\[/!d;}' "$XRDP_INI" 2>/dev/null || true
  
  # Add the Plasma Shared TigerVNC session
  cat <<EOF >>"$XRDP_INI"

[Plasma Shared TigerVNC]
name=Plasma Shared TigerVNC
lib=libvnc.so
username=ask
password=ask
ip=127.0.0.1
port=${VNC_PORT}
EOF

  # Set this as the default session
  if grep -q '^autorun=' "$XRDP_INI" 2>/dev/null; then
    sed -i 's/^autorun=.*/autorun=Plasma Shared TigerVNC/' "$XRDP_INI"
  else
    sed -i '/^\[Globals\]/a autorun=Plasma Shared TigerVNC' "$XRDP_INI"
  fi
  
  # Improve xrdp performance / compatibility
  sed -i 's/^crypt_level=.*/crypt_level=low/' "$XRDP_INI" || true
  sed -i 's/^max_bpp=.*/max_bpp=16/' "$XRDP_INI" || true
  sed -i 's/^tcp_nodelay=.*/tcp_nodelay=yes/' "$XRDP_INI" || true
  sed -i 's/^tcp_keepalive=.*/tcp_keepalive=yes/' "$XRDP_INI" || true
fi

echo "XRDP configuration completed. Restarting services..."
systemctl restart xrdp || true

cat >/etc/X11/Xwrapper.config <<'EOF'
allowed_users=anybody
needs_root_rights=no
EOF


cat >"/etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla" <<'EOF'
[Allow Colord All Users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.modify-system-profile
ResultAny=yes
ResultInactive=yes
ResultActive=yes
EOF

cat >"/home/${USER_NAME}/.config/plasma-workspace/env/x11rdp.sh" <<'EOF'
#!/bin/sh
export DESKTOP_SESSION=plasma
export XDG_CURRENT_DESKTOP=KDE
EOF
install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "/home/${USER_NAME}/.config/plasma-workspace/env"
chown -R "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.config/plasma-workspace"

cat >/etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
export DESKTOP_SESSION=plasma
export XDG_CURRENT_DESKTOP=KDE
export XDG_SESSION_TYPE=x11

if [ -r /etc/profile ]; then
  . /etc/profile
fi
if [ -r "$HOME/.profile" ]; then
  . "$HOME/.profile"
fi

if command -v dbus-run-session >/dev/null 2>&1 && [ -x /usr/bin/startplasma-x11 ]; then
  exec dbus-run-session -- /usr/bin/startplasma-x11
fi

if [ -x /usr/bin/startplasma-x11 ]; then
  exec /usr/bin/startplasma-x11
fi

exec /bin/sh /etc/X11/Xsession
EOF
chmod +x /etc/xrdp/startwm.sh

# Configure UFW firewall
echo "Configuring UFW firewall..."
ufw --force reset || true
ufw default deny incoming || true
ufw default allow outgoing || true
ufw allow 22/tcp || true      # SSH
ufw allow 3389/tcp || true    # RDP  
ufw allow 5900/tcp || true    # VNC
ufw allow 5901/tcp || true    # VNC alternate
ufw allow 47990/tcp || true   # Sunshine web UI
ufw allow 47989/tcp || true   # Sunshine RTSP
ufw allow 48010/tcp || true   # Sunshine HTTP
ufw --force enable || true
ufw reload || true
echo "UFW status:"
ufw status verbose || true

flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak -y --system install flathub org.chromium.Chromium

cat >/etc/profile.d/flatpak-xdg.sh <<'EOF'
export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:/var/lib/flatpak/exports/share:$HOME/.local/share/flatpak/exports/share"
EOF
chmod +x /etc/profile.d/flatpak-xdg.sh

USER_PROFILE="/home/${USER_NAME}/.profile"
if ! grep -Fq '/etc/profile.d/flatpak-xdg.sh' "$USER_PROFILE" 2>/dev/null; then
  {
    echo ""
    echo "if [ -f /etc/profile.d/flatpak-xdg.sh ]; then"
    echo "  . /etc/profile.d/flatpak-xdg.sh"
    echo "fi"
  } >> "$USER_PROFILE"
  chown "${USER_NAME}:${USER_NAME}" "$USER_PROFILE"
fi

su - "$USER_NAME" -c 'dbus-run-session -- flatpak --system repair || true'
su - "$USER_NAME" -c 'dbus-run-session -- flatpak --system update -y || true'
su - "$USER_NAME" -c 'systemctl --user daemon-reload 2>/dev/null || true'

SUN_API_URL="https://api.github.com/repos/LizardByte/Sunshine/releases/latest"
SUN_DEB_URL="$(curl -fsSL "$SUN_API_URL" | jq -r '.assets[] | select(.name | test("ubuntu.*22\\.04.*amd64.*\\.deb$")) | .browser_download_url' | head -n1)"
if [[ -z "$SUN_DEB_URL" || "$SUN_DEB_URL" == "null" ]]; then
  SUN_DEB_URL="https://github.com/LizardByte/Sunshine/releases/latest/download/sunshine-ubuntu-22.04-amd64.deb"
fi
TMP_DEB="$(mktemp /tmp/sunshine.XXXXXX.deb)"
curl -fL "$SUN_DEB_URL" -o "$TMP_DEB"
if ! dpkg -i "$TMP_DEB"; then
  apt --fix-broken install -y
  dpkg -i "$TMP_DEB"
fi
rm -f "$TMP_DEB"

apt --fix-broken install -y || true

cat >/usr/local/bin/sunshine-wait-uinput.sh <<'EOF'
#!/usr/bin/env bash
set -e
for _ in $(seq 1 30); do
  if [ -w /dev/uinput ]; then
    exit 0
  fi
  sleep 1
done
exit 1
EOF
chmod +x /usr/local/bin/sunshine-wait-uinput.sh

groupadd -f input
groupadd -f uinput
usermod -aG input,uinput "${USER_NAME}"

# Ensure uinput device exists and has correct permissions
if [ ! -e /dev/uinput ]; then
  mknod /dev/uinput c 10 223 || true
fi
chown root:uinput /dev/uinput
chmod 660 /dev/uinput

# Create additional udev rules for comprehensive uinput access
cat >/etc/udev/rules.d/99-uinput-sunshine.rules <<'EOF'
# uinput device for virtual input creation
KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"
SUBSYSTEM=="misc", KERNEL=="uinput", MODE="0660", GROUP="uinput"
# Input event devices
SUBSYSTEM=="input", KERNEL=="event*", MODE="0660", GROUP="input"
SUBSYSTEM=="input", KERNEL=="mouse*", MODE="0660", GROUP="input"
SUBSYSTEM=="input", KERNEL=="js*", MODE="0660", GROUP="input"
EOF
chmod 644 /etc/udev/rules.d/99-uinput-sunshine.rules


MODULE_CONF="/etc/modules-load.d/uinput.conf"
if [[ -f "$MODULE_CONF" ]]; then
  if ! grep -qxF 'uinput' "$MODULE_CONF"; then
    echo 'uinput' >>"$MODULE_CONF"
  fi
else
  echo 'uinput' >"$MODULE_CONF"
fi
modprobe uinput || true

cat >/etc/udev/rules.d/60-sunshine-input.rules <<'EOF'
KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"
SUBSYSTEM=="input", KERNEL=="event*", MODE="0660", GROUP="input"
EOF
chmod 644 /etc/udev/rules.d/60-sunshine-input.rules
udevadm control --reload-rules || true
udevadm trigger --subsystem-match=misc --action=add || true
udevadm trigger --subsystem-match=input --action=change || true

install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "/home/${USER_NAME}/.config/sunshine"
cat >"/home/${USER_NAME}/.config/sunshine/apps.json" <<'EOF'
{
  "apps": []
}
EOF
chown "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.config/sunshine/apps.json"

install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "/home/${USER_NAME}/.config/systemd/user"

cat >"/home/${USER_NAME}/.config/systemd/user/sunshine.service" <<EOF
[Unit]
Description=Sunshine Remote Play
After=graphical-session.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/local/bin/sunshine-wait-uinput.sh
ExecStart=/usr/bin/sunshine
Restart=on-failure
Environment=DISPLAY=:${VNC_DISPLAY}
Environment=XDG_RUNTIME_DIR=/run/user/${USER_UID}
Environment=XDG_SESSION_TYPE=x11
Environment=WAYLAND_DISPLAY=
SupplementaryGroups=input uinput
PrivateDevices=no

[Install]
WantedBy=default.target
EOF
chown "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.config/systemd/user/sunshine.service"

# Ensure Sunshine service has input supplementary group
install -d /etc/systemd/system/sunshine.service.d
cat >/etc/systemd/system/sunshine.service.d/10-input.conf <<'EOF'
[Service]
SupplementaryGroups=input uinput
EOF
systemctl daemon-reload
systemctl restart sunshine || true

# Install GLIBCXX for user lt4c and setup Sunshine autostart
echo "Setting up GLIBCXX and Sunshine for user ${USER_NAME}..."

# Ensure user has access to updated libstdc++6
su - "${USER_NAME}" -c 'echo "Checking GLIBCXX availability for user..."'
su - "${USER_NAME}" -c 'ldconfig -p | grep libstdc++ || echo "libstdc++ not found in user space"'

# Add library path to user environment
USER_PROFILE="/home/${USER_NAME}/.profile"
if ! grep -q 'LD_LIBRARY_PATH.*libstdc' "$USER_PROFILE" 2>/dev/null; then
  cat <<EOF >>"$USER_PROFILE"

# GLIBCXX library path for Sunshine
export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:\${LD_LIBRARY_PATH}"
EOF
  chown "${USER_NAME}:${USER_NAME}" "$USER_PROFILE"
fi

# Sunshine autostart in VNC/XRDP sessions
USER_XSESSION="/home/${USER_NAME}/.xsessionrc"
if [[ ! -f "$USER_XSESSION" ]]; then
  install -m 0644 -o "${USER_NAME}" -g "${USER_NAME}" /dev/null "$USER_XSESSION"
fi
if ! grep -q 'SUNSHINE_AUTO_START' "$USER_XSESSION" 2>/dev/null; then
  cat <<'EOF' >>"$USER_XSESSION"

# >>> SUNSHINE_AUTO_START >>>
# Auto-start Sunshine in Plasma Shared TigerVNC sessions
if ! pgrep -u "$USER" -x sunshine >/dev/null 2>&1; then
    # Wait for uinput device to be ready
    if /usr/local/bin/sunshine-wait-uinput.sh; then
        # Start Sunshine with proper environment
        export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}"
        mkdir -p "$HOME/.local/share/sunshine"
        /usr/bin/sunshine >>"$HOME/.local/share/sunshine/session.log" 2>&1 &
        echo "[INFO] Sunshine started in session $(date)" >>"$HOME/.local/share/sunshine/session.log"
    else
        echo "[WARN] Sunshine skipped - uinput not ready $(date)" >>"$HOME/.local/share/sunshine/session.log"
    fi
fi
# <<< SUNSHINE_AUTO_START <<<
EOF
  chown "${USER_NAME}:${USER_NAME}" "$USER_XSESSION"
fi

# Also add to VNC xstartup for direct VNC connections
if ! grep -q 'SUNSHINE_VNC_START' "/home/${USER_NAME}/.vnc/xstartup" 2>/dev/null; then
  sed -i '/exec \/usr\/bin\/startplasma-x11/i\
# >>> SUNSHINE_VNC_START >>>\
if ! pgrep -u "$USER" -x sunshine >/dev/null 2>&1; then\
    if /usr/local/bin/sunshine-wait-uinput.sh; then\
        export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}"\
        mkdir -p "$HOME/.local/share/sunshine"\
        # Ensure user has access to input devices\
        newgrp uinput <<EOFGRP\
        /usr/bin/sunshine >>"$HOME/.local/share/sunshine/vnc.log" 2>&1 &\
EOFGRP\
    fi\
fi\
# <<< SUNSHINE_VNC_START <<<\
' "/home/${USER_NAME}/.vnc/xstartup"
fi

# Create a helper script for Sunshine with proper permissions
cat >/usr/local/bin/sunshine-start-with-uinput.sh <<EOF
#!/bin/bash
# Helper script to start Sunshine with proper uinput permissions for user ${USER_NAME}

# Ensure user is in required groups
if ! groups \${USER} | grep -q uinput; then
    echo "Error: User \${USER} not in uinput group"
    exit 1
fi

# Check uinput device accessibility
if [ ! -w /dev/uinput ]; then
    echo "Error: /dev/uinput not writable by user \${USER}"
    exit 1
fi

# Set up environment for Sunshine
export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:\${LD_LIBRARY_PATH}"
mkdir -p "\${HOME}/.local/share/sunshine"

# Start Sunshine with proper group context
exec /usr/bin/sunshine "\$@"
EOF
chmod +x /usr/local/bin/sunshine-start-with-uinput.sh
chown root:root /usr/local/bin/sunshine-start-with-uinput.sh

# Verify uinput permissions and GLIBCXX
echo "Checking permissions and libraries for ${USER_NAME}..."
su - "${USER_NAME}" -c 'groups | grep -q uinput && echo "✓ User is in uinput group" || echo "✗ User not in uinput group"'
su - "${USER_NAME}" -c 'test -w /dev/uinput && echo "✓ User can write to /dev/uinput" || echo "✗ User cannot write to /dev/uinput"'

# Test virtual input device creation capability
echo "Testing virtual input device creation for ${USER_NAME}..."
su - "${USER_NAME}" -c '
if [ -w /dev/uinput ]; then
    # Test if user can create virtual devices (basic test)
    python3 -c "
import os
try:
    fd = os.open(\"/dev/uinput\", os.O_WRONLY | os.O_NONBLOCK)
    os.close(fd)
    print(\"✓ User can open /dev/uinput for virtual device creation\")
except Exception as e:
    print(f\"✗ Cannot open /dev/uinput: {e}\")
" 2>/dev/null || echo "✓ /dev/uinput accessible (python test unavailable)"
else
    echo "✗ /dev/uinput not writable"
fi'

# Check GLIBCXX availability
echo "Checking GLIBCXX symbols for Sunshine..."
LIBSTDCXX_PATH="$(ldconfig -p 2>/dev/null | awk '/libstdc\\+\\+\\.so\\.6/ {print $4; exit}')"
if [[ -n "$LIBSTDCXX_PATH" ]]; then
    if strings "$LIBSTDCXX_PATH" 2>/dev/null | grep -q "GLIBCXX_3.4.3[12]"; then
        echo "✓ GLIBCXX_3.4.31/32 available for Sunshine"
    else
        echo "✗ GLIBCXX_3.4.31/32 missing - Sunshine may not work"
    fi
else
    echo "✗ libstdc++6 not found"
fi

# Test Sunshine startup
echo "Testing Sunshine startup for ${USER_NAME}..."
su - "${USER_NAME}" -c 'timeout 10s /usr/bin/sunshine --help >/dev/null 2>&1 && echo "✓ Sunshine can start" || echo "✗ Sunshine startup failed"'

IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
if [ -z "$IP" ]; then
  IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

echo "========================================"
echo "Setup completed successfully!"
echo "========================================"
echo "VNC available at ${IP:-0.0.0.0}:$VNC_PORT (password: $VNC_PASS)"
echo "RDP available at ${IP:-0.0.0.0}:$RDP_PORT (user: $USER_NAME / password: $USER_PASS)"
echo "Sunshine Web UI: http://${IP:-0.0.0.0}:47990"
echo "========================================"
echo "Service status:"
sudo systemctl is-active vncserver@${VNC_DISPLAY} && echo "✓ VNC server running" || echo "✗ VNC server failed"
sudo systemctl is-active xrdp && echo "✓ XRDP server running" || echo "✗ XRDP server failed"
su - "${USER_NAME}" -c 'systemctl --user is-active sunshine' && echo "✓ Sunshine user service running" || echo "✗ Sunshine user service not running"
if pgrep -u "${USER_NAME}" -x sunshine >/dev/null; then
    echo "✓ Sunshine process running for ${USER_NAME}"
else
    echo "✗ No Sunshine process found for ${USER_NAME}"
fi

echo "========================================"
echo "XRDP Session Configuration:"
if grep -A 10 "\\[Plasma Shared TigerVNC\\]" /etc/xrdp/xrdp.ini 2>/dev/null; then
    echo "✓ Plasma Shared TigerVNC session found in XRDP config"
else
    echo "✗ Plasma Shared TigerVNC session missing from XRDP config"
fi

echo "========================================"
echo "Connection Instructions:"
echo "1. VNC Direct: vnc://${IP:-0.0.0.0}:${VNC_PORT} (password: ${VNC_PASS})"
echo "2. RDP to VNC: rdp://${IP:-0.0.0.0}:${RDP_PORT}"
echo "   - Username: ${USER_NAME}"
echo "   - Password: ${USER_PASS}"
echo "   - Session: Select 'Plasma Shared TigerVNC'"
echo "   - VNC Password: ${VNC_PASS}"

echo "========================================"
echo "Port status:"
ss -tlnp | grep -E ':(22|3389|5900|5901|47990)' || echo "No services listening on expected ports"
echo "========================================"
echo "VNC logs (last 10 lines):"
tail -n 10 "/home/${USER_NAME}/.vnc/"*.log 2>/dev/null || echo "No VNC logs found"
echo "========================================"
