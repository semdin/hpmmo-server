#!/usr/bin/env bash
set -e

echo "=========================================================="
echo ">>> POTTERMETIN MMO SERVER UPDATER <<<"
echo "=========================================================="

GAME_DIR="$HOME/pottermetin/game"

# 1. Stop systemd service
echo "[1/3] Stopping pottermetin service..."
sudo systemctl stop pottermetin || true

# 2. Update files
echo "[2/3] Updating server files..."
if [ -d "$GAME_DIR/.git" ]; then
    echo "Updating via git pull in $GAME_DIR..."
    cd "$GAME_DIR"
    git pull
elif [ -f "$HOME/pottermetin_server.tar.gz" ]; then
    echo "Extracting $HOME/pottermetin_server.tar.gz to $GAME_DIR..."
    tar -xzf "$HOME/pottermetin_server.tar.gz" -C "$GAME_DIR"
elif [ -f "./pottermetin_server.tar.gz" ]; then
    echo "Extracting ./pottermetin_server.tar.gz to $GAME_DIR..."
    tar -xzf "./pottermetin_server.tar.gz" -C "$GAME_DIR"
else
    echo "No tar.gz or git repo found. Ensure updated files are in $GAME_DIR."
fi

# 3. Restart systemd service
echo "[3/3] Restarting pottermetin service..."
sudo systemctl daemon-reload
sudo systemctl restart pottermetin

echo "=========================================================="
echo ">>> UPDATE COMPLETE! SERVER IS LIVE! <<<"
echo "=========================================================="
sudo systemctl status pottermetin --no-pager
