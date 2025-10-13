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
GEOM="${GEOM:-1280x720}"
VNC_PORT="${VNC_PORT:-5900}"
SUN_HTTP_TLS_PORT="${SUN_HTTP_TLS_PORT:-47990}"

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
USER_UID="$(id -u "$USER_NAME")"

# =================== DESKTOP + XRDP + TigerVNC ===================
step "2/11 Cài KDE Plasma + XRDP + TigerVNC"
apt -y install \
  kde-standard sddm xorg \
  xrdp xorgxrdp pulseaudio \
  tigervnc-standalone-server \
  remmina remmina-plugin-rdp remmina-plugin-vnc flatpak \
  mesa-vulkan-drivers libgl1-mesa-dri libasound2 libpulse0 libxkbcommon0 >>"$LOG" 2>&1

# Ensure xrdp is enabled and uses our startwm (Plasma session)
systemctl enable --now xrdp >>"$LOG" 2>&1 || true

XRDP_INI="/etc/xrdp/xrdp.ini"
if [[ -f "$XRDP_INI" ]]; then
  if ! grep -q 'Plasma Shared TigerVNC' "$XRDP_INI" 2>/dev/null; then
    cat <<EOF >>"$XRDP_INI"

[Plasma Shared TigerVNC]
name=Plasma Shared TigerVNC
lib=libvnc.so
username=.
password=${VNC_PASS}
ip=127.0.0.1
port=${VNC_PORT}
EOF
  fi
  if grep -q '^autorun=' "$XRDP_INI" 2>/dev/null; then
    sed -i 's/^autorun=.*/autorun=Plasma Shared TigerVNC/' "$XRDP_INI"
  else
    sed -i '/^\[Globals\]/a autorun=Plasma Shared TigerVNC' "$XRDP_INI"
  fi
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

systemctl daemon-reload
systemctl enable --now vncserver@0.service >>"$LOG" 2>&1 || true

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

# Override systemd: run Sunshine as user lt4c on DISPLAY :0
install -d /etc/systemd/system/sunshine.service.d
cat >/etc/systemd/system/sunshine.service.d/override.conf <<EOF
[Service]
User=${USER_NAME}
Group=${USER_NAME}
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/${USER_UID}
ExecStartPre=/usr/local/bin/sunshine-wait-uinput.sh
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
Type=simple
ExecStartPre=/usr/local/bin/sunshine-wait-uinput.sh
ExecStart=/usr/bin/sunshine
Restart=on-failure
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/${USER_UID}
SupplementaryGroups=input uinput
NoNewPrivileges=true

[Install]
WantedBy=default.target
EOF
chown "${USER_NAME}:${USER_NAME}" "$USR_UNIT_DIR/sunshine.service"

# Start as user
su - "${USER_NAME}" -c 'systemctl --user daemon-reload' || true
su - "${USER_NAME}" -c 'systemctl --user enable --now sunshine' || true

# Input stack
apt -y install evtest joystick >>"$LOG" 2>&1 || true
MODULE_CONF="/etc/modules-load.d/uinput.conf"
if [[ -f "$MODULE_CONF" ]]; then
  if ! grep -qxF 'uinput' "$MODULE_CONF"; then
    echo 'uinput' >>"$MODULE_CONF"
  fi
else
  echo 'uinput' >"$MODULE_CONF"
fi
modprobe uinput || true
groupadd -f input
groupadd -f uinput
usermod -aG input,uinput "${USER_NAME}"
cat >/etc/udev/rules.d/60-sunshine-input.rules <<'EOF'
KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"
SUBSYSTEM=="input", KERNEL=="event*", MODE="0660", GROUP="input"
EOF
chmod 644 /etc/udev/rules.d/60-sunshine-input.rules
udevadm control --reload-rules || true
udevadm trigger --subsystem-match=misc --action=add || true
udevadm trigger --subsystem-match=input --action=change || true

# Ensure Sunshine service has input supplementary group
cat >/etc/systemd/system/sunshine.service.d/10-input.conf <<'EOF'
[Service]
SupplementaryGroups=input uinput
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

# =================== Sunshine autostart in XRDP sessions ===================
step "7.3/11 Bật Sunshine tự khởi động trong phiên XRDP"
USER_XSESSION="/home/${USER_NAME}/.xsessionrc"
if [[ ! -f "$USER_XSESSION" ]]; then
  install -m 0644 -o "${USER_NAME}" -g "${USER_NAME}" /dev/null "$USER_XSESSION"
fi
if ! grep -q 'SUNSHINE_XRDP_AUTOSTART' "$USER_XSESSION" 2>/dev/null; then
  cat <<'EOF' >>"$USER_XSESSION"

# >>> SUNSHINE_XRDP_AUTOSTART >>>
if [ "${DESKTOP_SESSION:-}" = "xrdp" ] && ! pgrep -u "$USER" -x sunshine >/dev/null; then
    if /usr/local/bin/sunshine-wait-uinput.sh; then
        /usr/bin/sunshine >>"$HOME/.local/share/sunshine/xrdp.log" 2>&1 &
    else
        echo "[WARN] Sunshine skipped (uinput not ready)" >>"$HOME/.local/share/sunshine/xrdp.log"
    fi
fi
# <<< SUNSHINE_XRDP_AUTOSTART <<<
EOF
  chown "${USER_NAME}:${USER_NAME}" "$USER_XSESSION"
fi

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

echo "TigerVNC : ${IP}:${VNC_PORT}  (pass: ${VNC_PASS})"
echo "XRDP     : ${IP}:3389        (user ${USER_NAME} / ${USER_PASS})"
echo "Sunshine : https://${IP}:${SUN_HTTP_TLS_PORT}  (UI tự ký; auto-add Steam & Chromium)"
echo "Moonlight: Mở shortcut 'Moonlight (Sunshine Web UI)' trên Desktop để pair"

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
