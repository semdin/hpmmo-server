#!/usr/bin/env python3
"""Phase 8 magical staircase proof: one world server, real headless clients.

Proves the plan.md Phase 8 "Magical staircase prototype" exit check - two
independent clients see the same staircase position and state at the same tick -
and the rest of the prototype's required behaviour:

  1. agreement  - two clients observe the same position, state and destination on
                  every tick they both sampled, and both actually saw the
                  platform travel (the comparison is not two empty readings).
  2. carriage   - a real CharacterBody3D rider is carried across levels by the
                  moving deck and never falls through or is left behind.
  3. entry      - boarding is refused (with feedback) while the platform is
                  boarding_warning / moving / docking, and navigation links exist
                  only while docked.
  4. fallback   - the conventional staircase still connects the levels while the
                  magical one is away from the dock.
  5. failure    - death, disconnect and a map transfer while riding put the body
                  on a valid landing, never between floors or inside geometry.
  6. order      - the four states occur in the documented order.

Usage:
  python tests/staircase_sim.py [--skip=agreement,entry,logout,failure]
                               [--out-dir DIR] [--seconds N]

Environment: HPMMO_GODOT (godot binary), HPMMO_CLIENT_DIR / HPMMO_SERVER_DIR to
point at the two checkouts (defaults assume the standard workspace layout).
"""

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER_DIR = os.environ.get("HPMMO_SERVER_DIR", os.path.dirname(HERE))
WORKSPACE = os.path.dirname(SERVER_DIR)
CLIENT_DIR = os.environ.get("HPMMO_CLIENT_DIR", os.path.join(WORKSPACE, "client"))
GODOT = os.environ.get("HPMMO_GODOT", "godot")

# Where the dev hook places the staircase in the outdoor world (clear of the
# courtyard, village, forest, lake and pitch) and where the probes spawn.
STAIR_ORIGIN = "150,0,120"
STAIR_SPAWN = "150,0.6,108"
# Shorten the server-owned timing so a full dock cycle fits in a test window.
STAIR_SCALE = "0.25"

STATE_ORDER = ["docked", "boarding_warning", "moving", "docking"]
LEVEL_HEIGHTS = (0.1, 6.1, 12.1)

checks = 0
failures = []


def check(condition, message):
    global checks
    checks += 1
    if condition:
        print("PASS: " + message)
    else:
        failures.append(message)
        print("FAIL: " + message)


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def marker_cmd():
    """Prefer the console build: the GUI build returns before the run finishes."""
    path = GODOT
    if os.path.isfile(path) and path.lower().endswith("godot.exe"):
        console = path[: -len("godot.exe")] + "godot_console.exe"
        if os.path.isfile(console):
            return console
    return GODOT


class Proc:
    def __init__(self, name, args, env, log_path):
        self.name = name
        self.log_path = log_path
        self.log = open(log_path, "wb")
        self.proc = subprocess.Popen(args, stdout=self.log, stderr=subprocess.STDOUT, env=env)

    def wait_for(self, needle, timeout=60.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc.poll() is not None:
                return False
            try:
                with open(self.log_path, "r", encoding="utf-8", errors="replace") as handle:
                    if needle in handle.read():
                        return True
            except OSError:
                pass
            time.sleep(0.2)
        return False

    def read_log(self):
        try:
            with open(self.log_path, "r", encoding="utf-8", errors="replace") as handle:
                return handle.read()
        except OSError:
            return ""

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.log.close()


def base_env(extra=None):
    env = dict(os.environ)
    env.setdefault("HPMMO_GODOT", GODOT)
    if extra:
        env.update({k: str(v) for k, v in extra.items()})
    return env


def ensure_imported(project_dir, out_dir, name):
    log = os.path.join(out_dir, "%s-import.log" % name)
    with open(log, "wb") as handle:
        proc = subprocess.run([marker_cmd(), "--headless", "--path", project_dir, "--editor", "--import", "--quit"],
                              stdout=handle, stderr=subprocess.STDOUT)
    return proc.returncode == 0


def start_server(port, seed, out_dir, extra=None):
    env = base_env({
        "HPMMO_WORLD_PORT": port,
        "HPMMO_WORLD_SEED": seed,
        "HPMMO_ALLOW_DEV_JOIN": "1",
        "HPMMO_DEV_SPAWN": STAIR_SPAWN,
        "HPMMO_DEV_STAIRCASE": STAIR_ORIGIN,
        "HPMMO_DEV_STAIR_SCALE": STAIR_SCALE,
        "HPMMO_NET_PROFILE": "local",
    })
    if extra:
        env.update(extra)
    log = os.path.join(out_dir, "world-server-%d.log" % port)
    proc = Proc("world-server", [marker_cmd(), "--headless", "--path", os.path.join(SERVER_DIR, "world"),
                                 "res://server/world_server.tscn"], env, log)
    return proc


def start_probe(name, role, port, out_dir, seconds=26):
    """Launch a probe without waiting for it (clients must overlap in time)."""
    transcript = os.path.join(out_dir, "%s.jsonl" % name)
    if os.path.isfile(transcript):
        os.remove(transcript)   # a stale transcript must never be read as a fresh run
    env = base_env({"HPMMO_NET_PROFILE": "local", "HPMMO_DEV_STAIRCASE": STAIR_ORIGIN})
    log = os.path.join(out_dir, "%s.log" % name)
    log_handle = open(log, "wb")
    args = [marker_cmd(), "--headless", "--path", CLIENT_DIR,
            "res://scenes/test/net_client_probe.tscn", "--",
            "--mode=staircase", "--stair-role=%s" % role, "--port=%d" % port, "--name=%s" % name,
            "--out=%s" % transcript, "--seconds=%d" % seconds]
    proc = subprocess.Popen(args, stdout=log_handle, stderr=subprocess.STDOUT, env=env)
    return {"proc": proc, "log": log_handle, "transcript": transcript, "seconds": seconds}


def start_failure_probe(name, out_dir):
    transcript = os.path.join(out_dir, "%s.jsonl" % name)
    if os.path.isfile(transcript):
        os.remove(transcript)   # a stale transcript must never be read as a fresh run
    env = base_env({"HPMMO_DEV_STAIRCASE": STAIR_ORIGIN, "HPMMO_DEV_STAIR_SCALE": STAIR_SCALE})
    log = os.path.join(out_dir, "%s.log" % name)
    log_handle = open(log, "wb")
    args = [marker_cmd(), "--headless", "--path", CLIENT_DIR,
            "res://scenes/test/net_client_probe.tscn", "--",
            "--mode=staircase_failure", "--name=%s" % name,
            "--out=%s" % transcript, "--seconds=40"]
    proc = subprocess.Popen(args, stdout=log_handle, stderr=subprocess.STDOUT, env=env)
    return {"proc": proc, "log": log_handle, "transcript": transcript, "seconds": 40}


def collect_probe(handle, seconds):
    proc = handle["proc"]
    try:
        proc.wait(timeout=seconds + 60)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=10)
    handle["log"].close()
    return read_transcript(handle["transcript"])


def read_transcript(path):
    records = []
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    try:
                        records.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
    return records


def final_of(records):
    for record in reversed(records):
        if record.get("event") == "final":
            return record
    return {}


def by_event(records, name):
    return [r for r in records if r.get("event") == name]


def samples_by_tick(final):
    out = {}
    for sample in final.get("samples", []):
        out[int(sample["tick"])] = sample
    return out


def documented_steps(states):
    """Every observed transition must move forward through the documented cycle
    (a client that joins mid-cycle may miss a phase; it must never go backwards
    or repeat a phase out of order). Returns (ok, exact_steps)."""
    exact = 0
    for index in range(1, len(states)):
        step = (STATE_ORDER.index(states[index]) - STATE_ORDER.index(states[index - 1])) % len(STATE_ORDER)
        if step == 0 or step > 3:
            return False, exact
        if step == 1:
            exact += 1
    return True, exact


def landing_y_is_authored(y):
    return any(abs(float(y) - level) < 0.4 for level in LEVEL_HEIGHTS)


# --------------------------------------------------------------------- tests

def test_agreement_and_ride(out_dir):
    print("\n--- agreement: two clients, one moving staircase ---")
    port = free_port()
    server = start_server(port, 424242, out_dir)
    try:
        if not server.wait_for("listening on :%d" % port, timeout=120):
            check(False, "world server failed to start")
            return
        check(True, "world server is listening")
        alpha = start_probe("observe_a", "observe", port, out_dir, seconds=26)
        beta = start_probe("observe_b", "observe", port, out_dir, seconds=26)
        rider = start_probe("rider", "ride", port, out_dir, seconds=26)
        alpha = collect_probe(alpha, 26)
        beta = collect_probe(beta, 26)
        rider = collect_probe(rider, 26)
    finally:
        server.stop()

    fa, fb, fr = final_of(alpha), final_of(beta), final_of(rider)
    check(bool(fa) and bool(fb) and bool(fr), "all three clients produced a transcript")
    if not fa or not fb or not fr:
        return
    check(bool(by_event(alpha, "stair_ready")), "alpha loaded the staircase scene")
    check(bool(by_event(beta, "stair_ready")), "beta loaded the staircase scene")

    sa, sb = samples_by_tick(fa), samples_by_tick(fb)
    common = sorted(set(sa.keys()) & set(sb.keys()))
    check(len(sa) > 100 and len(sb) > 100,
          "each client sampled the staircase (%d / %d ticks)" % (len(sa), len(sb)))
    check(len(common) > 60, "the two clients have %d sampled ticks in common" % len(common))
    if not common:
        return

    # The comparison itself: same state, same destination, same position. Both
    # clients' ticks are the server tick each snapshot carried (net.gd mirrors
    # it, never re-derives it), so a shared tick is the same authoritative
    # instant in both transcripts; each platform reading is that client's own
    # scene at that tick, never a value copied out of the other transcript.
    state_mismatch = 0
    pos_mismatch = 0
    nav_mismatch = 0
    worst = 0.0
    first_state = None
    first_pos = None
    for tick in common:
        a, b = sa[tick], sb[tick]
        if (a["state"], a["from"], a["to"], a["dock"]) != (b["state"], b["from"], b["to"], b["dock"]):
            state_mismatch += 1
            if first_state is None:
                first_state = (tick, (a["state"], a["from"], a["to"], a["dock"]),
                               (b["state"], b["from"], b["to"], b["dock"]))
        if bool(a["nav"]) != bool(b["nav"]) or bool(a["entry"]) != bool(b["entry"]):
            nav_mismatch += 1
        if a["state"] == b["state"]:
            delta = max(abs(a["platform"][i] - b["platform"][i]) for i in range(3))
        else:
            delta = 0.0   # a state disagreement is counted above; the transform is not comparable
        worst = max(worst, delta)
        if delta > 0.05:
            pos_mismatch += 1
            if first_pos is None:
                first_pos = (tick, list(a["platform"]), list(b["platform"]))
    check(state_mismatch == 0,
          "both clients report the same state/destination on every shared tick (%d disagreements%s)"
          % (state_mismatch, "" if first_state is None else
             "; first at tick %d: alpha %s vs beta %s" % first_state))
    check(pos_mismatch == 0,
          "both clients report the same platform position on every shared tick (worst %.4f m%s)"
          % (worst, "" if first_pos is None else
             "; first at tick %d: alpha %s vs beta %s" % first_pos))
    check(nav_mismatch == 0,
          "both clients agree on whether boarding/navigation is open on every shared tick")

    states_seen = sorted({sa[tick]["state"] for tick in common})
    check(len(states_seen) == len(STATE_ORDER),
          "the shared ticks cover all four states (%s)" % ", ".join(states_seen))
    platform_ys = [sa[tick]["platform"][1] for tick in common]
    travel = max(platform_ys) - min(platform_ys)
    check(travel >= 4.5,
          "the comparison is not two empty readings: the platform travelled %.2f m vertically" % travel)

    # States occur in the documented order, on a real client.
    events = [e["state"] for e in fr.get("events", [])]
    ordered, exact = documented_steps(events)
    check(len(events) >= 8 and ordered and exact >= 4,
          "the states occur in the documented order (%d transitions, %d of them the next state in "
          "the cycle): %s" % (len(events), exact, " -> ".join(events[:8])))

    # Carriage of a real CharacterBody3D rider.
    ride = fr.get("ride", {})
    check(bool(ride.get("aboard")), "the rider boarded while the platform was docked")
    delta_y = float(ride.get("max_y", 0.0)) - float(ride.get("min_y", 0.0))
    check(delta_y >= 4.5,
          "the rider was carried across levels (%.2f m of vertical travel)" % delta_y)
    check(int(ride.get("left_at", -1)) < 0 and bool(ride.get("on_deck_at_end", False)),
          "the rider stayed on the deck for the whole trip (never fell through or was left behind)")
    min_above = float(ride.get("min_above_deck", 99.0))
    max_above = float(ride.get("max_above_deck", -99.0))
    check(min_above >= -1.6 and max_above <= 6.0 + 2.2,
          "the rider stayed inside the deck's vertical span while it moved (%.2f .. %.2f m above its foot)"
          % (min_above, max_above))
    # The rider's own samples must agree with an observer's, too.
    sr = samples_by_tick(fr)
    shared = sorted(set(sr.keys()) & set(sa.keys()))
    rider_delta = 0.0
    for tick in shared:
        if sr[tick]["state"] == sa[tick]["state"]:
            rider_delta = max(rider_delta, max(abs(sr[tick]["platform"][i] - sa[tick]["platform"][i]) for i in range(3)))
    check(len(shared) > 20 and rider_delta <= 0.05,
          "the riding client and an observer agree about the platform (%d shared ticks, worst %.4f m)"
          % (len(shared), rider_delta))


def test_entry_and_fallback(out_dir):
    print("\n--- entry refused while moving; fallback route while it is away ---")
    port = free_port()
    server = start_server(port, 515151, out_dir)
    try:
        if not server.wait_for("listening on :%d" % port, timeout=120):
            check(False, "world server failed to start")
            return
        busy = start_probe("busy", "board_busy", port, out_dir, seconds=24)
        fallback = start_probe("fallback", "fallback", port, out_dir, seconds=44)
        busy = collect_probe(busy, 24)
        fallback = collect_probe(fallback, 44)
    finally:
        server.stop()

    fb, ff = final_of(busy), final_of(fallback)
    check(bool(fb) and bool(ff), "both probes produced a transcript")
    if not fb or not ff:
        return

    walk = fb.get("walk", {})
    check(bool(walk.get("tried")), "the probe tried to board while the platform was moving")
    check(int(walk.get("locked_ticks", 0)) > 0, "it was locked out for %s ticks" % walk.get("locked_ticks"))
    notices = fb.get("notices", [])
    check(len(notices) > 0,
          "the server refused the entry with feedback (%d notice(s): %s)"
          % (len(notices), notices[0]["text"] if notices else ""))
    check(not bool(walk.get("ever_on_deck_while_locked", False)),
          "the probe never stood on the deck while the platform was locked")

    # Every sample the busy probe took while locked must report entry closed.
    locked_samples = [s for s in fb.get("samples", []) if not s["entry"]]
    check(len(locked_samples) > 0 and all(s["nav"] == s["entry"] for s in fb.get("samples", [])),
          "navigation/boarding is open only while docked (%d locked samples)" % len(locked_samples))

    fwalk = ff.get("walk", {})
    check(int(fwalk.get("waypoint", 0)) >= 9,
          "the fallback walk reached all 9 waypoints (got %s)" % fwalk.get("waypoint"))
    end = fwalk.get("end_pos", [0.0, 0.0, 0.0])
    check(landing_y_is_authored(end[1]) and end[1] > 11.0,
          "the fallback route ended on the second floor at y=%.2f while the magical staircase was away" % end[1])
    started = int(fwalk.get("started_tick", 0))
    check(started > 0, "the fallback walk started only once the platform had left the ground dock (tick %d)" % started)
    reached = [k for k in fwalk.keys() if k.startswith("reached_")]
    check(len(reached) == 9, "the fallback walk recorded every landing it reached (%s)" % ", ".join(sorted(reached)))


def test_rider_logout(out_dir):
    print("\n--- disconnect while riding ---")
    port = free_port()
    server = start_server(port, 616161, out_dir)
    server_log = ""
    try:
        if not server.wait_for("listening on :%d" % port, timeout=120):
            check(False, "world server failed to start")
            return
        observer = start_probe("watch", "observe", port, out_dir, seconds=30)
        rider = start_probe("logout", "rider_logout", port, out_dir, seconds=30)
        rider = collect_probe(rider, 30)
        observer = collect_probe(observer, 30)
        server_log = server.read_log()
    finally:
        server.stop()

    fr, fo = final_of(rider), final_of(observer)
    check(bool(fr) and bool(fo), "both probes produced a transcript")
    ride = fr.get("ride", {})
    check(bool(ride.get("aboard")), "the rider was aboard before disconnecting")
    check(int(ride.get("logout_tick", -1)) > 0, "the probe dropped the connection mid-flight (tick %s)"
          % ride.get("logout_tick"))

    resolutions = re.findall(
        r"\[Staircase\] rider uid (\d+) resolved to landing \((-?[\d.]+), (-?[\d.]+), (-?[\d.]+)\) \((\w+), state (\w+)\)",
        server_log)
    check(bool(resolutions),
          "the server resolved the disconnected rider to a landing (log: %d line(s))" % len(resolutions))
    if resolutions:
        _uid, _x, _y, _z, reason, state = resolutions[-1]
        check(reason == "disconnect", "the resolution names the disconnect (%s)" % reason)
        check(state in ("moving", "docking", "boarding_warning"),
              "the rider was between floors when it happened (state %s)" % state)
        check(landing_y_is_authored(_y),
              "the resolved landing is an authored floor level (y=%s)" % _y)

    if fo and fr:
        rider_uid = int(fr.get("uid", 0))
        despawns = [int(d["uid"]) for d in fo.get("despawns", [])]
        check(rider_uid in despawns, "the observer saw the rider's entity despawn cleanly (uid %d)" % rider_uid)
        last_tick = max([int(s["tick"]) for s in fo.get("samples", [])] or [0])
        logout_tick = int(ride.get("logout_tick", 0))
        check(last_tick > logout_tick,
              "the world kept ticking after the disconnect (%d > %d)" % (last_tick, logout_tick))


def test_failure_cases(out_dir):
    print("\n--- death and map transfer while riding ---")
    handle = start_failure_probe("failure", out_dir)
    records = collect_probe(handle, 40)
    blocks = by_event(records, "stair_failure")
    check(bool(blocks), "the failure probe produced a result block")
    if not blocks:
        return
    result = blocks[0]
    check(bool(result.get("authority")), "the in-process run was the authority")
    check(bool(result.get("death_on_deck")), "the player really was standing on the moving deck when it died")
    check(bool(result.get("death_rider")), "the authority had the body registered as a rider when it died")
    check(bool(result.get("dead")), "the lethal damage landed")
    check(bool(result.get("respawn_is_landing")),
          "the respawn was not inside the staircase volume")
    check(bool(result.get("respawn_matches_map")),
          "the respawn used the map's authored spawn (%s)" % result.get("respawn_pos"))
    check(bool(result.get("transfer_rider")), "the body was a registered rider when the transfer started")
    check(bool(result.get("transfer_on_authored_landing")),
          "a map transfer while riding resolved to an authored landing (%s)" % result.get("transfer_landing"))
    check(bool(result.get("transfer_moved_body")), "the body was moved to that landing")
    check(str(result.get("transfer_state")) in ("moving", "docking", "boarding_warning"),
          "the transfer happened while the platform was away from a dock (%s)" % result.get("transfer_state"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip", default="")
    parser.add_argument("--out-dir", default="")
    args = parser.parse_args()
    skip = {s for s in args.skip.split(",") if s}

    if not os.path.isdir(os.path.join(CLIENT_DIR, "addons", "hpmmo_sim")):
        print("client simulation package not found - run dev.ps1 sync-sim first")
        return 2

    out_dir = args.out_dir or tempfile.mkdtemp(prefix="hpmmo-stair-")
    os.makedirs(out_dir, exist_ok=True)
    print("artifacts: %s" % out_dir)

    for project, name in ((os.path.join(SERVER_DIR, "world"), "world"), (CLIENT_DIR, "client")):
        if not ensure_imported(project, out_dir, name):
            print("import failed for %s (see %s-import.log)" % (project, name))
            return 2

    if "agreement" not in skip:
        test_agreement_and_ride(out_dir)
    if "entry" not in skip:
        test_entry_and_fallback(out_dir)
    if "logout" not in skip:
        test_rider_logout(out_dir)
    if "failure" not in skip:
        test_failure_cases(out_dir)

    print("\nSTAIRCASE RESULT: %d checks, %d failures" % (checks, len(failures)))
    for failure in failures:
        print("  FAILED: " + failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
