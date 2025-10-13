#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "Run this reset script as root." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

USER_NAME="lt4c"
VNC_DISPLAY=0
VNC_SERVICE="vncserver@${VNC_DISPLAY}.service"
SUN_USER_SERVICE="sunshine.service"

# Packages originally installed by eee.sh (may already exist on system)
PACKAGES_TO_PURGE=(
  kde-standard
  sddm
  xorg
  xrdp
  xorgxrdp
  tigervnc-standalone-server
  sunshine
  flatpak
  remmina
  remmina-plugin-rdp
  remmina-plugin-vnc
  curl
  wget
  jq
  ca-certificates
  gnupg2
  software-properties-common
  lsb-release
  xserver-xorg-core
  xserver-xorg-input-all
  xserver-xorg-video-dummy
  sudo
  dbus-x11
  xdg-utils
  desktop-file-utils
  dconf-cli
  binutils
  mesa-vulkan-drivers
  libgl1-mesa-dri
  libasound2
  libpulse0
  libxkbcommon0
)

echo "[RESET] Stopping services..."
systemctl disable --now "${VNC_SERVICE}" >/dev/null 2>&1 || true
systemctl disable --now xrdp >/dev/null 2>&1 || true
systemctl disable --now sunshine >/dev/null 2>&1 || true
su - "${USER_NAME}" -c 'systemctl --user disable --now sunshine >/dev/null 2>&1' || true

echo "[RESET] Removing systemd unit files..."
rm -f /etc/systemd/system/vncserver@.service
rm -f /etc/systemd/system/${VNC_SERVICE}
rm -f /etc/systemd/system/sunshine.service
rm -rf /etc/systemd/system/sunshine.service.d
systemctl daemon-reload
su - "${USER_NAME}" -c 'systemctl --user daemon-reload' || true

echo "[RESET] Cleaning VNC configuration..."
rm -f /etc/X11/xorg.conf.d/10-vnc-dummy.conf
rm -rf "/home/${USER_NAME}/.vnc"
rm -f "/home/${USER_NAME}/.xsession"
rm -f "/home/${USER_NAME}/.xsessionrc"
rm -rf "/home/${USER_NAME}/.config/plasma-workspace/env"

echo "[RESET] Cleaning Sunshine configuration..."
rm -rf "/home/${USER_NAME}/.config/sunshine"
rm -rf "/home/${USER_NAME}/.local/share/sunshine"
rm -f "/home/${USER_NAME}/.config/systemd/user/${SUN_USER_SERVICE}"
rm -f /usr/local/bin/sunshine-wait-uinput.sh
rm -f /etc/udev/rules.d/60-sunshine-input.rules
rm -f /etc/modules-load.d/uinput.conf
groupdel uinput >/dev/null 2>&1 || true

echo "[RESET] Removing installed packages (optional)"
apt-get purge -y "${PACKAGES_TO_PURGE[@]}" || true
apt-get autoremove -y --purge || true
apt-get autoclean -y || true

echo "[RESET] Re-enable display manager if installed..."
systemctl enable --now sddm >/dev/null 2>&1 || true

echo "[RESET] Reset complete. Consider reviewing remaining packages or configs manually."
