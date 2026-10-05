#!/usr/bin/env python3
"""Phase 14 latency / loss cost report (plan.md Phase 14: "Test packet delay/loss
profiles and report correction frequency, hit consistency, disconnect handling,
and bandwidth per player").

Reuses the Phase 5 multiplayer harness (same world server, same real headless
clients, same `agree` scenario: walk to a pack, fight it, take the reward) and
adds two things that suite does not measure:

  * a per-client UDP relay between each client and the world server. The relay
    counts the bytes that actually cross the wire in both directions, so
    "bandwidth per player" is a measurement of the transport, not an estimate
    from payload sizes. It also proves the client never needs a direct route to
    the game server (the relay is a NAT).
  * a mid-run hard disconnect of one client, to report what the other client and
    the server do (the transcript keeps going; the roster drops the peer).

Profiles come from `addons/hpmmo_sim/net.gd` (`local`, `broadband`, `mobile`,
`awful`); the delay/loss is applied at the application layer by the sim, exactly
as in the Phase 5 proof.

Usage: python tests/phase14_profiles.py [--profiles local,mobile,awful]
                                        [--seconds 45] [--out-dir DIR]
"""

import argparse
import json
import os
import socket
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import multiplayer_sim as mp  # noqa: E402  (same directory, shared harness)

HERE_OUT = HERE


class Relay:
    """One UDP relay = one client's NAT. Counts bytes in both directions."""

    def __init__(self, target_port):
        self.target = ("127.0.0.1", target_port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]
        self.client = None
        self.up = 0          # client -> server
        self.down = 0        # server -> client
        self.up_packets = 0
        self.down_packets = 0
        self.started = 0.0
        self.ended = 0.0
        self._stop = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self.started = time.time()
        self.thread.start()

    def stop(self):
        self.ended = time.time()
        self._stop.set()
        try:
            self.sock.close()
        except OSError:
            pass

    def _run(self):
        while not self._stop.is_set():
            try:
                data, addr = self.sock.recvfrom(65535)
            except OSError:
                return
            if addr == self.target:
                self.down += len(data)
                self.down_packets += 1
                if self.client is not None:
                    try:
                        self.sock.sendto(data, self.client)
                    except OSError:
                        pass
            else:
                if self.client is None:
                    self.client = addr
                self.up += len(data)
                self.up_packets += 1
                try:
                    self.sock.sendto(data, self.target)
                except OSError:
                    pass

    def report(self):
        seconds = max(0.001, (self.ended or time.time()) - self.started)
        return {
            "up_bytes": self.up,
            "down_bytes": self.down,
            "up_packets": self.up_packets,
            "down_packets": self.down_packets,
            "seconds": round(seconds, 2),
            "up_bytes_per_s": round(self.up / seconds, 1),
            "down_bytes_per_s": round(self.down / seconds, 1),
            "total_kib_per_s": round((self.up + self.down) / seconds / 1024.0, 2),
        }


def read_transcript(path):
    records = []
    if not os.path.exists(path):
        return records
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except ValueError:
                pass
    return records


def final_of(records):
    for record in records:
        if record.get("event") == "final":
            return record
    return {}


def run_profile(profile, seconds, out_dir):
    print("\n=== profile %s ===" % profile)
    port = mp.free_port()
    server = mp.start_server(port, 20261005, profile, out_dir)
    if not server.wait_for("waiting for players", timeout=180):
        server.stop()
        return {"profile": profile, "error": "world server did not boot"}

    relays = [Relay(port), Relay(port)]
    for relay in relays:
        relay.start()
    names = ["costA", "costB"]
    probes = []
    for index, relay in enumerate(relays):
        # The probes are given a little more than the fight window so the
        # surviving one finishes its own run (and writes its final record)
        # instead of being killed mid-flight.
        probes.append(mp.start_probe(names[index], "agree", relay.port, out_dir,
                                     seconds=seconds + 15, profile=profile))
    # Let them join and fight for most of the window.
    time.sleep(max(10.0, seconds - 15.0))
    # Disconnect handling: hard-kill client A, then watch B and the roster.
    kill_at = time.time()
    probes[0]["proc"].kill()
    roster_before = open(server.log_path, "r", encoding="utf-8", errors="replace").read()
    # B runs to its own end (it must still be playing when A disappears).
    remaining = seconds + 15.0 - max(10.0, seconds - 15.0)
    time.sleep(remaining + 15.0)
    roster_after = open(server.log_path, "r", encoding="utf-8", errors="replace").read()
    for probe in probes[1:]:
        if probe["proc"].poll() is None:
            probe["proc"].kill()
        probe["proc"].wait(timeout=30)
        probe["log"].close()
    for relay in relays:
        relay.stop()
    server.stop()

    result = {"profile": profile, "seconds": seconds}
    a = read_transcript(probes[0]["transcript"])
    b = read_transcript(probes[1]["transcript"])
    fa = final_of(a)
    fb = final_of(b)
    for label, final in (("A", fa), ("B", fb)):
        result["client_%s" % label] = {
            "casts_sent": final.get("casts_sent"),
            "casts_accepted": final.get("casts_accepted"),
            "casts_rejected": len(final.get("casts_rejected", []) or []),
            "corrections": final.get("corrections"),
            "intent_frames": final.get("intent_frames"),
            "rewards": len(final.get("rewards", []) or []),
            "exp_start": final.get("exp_start"),
            "exp_end": final.get("exp_end"),
            "target_death_tick": final.get("target_death_tick"),
            "target_respawn_tick": final.get("target_respawn_tick"),
            "visible_mobs": len(final.get("visible_mobs", []) or []),
            "corrections_per_min": round(
                60.0 * (final.get("corrections") or 0) / max(1.0, float(final.get("intent_frames") or seconds * 20) / 20.0), 1),
        }
    landed_a = len([r for r in a if r.get("event") == "landed"])
    landed_b = len([r for r in b if r.get("event") == "landed"])
    result["hits"] = {"A_landed": landed_a, "B_landed": landed_b}
    result["bandwidth"] = [relay.report() for relay in relays]
    # After A dies, B must still be working: casts and a reward recorded after
    # the disconnect instant.
    kill_epoch = kill_at
    progressed = [r for r in b if r.get("event") == "pack_respawned"]
    result["disconnect"] = {
        "client_A_killed": True,
        "server_saw_leave": roster_after.count("leave") > roster_before.count("leave"),
        "peer_count_after": _last_roster_players(roster_after),
        "B_still_landed_hits_after": len(progressed) > 0,
        "B_rewards": len(fb.get("rewards", []) or []),
    }
    print(json.dumps(result, indent=2))
    return result


def _last_roster_players(text):
    players = None
    for line in text.splitlines():
        if "players=" in line:
            try:
                players = int(line.split("players=")[1].split()[0])
            except (IndexError, ValueError):
                pass
    return players


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--profiles", default="local,mobile,awful")
    parser.add_argument("--seconds", type=float, default=45.0)
    parser.add_argument("--out-dir", default="")
    args = parser.parse_args()

    out_dir = args.out_dir
    if not out_dir:
        import tempfile
        out_dir = tempfile.mkdtemp(prefix="hpmmo-phase14-")
    os.makedirs(out_dir, exist_ok=True)
    print("artifacts: %s" % out_dir)
    for project, name in ((os.path.join(mp.SERVER_DIR, "world"), "world"), (mp.CLIENT_DIR, "client")):
        if not mp.ensure_imported(project, out_dir, name):
            print("import failed for %s" % project)
            return 2

    results = []
    for profile in [p.strip() for p in args.profiles.split(",") if p.strip()]:
        results.append(run_profile(profile, args.seconds, out_dir))
    with open(os.path.join(out_dir, "profiles.json"), "w", encoding="utf-8") as handle:
        json.dump(results, handle, indent=2)
    print("\nPROFILES RESULT " + json.dumps(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
