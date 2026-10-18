#!/usr/bin/env bash
# Host tuning for the HPMMO world box (small VPS: 2 vCPU, ~2 GB RAM).
# Idempotent; safe to re-run. Takes effect for the world unit at its next
# restart (every deploy restarts it).
#
#   - swap: the world server alone holds ~1 GB, and with no swap a short spike
#     (deploy import, a burst of joins) lets the kernel OOM-kill it outright.
#   - UDP buffers: ENet is one UDP socket for every player; the 208 KB kernel
#     default drops datagrams under a burst of snapshots instead of queueing.
#   - world unit drop-in: the game process is the last thing the OOM killer
#     picks, gets CPU before housekeeping, and has file-descriptor headroom.
set -euo pipefail

SWAPFILE=/swapfile
SWAP_SIZE=${HPMMO_SWAP_SIZE:-2G}
UNIT_DIR=${HPMMO_UNIT_DIR:-/etc/systemd/system}
WORLD_UNIT=${HPMMO_WORLD_UNIT:-hpmmo.service}

if ! swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"; then
    if [ ! -f "$SWAPFILE" ]; then
        fallocate -l "$SWAP_SIZE" "$SWAPFILE"
        chmod 600 "$SWAPFILE"
        mkswap "$SWAPFILE" >/dev/null
    fi
    swapon "$SWAPFILE"
fi
grep -q "^$SWAPFILE " /etc/fstab || echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab

cat > /etc/sysctl.d/90-hpmmo.conf <<'EOF'
# HPMMO world server (see deploy/tune_host.sh)
vm.swappiness = 10
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 5000
EOF
sysctl -q -p /etc/sysctl.d/90-hpmmo.conf

mkdir -p "$UNIT_DIR/$WORLD_UNIT.d"
cat > "$UNIT_DIR/$WORLD_UNIT.d/90-tuning.conf" <<'EOF'
# HPMMO world server (see deploy/tune_host.sh)
[Service]
OOMScoreAdjust=-800
CPUWeight=400
Nice=-5
LimitNOFILE=65536
EOF
systemctl daemon-reload

echo "tune_host: swap=$(swapon --show=SIZE --noheadings | head -1) swappiness=$(sysctl -n vm.swappiness) rmem_max=$(sysctl -n net.core.rmem_max)"
