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

# Create SSH config for easier manual access
CONFIG_FILE="/root/.ssh/config"
HOST_ALIAS="iran-server-$REMOTE_PORT"

echo "[+] Updating SSH config at $CONFIG_FILE..."

mkdir -p /root/.ssh
touch "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# Remove any previous config block for this host alias
sed -i "/^Host $HOST_ALIAS\$/,/^Host /{/^Host /!d}" "$CONFIG_FILE"
sed -i "/^Host $HOST_ALIAS\$/d" "$CONFIG_FILE"

{
  echo "Host $HOST_ALIAS"
  echo "    HostName $DEST_IP"
  echo "    Port $SSH_PORT"
  echo "    User root"
  echo "    IdentityFile $KEY_FILE"
  if [[ "$USE_SECOND_IP" =~ ^[Yy]$ ]]; then
    echo "    BindAddress $BIND_IP"
  fi
  echo ""
} >> "$CONFIG_FILE"

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

echo ""
echo "✅ You can manually connect using:"
echo "    ssh $HOST_ALIAS"

# Add cronjob to restart the tunnel every 30 minutes
CRON_MARK="# Reverse SSH Auto-Restart for $SERVICE_NAME"
CRON_CMD="*/10 * * * * systemctl restart $SERVICE_NAME $CRON_MARK"

# Remove existing job (if present)
(crontab -l 2>/dev/null | grep -v "$CRON_MARK") | crontab -

# Add new job
(crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -

echo "[✓] Cronjob added: will restart $SERVICE_NAME every 30 minutes"
