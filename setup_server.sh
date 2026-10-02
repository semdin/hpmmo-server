#!/usr/bin/env bash
set -e

echo "=========================================================="
echo ">>> POTTERMETIN MMO DEDICATED SERVER & DB INSTALLER <<<"
echo "=========================================================="

# 1. Update and install prerequisites
echo "[1/5] Updating packages and installing prerequisites..."
sudo apt-get update -y
sudo apt-get install -y wget unzip tar curl ufw python3 python3-pip postgresql postgresql-contrib

# Optional: Python psycopg2 for PostgreSQL support (db_service falls back to SQLite automatically if omitted)
pip3 install psycopg2-binary || pip install psycopg2-binary --break-system-packages || true

# 2. Setup Godot 4.7.2 Linux Headless Engine
echo "[2/5] Downloading Godot 4.7.2 Linux Server Engine..."
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
    echo "[3/5] Extracting pottermetin_server.tar.gz..."
    tar -xzf "$HOME/pottermetin_server.tar.gz" -C "$HOME/pottermetin/game"
elif [ -f "./pottermetin_server.tar.gz" ]; then
    echo "[3/5] Extracting pottermetin_server.tar.gz..."
    tar -xzf "./pottermetin_server.tar.gz" -C "$HOME/pottermetin/game"
else
    echo "[3/5] Notice: Place pottermetin_server.tar.gz in $HOME before launching."
fi

# Configure PostgreSQL if active
if command -v psql &> /dev/null; then
    echo "Configuring PostgreSQL user and database (pottermetin_db)..."
    sudo systemctl start postgresql || true
    sudo -u postgres psql -c "CREATE USER pottermetin WITH PASSWORD 'REDACTED_SECRET';" 2>/dev/null || true
    sudo -u postgres psql -c "CREATE DATABASE pottermetin_db OWNER pottermetin;" 2>/dev/null || true
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE pottermetin_db TO pottermetin;" 2>/dev/null || true
    if [ -f "$HOME/pottermetin/game/server/schema.sql" ]; then
        PGPASSWORD=REDACTED_SECRET psql -h localhost -U pottermetin -d pottermetin_db -f "$HOME/pottermetin/game/server/schema.sql" 2>/dev/null || true
    fi
fi

# 4. Configure Firewall (allow port 22 SSH, 7777 UDP game, and 8081 TCP database/version API)
echo "[4/5] Configuring Linux UFW Firewall..."
sudo ufw allow 22/tcp || true
sudo ufw allow 7777/udp || true
sudo ufw allow 8081/tcp || true
sudo ufw --force enable || true

# 5. Create Systemd Services (DB Microservice + Dedicated Game Server)
echo "[5/5] Creating systemd background services..."

# Service 1: DB & Version Microservice
sudo tee /etc/systemd/system/pottermetin-db.service > /dev/null <<EOF
[Unit]
Description=PotterMetin MMO Database & Persistence Microservice
After=network.target postgresql.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME/pottermetin/game/server
ExecStart=/usr/bin/python3 $HOME/pottermetin/game/server/db_service.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Service 2: Dedicated Godot Game Server
sudo tee /etc/systemd/system/pottermetin.service > /dev/null <<EOF
[Unit]
Description=PotterMetin MMO Dedicated Game Server
After=network.target pottermetin-db.service
Wants=pottermetin-db.service

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
sudo systemctl enable pottermetin-db
sudo systemctl enable pottermetin

echo "=========================================================="
echo ">>> POTTERMETIN SERVER SETUP COMPLETE! <<<"
echo "=========================================================="
echo "Start all services:       sudo systemctl start pottermetin-db pottermetin"
echo "Stop all services:        sudo systemctl stop pottermetin pottermetin-db"
echo "Check DB service logs:    journalctl -u pottermetin-db -f"
echo "Check Game Server logs:   journalctl -u pottermetin -f"
echo "=========================================================="
