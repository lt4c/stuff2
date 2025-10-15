#!/bin/bash

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
fi

USERNAME="Red"
PASSWORD="124192"
VNC_DISPLAY="1"
VNC_PORT=$((5900 + VNC_DISPLAY))

echo "Updating package index..."
apt-get update

echo "Installing required packages..."
apt-get install -y sudo kde-plasma-desktop sddm dbus-x11 tigervnc-standalone-server tigervnc-common ufw

if ! id -u "$USERNAME" >/dev/null 2>&1; then
    echo "Creating user $USERNAME..."
    useradd -m -s /bin/bash "$USERNAME"
else
    echo "User $USERNAME already exists, skipping creation."
fi

echo "Setting password for $USERNAME..."
echo "$USERNAME:$PASSWORD" | chpasswd

echo "Granting sudo privileges to $USERNAME..."
usermod -aG sudo "$USERNAME"

echo "Configuring KDE Plasma for VNC sessions..."
sudo -u "$USERNAME" mkdir -p "/home/$USERNAME/.vnc"
cat <<'EOF' > "/home/$USERNAME/.vnc/xstartup"
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startplasma-x11
EOF
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.vnc/xstartup"
chmod +x "/home/$USERNAME/.vnc/xstartup"

echo "Setting TigerVNC password for $USERNAME..."
sudo -u "$USERNAME" bash -c "printf '%s\n' '$PASSWORD' | vncpasswd -f > ~/.vnc/passwd"
chmod 600 "/home/$USERNAME/.vnc/passwd"

echo "Creating systemd service for TigerVNC..."
cat <<'EOF' > /etc/systemd/system/vncserver@.service
[Unit]
Description=TigerVNC server for user %i
After=syslog.target network.target

[Service]
Type=forking
User=%i
PAMName=login
PIDFile=/home/%i/.vnc/%H:%i.pid
WorkingDirectory=/home/%i
ExecStart=/usr/bin/vncserver -geometry 1920x1080 -localhost no :1
ExecStop=/usr/bin/vncserver -kill :1

[Install]
WantedBy=multi-user.target
EOF

echo "Reloading systemd configuration..."
systemctl daemon-reload

echo "Enabling SDDM display manager..."
systemctl enable sddm >/dev/null 2>&1 || true

echo "Enabling and starting TigerVNC service for $USERNAME..."
systemctl enable --now "vncserver@${USERNAME}.service"

echo "Configuring UFW firewall..."
ufw allow "${VNC_PORT}/tcp"
ufw allow 5900:5905/tcp
ufw --force enable

echo "Setup complete. Connect to the server's public IP on TCP port ${VNC_PORT} using a VNC client."
