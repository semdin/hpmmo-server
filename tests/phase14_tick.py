#!/usr/bin/env python3
"""Phase 14 server tick headroom (plan.md Phase 14).

Runs the instrumented production boot (`client/scripts/test/phase14_tick.gd`,
which performs exactly `world_server.gd`'s steps and then times every
`SimAuthority._step` call) and walks it through increasing load levels by
starting real headless clients against it - the same clients the Phase 5
multiplayer proof uses, in their `agree` mode, so the load is players walking,
casting, killing packs and taking rewards.

Levels: 0, 2, 4, 8, 16 clients. Each level builds on the previous one (clients
stay connected), and the server keeps stepping at the production 20 Hz cadence.

Output: per-level p50/p95/p99/max of the authoritative step, the entity and
player counts, and the headroom against the 50 ms tick budget.

Usage:
  python tests/phase14_tick.py [--out-dir DIR] [--quick]

Environment: HPMMO_GODOT, HPMMO_CLIENT_DIR / HPMMO_SERVER_DIR.
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER_DIR = os.environ.get("HPMMO_SERVER_DIR", os.path.dirname(HERE))
WORKSPACE = os.path.dirname(SERVER_DIR)
CLIENT_DIR = os.environ.get("HPMMO_CLIENT_DIR", os.path.join(WORKSPACE, "client"))
GODOT = os.environ.get("HPMMO_GODOT", "godot")

LEVELS = [0, 2, 4, 8, 16]


def console_godot():
    """Resolve the console companion so a killed shell cannot orphan the GUI
    shim, and so subprocess waits behave on Windows."""
    candidate = GODOT
    if candidate.endswith("_console.exe"):
        return candidate
    alt = candidate[:-4] + "_console.exe" if candidate.endswith(".exe") else None
    for path in (alt,):
        if path and os.path.exists(path):
            return path
    return candidate


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def base_env(extra):
    env = dict(os.environ)
    env.update(extra)
    return env


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default=os.path.join(HERE, "out", "phase14"))
    parser.add_argument("--quick", action="store_true", help="2 s levels, for a smoke test")
    parser.add_argument("--levels", default="")
    args = parser.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)
    levels = [int(x) for x in args.levels.split(",")] if args.levels else LEVELS
    per_level = 8.0 if args.quick else 60.0

    godot = console_godot()
    port = free_port()
    tick_log = os.path.join(args.out_dir, "tick-server.log")
    tick_err = os.path.join(args.out_dir, "tick-server.err.log")
    server = subprocess.Popen(
        [godot, "--headless", "--path", CLIENT_DIR, "res://scenes/test/phase14_tick.tscn", "--",
         "--port=%d" % port, "--seconds=%d" % (30 + per_level * len(levels) + 30)],
        stdout=open(tick_log, "wb"), stderr=open(tick_err, "wb"),
        env=base_env({"HPMMO_ALLOW_DEV_JOIN": "1", "HPMMO_DEV_FAST_RESPAWN": "4000",
                      "HPMMO_DEV_SPAWN": "24,0.6,-25"}))
    print("[tick] server pid %d, port %d, log %s" % (server.pid, port, tick_log))

    # Wait for the world to be up.
    deadline = time.time() + 180
    ready = False
    while time.time() < deadline:
        if os.path.exists(tick_log):
            with open(tick_log, "rb") as handle:
                if b"TICK READY" in handle.read():
                    ready = True
                    break
        if server.poll() is not None:
            break
        time.sleep(1.0)
    if not ready:
        server.kill()
        print("TICK RESULT: server never became ready (see %s)" % tick_log)
        return 1

    probes = []
    windows = []
    script = os.path.join(CLIENT_DIR, "scenes", "test", "net_client_probe.tscn")
    try:
        current = 0
        for index, level in enumerate(levels):
            start = time.time()
            remaining = 30 + per_level * (len(levels) - index) + 10
            while current < level:
                name = "Load%d" % current
                transcript = os.path.join(args.out_dir, "load-%s.jsonl" % name)
                proc = subprocess.Popen(
                    [godot, "--headless", "--path", CLIENT_DIR, script, "--",
                     "--mode=agree", "--port=%d" % port, "--name=%s" % name,
                     "--out=%s" % transcript, "--seconds=%d" % int(remaining)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    env=base_env({"HPMMO_NET_PROFILE": "local"}))
                probes.append(proc)
                current += 1
            time.sleep(per_level)
            windows.append((level, start + 2.0, time.time() - 1.0))
            print("[tick] level %d clients done (%d alive)" % (
                level, sum(1 for p in probes if p.poll() is None)))
    finally:
        for proc in probes:
            if proc.poll() is None:
                proc.kill()
        if server.poll() is None:
            server.kill()

    # Fold the server's own reports into per-level numbers.
    rows = []
    with open(tick_log, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if not line.startswith("TICK {"):
                continue
            try:
                rows.append(json.loads(line[5:]))
            except ValueError:
                continue
    summary = []
    for level, start, end in windows:
        picked = [row for row in rows if start <= row["epoch"] <= end]
        if not picked:
            summary.append({"level": level, "reports": 0})
            continue
        steps = sum(row["steps"] for row in picked)
        weighted = lambda key: sum(row[key] * row["steps"] for row in picked) / max(1, steps)
        summary.append({
            "level": level,
            "reports": len(picked),
            "steps": steps,
            "players": max(row["players"] for row in picked),
            "entities": round(sum(row["entities"] for row in picked) / len(picked), 1),
            "p50_us": round(weighted("p50_us")),
            "p95_us": round(weighted("p95_us")),
            "p99_us": round(weighted("p99_us")),
            "max_us": max(row["max_us"] for row in picked),
            "budget_us": picked[0]["budget_us"],
        })
    out = os.path.join(args.out_dir, "tick-summary.json")
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2)
    print("TICK LEVELS " + json.dumps(summary))
    worst = max((r for r in summary if r.get("reports")), key=lambda r: r["p95_us"], default=None)
    if worst:
        headroom = 100.0 * (1.0 - float(worst["p95_us"]) / float(worst["budget_us"]))
        print("TICK RESULT worst_p95=%dus at %d players (budget %dus) headroom=%.1f%%" % (
            worst["p95_us"], worst["level"], worst["budget_us"], headroom))
    return 0


if __name__ == "__main__":
    sys.exit(main())
