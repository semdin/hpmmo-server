#!/usr/bin/env bash
set -e

echo "=========================================================="
echo ">>> HPMMO SERVER UPDATER <<<"
echo "=========================================================="

if [ -d "$HOME/hpmmo/game" ]; then
    GAME_DIR="$HOME/hpmmo/game"
elif [ -d "$HOME/pottermetin/game" ]; then
    GAME_DIR="$HOME/pottermetin/game"
else
    GAME_DIR="$HOME/hpmmo/game"
    mkdir -p "$GAME_DIR"
fi

# 1. Stop systemd services
echo "[1/3] Stopping HPMMO services..."
sudo systemctl stop hpmmo || sudo systemctl stop pottermetin || true
sudo systemctl stop hpmmo-db || sudo systemctl stop pottermetin-db || true

# 2. Update files
echo "[2/3] Updating server files..."
if [ -d "$GAME_DIR/.git" ]; then
    echo "Updating via git pull in $GAME_DIR..."
    cd "$GAME_DIR"
    git pull
elif [ -f "$HOME/hpmmo_server.tar.gz" ]; then
    echo "Extracting $HOME/hpmmo_server.tar.gz to $GAME_DIR..."
    tar -xzf "$HOME/hpmmo_server.tar.gz" -C "$GAME_DIR"
elif [ -f "./hpmmo_server.tar.gz" ]; then
    echo "Extracting ./hpmmo_server.tar.gz to $GAME_DIR..."
    tar -xzf "./hpmmo_server.tar.gz" -C "$GAME_DIR"
elif [ -f "$HOME/pottermetin_server.tar.gz" ]; then
    echo "Extracting $HOME/pottermetin_server.tar.gz to $GAME_DIR..."
    tar -xzf "$HOME/pottermetin_server.tar.gz" -C "$GAME_DIR"
else
    echo "No tar.gz or git repo found. Ensure updated files are placed in $GAME_DIR."
fi

# Run any schema migrations if present
if command -v psql &> /dev/null && [ -f "$GAME_DIR/server/schema.sql" ]; then
    echo "Applying schema updates (if any)..."
    PGPASSWORD=REDACTED_SECRET psql -h localhost -U hpmmo -d hpmmo_db -f "$GAME_DIR/server/schema.sql" 2>/dev/null || \
    PGPASSWORD=REDACTED_SECRET psql -h localhost -U pottermetin -d hpmmo_db -f "$GAME_DIR/server/schema.sql" 2>/dev/null || \
    PGPASSWORD=REDACTED_SECRET psql -h localhost -U pottermetin -d pottermetin_db -f "$GAME_DIR/server/schema.sql" 2>/dev/null || true
fi

# 3. Restart systemd services
echo "[3/3] Restarting HPMMO services..."
sudo systemctl daemon-reload
if systemctl list-unit-files | grep -q hpmmo.service; then
    sudo systemctl restart hpmmo-db
    sudo systemctl restart hpmmo
    sudo systemctl status hpmmo-db --no-pager
    sudo systemctl status hpmmo --no-pager
else
    sudo systemctl restart pottermetin-db 2>/dev/null || true
    sudo systemctl restart pottermetin 2>/dev/null || true
    sudo systemctl status pottermetin-db --no-pager
    sudo systemctl status pottermetin --no-pager
fi

echo "=========================================================="
echo ">>> UPDATE COMPLETE! HPMMO SERVICES ARE LIVE! <<<"
echo "=========================================================="
