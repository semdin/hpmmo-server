#!/usr/bin/env bash
set -e

echo "=========================================================="
echo ">>> HPMMO DEDICATED SERVER & DB INSTALLER <<<"
echo "=========================================================="

BASE_DIR="$HOME/hpmmo"
BIN_DIR="$BASE_DIR/bin"
GAME_DIR="$BASE_DIR/game"

# 1. Update and install prerequisites
echo "[1/5] Updating packages and installing prerequisites..."
sudo apt-get update -y
sudo apt-get install -y wget unzip tar curl ufw python3 python3-pip postgresql postgresql-contrib

# Optional: Python psycopg2 for PostgreSQL support
pip3 install psycopg2-binary || pip install psycopg2-binary --break-system-packages || true

# 2. Setup Godot 4.7.2 Linux Headless Engine
echo "[2/5] Setting up Godot 4.7.2 Linux Server Engine..."
mkdir -p "$BIN_DIR"
mkdir -p "$GAME_DIR"

# Symlink migration if old pottermetin folder existed
if [ -d "$HOME/pottermetin/bin" ] && [ ! -f "$BIN_DIR/godot_server" ]; then
    cp -r "$HOME/pottermetin/bin/"* "$BIN_DIR/" 2>/dev/null || true
fi

if [ ! -f "$BIN_DIR/godot_server" ]; then
    cd /tmp
    wget -c "https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip" -O godot_linux.zip
    unzip -o godot_linux.zip
    mv Godot_v4.7.2-stable_linux.x86_64 "$BIN_DIR/godot_server"
    chmod +x "$BIN_DIR/godot_server"
    rm -f godot_linux.zip
fi

# 3. Unpack game files
echo "[3/5] Extracting HPMMO server files..."
if [ -f "$HOME/hpmmo_server.tar.gz" ]; then
    tar -xzf "$HOME/hpmmo_server.tar.gz" -C "$GAME_DIR"
elif [ -f "./hpmmo_server.tar.gz" ]; then
    tar -xzf "./hpmmo_server.tar.gz" -C "$GAME_DIR"
elif [ -f "$HOME/pottermetin_server.tar.gz" ]; then
    tar -xzf "$HOME/pottermetin_server.tar.gz" -C "$GAME_DIR"
elif [ -f "./pottermetin_server.tar.gz" ]; then
    tar -xzf "./pottermetin_server.tar.gz" -C "$GAME_DIR"
else
    echo "Notice: Place hpmmo_server.tar.gz in $HOME before launching."
fi

# Configure PostgreSQL (hpmmo_db and hpmmo user)
if command -v psql &> /dev/null; then
    echo "Configuring PostgreSQL user and database (hpmmo_db)..."
    sudo systemctl start postgresql || true
    sudo -u postgres psql -c "CREATE USER hpmmo WITH PASSWORD 'REDACTED_SECRET';" 2>/dev/null || true
    sudo -u postgres psql -c "CREATE DATABASE hpmmo_db OWNER hpmmo;" 2>/dev/null || true
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE hpmmo_db TO hpmmo;" 2>/dev/null || true
    # Legacy compatibility fallback user
    sudo -u postgres psql -c "CREATE USER pottermetin WITH PASSWORD 'REDACTED_SECRET';" 2>/dev/null || true
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE hpmmo_db TO pottermetin;" 2>/dev/null || true

    if [ -f "$GAME_DIR/server/schema.sql" ]; then
        PGPASSWORD=REDACTED_SECRET psql -h localhost -U hpmmo -d hpmmo_db -f "$GAME_DIR/server/schema.sql" 2>/dev/null || \
        PGPASSWORD=REDACTED_SECRET psql -h localhost -U pottermetin -d hpmmo_db -f "$GAME_DIR/server/schema.sql" 2>/dev/null || true
    fi
fi

# 4. Configure Firewall (allow port 22 SSH, 7777 UDP game, and 8081 TCP API)
echo "[4/5] Configuring Linux UFW Firewall..."
sudo ufw allow 22/tcp || true
sudo ufw allow 7777/udp || true
sudo ufw allow 8081/tcp || true
sudo ufw --force enable || true

# 5. Create Systemd Services (hpmmo-db & hpmmo)
echo "[5/5] Creating systemd background services..."

# Service 1: DB & Version Microservice
sudo tee /etc/systemd/system/hpmmo-db.service > /dev/null <<EOF
[Unit]
Description=HPMMO Database & Persistence Microservice
After=network.target postgresql.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$GAME_DIR/server
ExecStart=/usr/bin/python3 $GAME_DIR/server/db_service.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Service 2: Dedicated Godot Game Server
sudo tee /etc/systemd/system/hpmmo.service > /dev/null <<EOF
[Unit]
Description=HPMMO Dedicated Game Server
After=network.target hpmmo-db.service
Wants=hpmmo-db.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$GAME_DIR
ExecStart=$BIN_DIR/godot_server --headless scenes/server/dedicated_server.tscn
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Stop legacy services if active
sudo systemctl stop pottermetin 2>/dev/null || true
sudo systemctl stop pottermetin-db 2>/dev/null || true

sudo systemctl daemon-reload
sudo systemctl enable hpmmo-db
sudo systemctl enable hpmmo
sudo systemctl restart hpmmo-db hpmmo

echo "=========================================================="
echo ">>> HPMMO SERVER SETUP COMPLETE & SERVICES ARE LIVE! <<<"
echo "=========================================================="
echo "Start all services:       sudo systemctl start hpmmo-db hpmmo"
echo "Stop all services:        sudo systemctl stop hpmmo hpmmo-db"
echo "Check DB service logs:    journalctl -u hpmmo-db -f"
echo "Check Game Server logs:   journalctl -u hpmmo -f"
echo "=========================================================="
sudo systemctl status hpmmo-db --no-pager
sudo systemctl status hpmmo --no-pager
