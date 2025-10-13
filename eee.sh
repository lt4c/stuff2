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
  mesa-vulkan-drivers libgl1-mesa-dri libasound2 libpulse0 libxkbcommon0
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
systemctl enable --now vncserver@${VNC_DISPLAY}.service || true

XRDP_INI="/etc/xrdp/xrdp.ini"
if [[ -f "$XRDP_INI" ]]; then
  sed -i 's/^port=.*/port=3389/' "$XRDP_INI" || true
  if ! grep -q '\[Plasma VNC\]' "$XRDP_INI" 2>/dev/null; then
    cat <<EOF >>"$XRDP_INI"

[Plasma VNC]
name=Plasma VNC
lib=libvnc.so
username=.
password=${VNC_PASS}
ip=127.0.0.1
port=${VNC_PORT}
EOF
  fi
  if grep -q '^autorun=' "$XRDP_INI" 2>/dev/null; then
    sed -i 's/^autorun=.*/autorun=Plasma VNC/' "$XRDP_INI"
  else
    sed -i '/^\[Globals\]/a autorun=Plasma VNC' "$XRDP_INI"
  fi
fi
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

if command -v ufw >/dev/null 2>&1; then
  ufw disable || true
fi

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
SupplementaryGroups=input uinput

[Install]
WantedBy=default.target
EOF
chown "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.config/systemd/user/sunshine.service"

install -d -m 0700 -o "${USER_NAME}" -g "${USER_NAME}" "/run/user/${USER_UID}" || true
systemctl disable --now sunshine || true
rm -f /etc/systemd/system/sunshine.service
rm -rf /etc/systemd/system/sunshine.service.d
systemctl disable --now /etc/systemd/system/sunshine.service >>/dev/null 2>&1 || true
systemctl daemon-reload
su - "${USER_NAME}" -c 'systemctl --user daemon-reload'
su - "${USER_NAME}" -c 'systemctl --user enable --now sunshine'

IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
if [ -z "$IP" ]; then
  IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

echo "VNC available at ${IP:-0.0.0.0}:$VNC_PORT (password $VNC_PASS)"
echo "RDP available at ${IP:-0.0.0.0}:$RDP_PORT (user $USER_NAME / $USER_PASS)"
echo "Sunshine service active for $USER_NAME"
