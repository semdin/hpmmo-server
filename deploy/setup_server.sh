#!/usr/bin/env bash
set -e
# HPMMO dedicated server + database installer (Ubuntu 22.04+).
# Phase 3 layout. Credentials come from /etc/hpmmo/hpmmo.env - never hardcoded.
# Phase 6 replaces this script with the staged deployment controller + drain flow.

echo "=========================================================="
echo ">>> HPMMO DEDICATED SERVER & DB INSTALLER <<<"
echo "=========================================================="

BASE_DIR="$HOME/hpmmo"
BIN_DIR="$BASE_DIR/bin"
GAME_DIR="$BASE_DIR/game"
ENV_DIR="/etc/hpmmo"
ENV_FILE="$ENV_DIR/hpmmo.env"

# 0. Prepare the environment file (edit it before first start)
if [ ! -f "$ENV_FILE" ]; then
    sudo mkdir -p "$ENV_DIR"
    sudo tee "$ENV_FILE" > /dev/null <<'EOF'
# HPMMO server secrets - fill in and chmod 600. See deploy/hpmmo.env.example.
DATABASE_URL=postgresql://hpmmo:CHANGE_ME@localhost:5432/hpmmo_db
HPMMO_DB_PASSWORD=CHANGE_ME
EOF
    sudo chmod 600 "$ENV_FILE"
    echo ">>> Created $ENV_FILE - set real credentials, then re-run this script."
fi
# shellcheck disable=SC1090
source "$ENV_FILE"
if [ "${HPMMO_DB_PASSWORD:-CHANGE_ME}" = "CHANGE_ME" ]; then
    echo "ERROR: set HPMMO_DB_PASSWORD (and DATABASE_URL) in $ENV_FILE first." >&2
    exit 1
fi

# 1. Update and install prerequisites
echo "[1/5] Updating packages and installing prerequisites..."
sudo apt-get update -y
sudo apt-get install -y wget unzip tar curl ufw python3 python3-pip postgresql postgresql-contrib build-essential cmake ninja-build libpq-dev
pip3 install psycopg2-binary || pip install psycopg2-binary --break-system-packages || true

# 2. Setup Godot 4.7.2 Linux Headless Engine
echo "[2/5] Setting up Godot 4.7.2 Linux Server Engine..."
mkdir -p "$BIN_DIR" "$GAME_DIR"
if [ ! -f "$BIN_DIR/godot_server" ]; then
    cd /tmp
    wget -c "https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip" -O godot_linux.zip
    unzip -o godot_linux.zip
    mv Godot_v4.7.2-stable_linux.x86_64 "$BIN_DIR/godot_server"
    chmod +x "$BIN_DIR/godot_server"
    rm -f godot_linux.zip
fi

# 3. Unpack the server release package (built by deploy/package_server.ps1)
echo "[3/5] Extracting HPMMO server files..."
if [ -f "$HOME/hpmmo_server.tar.gz" ]; then
    tar -xzf "$HOME/hpmmo_server.tar.gz" -C "$GAME_DIR"
elif [ -f "./hpmmo_server.tar.gz" ]; then
    tar -xzf "./hpmmo_server.tar.gz" -C "$GAME_DIR"
else
    echo "Notice: place a package built by deploy/package_server.ps1 at $HOME/hpmmo_server.tar.gz."
fi

# Run Godot headless editor import pass to build class caches and imports
if [ -f "$BIN_DIR/godot_server" ] && [ -d "$GAME_DIR/world" ]; then
    echo "Running Godot import pass on world..."
    "$BIN_DIR/godot_server" --headless --path "$GAME_DIR/world" --editor --import --quit 2>&1 || true
fi

# Configure PostgreSQL (hpmmo_db and hpmmo user) using the env password
if command -v psql &> /dev/null; then
    echo "Configuring PostgreSQL user and database (hpmmo_db)..."
    sudo systemctl start postgresql || true
    sudo -u postgres psql -c "CREATE USER hpmmo WITH PASSWORD '$HPMMO_DB_PASSWORD';" 2>/dev/null || \
        sudo -u postgres psql -c "ALTER USER hpmmo WITH PASSWORD '$HPMMO_DB_PASSWORD';"
    sudo -u postgres psql -c "CREATE DATABASE hpmmo_db OWNER hpmmo;" 2>/dev/null || true
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE hpmmo_db TO hpmmo;" 2>/dev/null || true

    if [ -f "$GAME_DIR/deploy/apply_migrations.sh" ]; then
        echo "Applying database migrations..."
        bash "$GAME_DIR/deploy/apply_migrations.sh" || true
    fi
fi

# Compile C++ persistence microservice (Phase 4)
if [ -d "$GAME_DIR/services/cpp" ]; then
    echo "Building C++ persistence service (hpmmo_service)..."
    rm -rf "$GAME_DIR/services/cpp/build"
    cmake -S "$GAME_DIR/services/cpp" -B "$GAME_DIR/services/cpp/build" -G Ninja -DCMAKE_BUILD_TYPE=Release
    ninja -C "$GAME_DIR/services/cpp/build"
fi

# 4. Firewall (SSH, 7777 UDP game, 8081 TCP API - see plan.md B3 before exposing 8081)
echo "[4/5] Configuring Linux UFW Firewall..."
sudo ufw allow 22/tcp || true
sudo ufw allow 7777/udp || true
sudo ufw allow 8081/tcp || true
sudo ufw --force enable || true

# 5. Release layout + systemd units (Phase 6)
#    The world/db units run through $RELEASES_DIR/current so a release swap is
#    an atomic symlink rename, not a rewrite of live files. The status endpoint
#    (loopback only) answers /status while the world server is stopped.
echo "[5/5] Installing the staged release layout and systemd services..."
RELEASES_DIR="${HPMMO_RELEASES_DIR:-/opt/hpmmo/releases}"
LAYOUT="$0"
if [ -d "$GAME_DIR" ]; then
    # Adopt the tree this script just unpacked as the first release, so the
    # first controller deployment has a known-good release to roll back to.
    sudo bash "$(dirname "$LAYOUT")/install_layout.sh" \
        --releases-dir "$RELEASES_DIR" --run-user "$USER" \
        --godot "$BIN_DIR/godot_server" --adopt "$GAME_DIR"
else
    sudo bash "$(dirname "$LAYOUT")/install_layout.sh" \
        --releases-dir "$RELEASES_DIR" --run-user "$USER" --godot "$BIN_DIR/godot_server"
fi

echo "=========================================================="
echo ">>> HPMMO SERVER SETUP COMPLETE <<<"
echo "=========================================================="
echo "Start:  sudo systemctl start hpmmo-db hpmmo     Stop: sudo systemctl stop hpmmo hpmmo-db"
echo "Logs:   journalctl -u hpmmo-db -f   /   journalctl -u hpmmo -f"
echo "Status: curl -s http://127.0.0.1:8083/status"
echo "Deploy: sudo bash $(dirname "$0")/hpmmo_deploy.sh --deploy <artifact.tar.gz>"
echo "=========================================================="
sudo systemctl status hpmmo-db --no-pager || true
sudo systemctl status hpmmo --no-pager || true
