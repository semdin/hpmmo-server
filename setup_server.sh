#!/usr/bin/env bash
set -e

echo "=========================================================="
echo ">>> POTTERMETIN MMO DEDICATED SERVER INSTALLER <<<"
echo "=========================================================="

# 1. Update and install prerequisites
echo "[1/4] Updating packages and installing prerequisites..."
sudo apt-get update -y
sudo apt-get install -y wget unzip tar curl ufw

# 2. Setup Godot 4.7.2 Linux Headless Engine
echo "[2/4] Downloading Godot 4.7.2 Linux Server Engine..."
mkdir -p "$HOME/pottermetin/bin"
mkdir -p "$HOME/pottermetin/game"

if [ ! -f "$HOME/pottermetin/bin/godot_server" ]; then
    cd /tmp
    wget -c "https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip" -O godot_linux.zip
    unzip -o godot_linux.zip
    mv Godot_v4.7.2-stable_linux.x86_64 "$HOME/pottermetin/bin/godot_server"
    chmod +x "$HOME/pottermetin/bin/godot_server"
    rm -f godot_linux.zip
fi

# 3. Unpack game files if archive present in home or current directory
if [ -f "$HOME/pottermetin_server.tar.gz" ]; then
    echo "[3/4] Extracting pottermetin_server.tar.gz..."
    tar -xzf "$HOME/pottermetin_server.tar.gz" -C "$HOME/pottermetin/game"
elif [ -f "./pottermetin_server.tar.gz" ]; then
    echo "[3/4] Extracting pottermetin_server.tar.gz..."
    tar -xzf "./pottermetin_server.tar.gz" -C "$HOME/pottermetin/game"
else
    echo "[3/4] Notice: Place pottermetin_server.tar.gz in $HOME before launching."
fi

# 4. Configure Firewall (allow port 7777 UDP and port 22 SSH)
echo "[4/4] Configuring Linux UFW Firewall..."
sudo ufw allow 22/tcp || true
sudo ufw allow 7777/udp || true
sudo ufw --force enable || true

# 5. Create Systemd Background Service
echo "Creating systemd 24/7 service (pottermetin.service)..."
sudo tee /etc/systemd/system/pottermetin.service > /dev/null <<EOF
[Unit]
Description=PotterMetin MMO Dedicated Game Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME/pottermetin/game
ExecStart=$HOME/pottermetin/bin/godot_server --headless scenes/server/dedicated_server.tscn
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable pottermetin

echo "=========================================================="
echo ">>> POTTERMETIN SERVER SETUP COMPLETE! <<<"
echo "=========================================================="
echo "Start the server with:    sudo systemctl start pottermetin"
echo "Stop the server with:     sudo systemctl stop pottermetin"
echo "Check live status:        sudo systemctl status pottermetin"
echo "View real-time logs:      journalctl -u pottermetin -f"
echo "=========================================================="
