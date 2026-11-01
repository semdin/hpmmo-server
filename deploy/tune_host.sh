#!/usr/bin/env bash
# Host tuning for the HPMMO world box (VPS: 4 vCPU, 8 GB RAM, VMware balloon).
# Idempotent; safe to re-run. Takes effect for the world unit at its next
# restart (every deploy restarts it).
#
#   - swap: the world server alone holds ~1 GB, and with no swap a short spike
#     (deploy import, a burst of joins) lets the kernel OOM-kill it outright.
#   - UDP buffers: ENet is one UDP socket for every player; the 208 KB kernel
#     default drops datagrams under a burst of snapshots instead of queueing.
#   - world unit drop-in: the game process is the last thing the OOM killer
#     picks, gets CPU before housekeeping, and has file-descriptor headroom;
#     its memory is protected from reclaim and it has its own CPUs.
#   - CI slice drop-in: the build runners are reclaimed before they push the
#     world into memory pressure.
set -euo pipefail

SWAPFILE=/swapfile
SWAP_SIZE=${HPMMO_SWAP_SIZE:-2G}
UNIT_DIR=${HPMMO_UNIT_DIR:-/etc/systemd/system}
WORLD_UNIT=${HPMMO_WORLD_UNIT:-hpmmo.service}
CI_SLICE=${HPMMO_CI_SLICE:-hpmmo-ci.slice}
# The world's CPUs; the CI slice runs on the others (AllowedCPUs=2-3).
WORLD_CPUS=${HPMMO_WORLD_CPUS:-0-1}
WORLD_MEMORY_MIN=${HPMMO_WORLD_MEMORY_MIN:-1800M}
CI_MEMORY_HIGH=${HPMMO_CI_MEMORY_HIGH:-3G}

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
cat > "$UNIT_DIR/$WORLD_UNIT.d/90-tuning.conf" <<EOF
# HPMMO world server (see deploy/tune_host.sh)
[Service]
OOMScoreAdjust=-800
CPUWeight=400
Nice=-5
LimitNOFILE=65536
# The VM's memory balloon can squeeze the guest; the world must not be the
# process that gets swapped (a swapped-out page is a frame hitch for everyone).
MemorySwapMax=0
# ... nor the one whose pages the kernel reclaims when it does: the balloon
# took ~5 GB at once (2026-11-01) and kswapd stalled the world 140 ms a frame.
MemoryMin=$WORLD_MEMORY_MIN
# Its own CPUs: a client export and a server build in parallel on shared
# cores raised the world's worst frame to 58-149 ms.
AllowedCPUs=$WORLD_CPUS
EOF
if systemctl cat "$CI_SLICE" >/dev/null 2>&1; then
    mkdir -p "$UNIT_DIR/$CI_SLICE.d"
    cat > "$UNIT_DIR/$CI_SLICE.d/90-memory.conf" <<EOF
# HPMMO CI runners (see deploy/tune_host.sh): reclaimed and throttled from
# here, before the world feels the memory pressure (MemoryMax stays the cap).
[Slice]
MemoryHigh=$CI_MEMORY_HIGH
EOF
fi
systemctl daemon-reload
# Live as well: cgroup limits apply without restarting the world.
systemctl set-property --runtime "$WORLD_UNIT" MemoryMin="$WORLD_MEMORY_MIN" AllowedCPUs="$WORLD_CPUS"
if systemctl cat "$CI_SLICE" >/dev/null 2>&1; then
    systemctl set-property --runtime "$CI_SLICE" MemoryHigh="$CI_MEMORY_HIGH"
fi

# Unbounded journals reached 1.6 GB on the first box.
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/90-hpmmo.conf <<'EOF'
# HPMMO (see deploy/tune_host.sh)
[Journal]
SystemMaxUse=300M
EOF
systemctl restart systemd-journald

echo "tune_host: swap=$(swapon --show=SIZE --noheadings | head -1) swappiness=$(sysctl -n vm.swappiness) rmem_max=$(sysctl -n net.core.rmem_max)"
