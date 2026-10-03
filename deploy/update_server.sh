#!/usr/bin/env bash
set -e
# HPMMO server updater (Phase 3): installs a release package built by
# deploy/package_server.ps1 with a staged swap and rollback.
#
# Managed upgrade flow on the VPS:
#   1. copy the packaged hpmmo-server-*.tar.gz to $HOME/hpmmo_server.tar.gz
#   2. run: bash deploy/update_server.sh
#
# Players are disconnected by the service stop; the countdown/drain/save
# barriers arrive with the Phase 6 maintenance controller. Live files are
# NEVER modified in place: the new release extracts to game.new, is sanity
# checked, and swapped in with game.old kept for rollback.

BASE_DIR="$HOME/hpmmo"
GAME_DIR="$BASE_DIR/game"
STAGE_DIR="$BASE_DIR/game.new"
OLD_DIR="$BASE_DIR/game.old"
ARCHIVE="${1:-$HOME/hpmmo_server.tar.gz}"

echo ">>> HPMMO SERVER UPDATE <<<"
if [ ! -f "$ARCHIVE" ]; then
    echo "ERROR: package not found at $ARCHIVE" >&2
    exit 1
fi

echo "[1/6] Extracting $ARCHIVE to staging..."
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
tar -xzf "$ARCHIVE" -C "$STAGE_DIR"

echo "[2/6] Sanity checks on the staged release..."
for f in world/project.godot services/db_service.py contracts/protocol.md; do
    if [ ! -e "$STAGE_DIR/$f" ]; then
        echo "ERROR: staged release is missing $f" >&2
        exit 1
    fi
done
if find "$STAGE_DIR" -name '*.db' | grep -q .; then
    echo "ERROR: staged release contains an account database file" >&2
    exit 1
fi

echo "[3/6] Stopping services..."
sudo systemctl stop hpmmo || true
sudo systemctl stop hpmmo-db || true

echo "[4/6] Swapping releases (rollback copy at $OLD_DIR)..."
rm -rf "$OLD_DIR"
if [ -d "$GAME_DIR" ]; then
    mv "$GAME_DIR" "$OLD_DIR"
fi
mv "$STAGE_DIR" "$GAME_DIR"

echo "[5/6] Applying schema migrations (idempotent)..."
"$GAME_DIR/deploy/apply_migrations.sh" || {
    echo "Migration failed - rolling back." >&2
    rm -rf "$GAME_DIR"
    mv "$OLD_DIR" "$GAME_DIR"
    sudo systemctl start hpmmo-db hpmmo || true
    exit 1
}

echo "[6/6] Starting services and verifying readiness..."
sudo systemctl daemon-reload
sudo systemctl start hpmmo-db hpmmo
for _ in $(seq 1 15); do
    if curl -fsS "http://localhost:8081/api/health" > /dev/null 2>&1; then
        echo ">>> UPDATE COMPLETE - db service reports healthy."
        echo "    Previous release kept at $OLD_DIR (delete when satisfied)."
        exit 0
    fi
    sleep 1
done

echo "Readiness check failed - rolling back." >&2
sudo systemctl stop hpmmo hpmmo-db || true
rm -rf "$GAME_DIR"
mv "$OLD_DIR" "$GAME_DIR"
sudo systemctl start hpmmo-db hpmmo || true
exit 1
