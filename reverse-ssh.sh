#!/bin/bash
clear
echo "💻 Reverse SSH Tunnel Setup Script"
echo "----------------------------------"

# Input fields
read -p "🇮🇷 Destination IP (Iran server): " DEST_IP
read -p "🔑 SSH Password: " SSH_PASS
read -p "🛣️  Remote Port to open on Iran (e.g. 443): " REMOTE_PORT
read -p "📡 Local Port to forward to (on this server, e.g. 443): " LOCAL_PORT
read -p "🚪 SSH Port on Iran server [22]: " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

# Ask about binding from secondary IP
read -p "🌐 Do you want to bind the SSH connection from a secondary IP? (y/N): " USE_SECOND_IP

if [[ "$USE_SECOND_IP" =~ ^[Yy]$ ]]; then
  read -p "➡️  Enter the secondary IP address of this (foreign) server: " BIND_IP
  BIND_ARG="-b $BIND_IP"
  echo "[+] Will bind SSH from: $BIND_IP"
else
  BIND_ARG=""
  echo "[+] Will use default IP to connect"
fi

SERVICE_NAME="reverse-ssh-${REMOTE_PORT}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Check if service exists
if systemctl list-units --full -all | grep -q "$SERVICE_NAME"; then
  echo "⚠️  A tunnel using port $REMOTE_PORT already exists as $SERVICE_NAME."
  read -p "❓ Do you want to stop and remove the existing tunnel? [y/N]: " CONFIRM
  if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "[+] Removing old service..."
    systemctl stop "$SERVICE_NAME"
    systemctl disable "$SERVICE_NAME"
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    echo "[✓] Old service removed."
  else
    echo "❌ Aborting to avoid conflict on port $REMOTE_PORT."
    exit 1
  fi
fi

# Generate SSH key if needed
KEY_FILE="/root/.ssh/id_rsa_reverse"
if [[ ! -f "$KEY_FILE" ]]; then
  echo "[+] Generating new SSH key..."
  ssh-keygen -t rsa -b 4096 -f "$KEY_FILE" -N "" -C "reverse-tunnel" <<< y >/dev/null
fi

# Install sshpass if missing
if ! command -v sshpass &>/dev/null; then
  echo "[+] Installing sshpass..."
  apt-get update && apt-get install -y sshpass
fi

# Copy SSH key
echo "[+] Copying SSH key to $DEST_IP..."
sshpass -p "$SSH_PASS" ssh-copy-id -i "${KEY_FILE}.pub" -p "$SSH_PORT" -o StrictHostKeyChecking=no root@"$DEST_IP"

# Create systemd service
echo "[+] Creating systemd service at $SERVICE_FILE..."

cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Reverse SSH Tunnel: Iran:$REMOTE_PORT → Foreign:localhost:$LOCAL_PORT
After=network.target

[Service]
ExecStart=/usr/bin/ssh -p $SSH_PORT -i $KEY_FILE -N -R $REMOTE_PORT:localhost:$LOCAL_PORT root@$DEST_IP $BIND_ARG
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
echo "[+] Enabling and starting systemd service..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

# Show status
echo "[✓] Reverse SSH tunnel is set up and running:"
systemctl status "$SERVICE_NAME" --no-pager
