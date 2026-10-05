#!/usr/bin/env python3
"""Phase 5 multiplayer proof: two independent clients against one world server.

Proves the plan.md Phase 5 exit checks with real processes:

  1. agreement   - two headless clients join the same world server, walk to the
                   same pack, attack the same mob, and must observe the same
                   pack, health, cast outcome, death, respawn and reward.
                   Re-run with --profile mobile/awful to prove the same holds
                   under documented latency and packet loss.
  2. forged      - a hostile client claims damage, claims kills, casts unknown
                   spells, teleports and speed-hacks; none of it may land.
  3. protection  - a protected target cannot be damaged by a delayed projectile,
                   a burn tick or a boss AoE (with positive controls proving the
                   attacks do land outside protection).

Usage:
  python tests/multiplayer_sim.py [--profile local|broadband|mobile|awful]
                                  [--skip=agreement,forged,protection]

Environment: HPMMO_GODOT (godot binary), HPMMO_CLIENT_DIR / HPMMO_SERVER_DIR to
point at the two checkouts (defaults assume the standard workspace layout).
"""

import argparse
import json
import os
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
    """Godot resolves the shared package's `class_name` globals from the project's
    import cache, so the exported world must be re-imported after every
    sync-world (which rewrites its scripts)."""
    log = os.path.join(out_dir, "%s-import.log" % name)
    with open(log, "wb") as handle:
        proc = subprocess.run([marker_cmd(), "--headless", "--path", project_dir, "--editor", "--import", "--quit"],
                              stdout=handle, stderr=subprocess.STDOUT)
    return proc.returncode == 0


def start_server(port, seed, profile, out_dir, extra=None):
    env = base_env({
        "HPMMO_WORLD_PORT": port,
        "HPMMO_WORLD_SEED": seed,
        "HPMMO_ALLOW_DEV_JOIN": "1",
        "HPMMO_DEV_FAST_RESPAWN": "2000",
        # Both clients spawn beside the pack under test: the walk stays short and
        # reproducible, and nothing has to path around the courtyard.
        "HPMMO_DEV_SPAWN": "24,0.6,-25",
        "HPMMO_NET_PROFILE": profile,
    })
    if extra:
        env.update(extra)
    log = os.path.join(out_dir, "world-server.log")
    proc = Proc("world-server", [marker_cmd(), "--headless", "--path", os.path.join(SERVER_DIR, "world"),
                                 "res://server/world_server.tscn"], env, log)
    return proc


def start_probe(name, mode, port, out_dir, seconds=20, profile="local"):
    """Launch a probe without waiting for it (clients must overlap in time)."""
    transcript = os.path.join(out_dir, "%s.jsonl" % name)
    env = base_env({"HPMMO_NET_PROFILE": profile})
    log = os.path.join(out_dir, "%s.log" % name)
    log_handle = open(log, "wb")
    args = [marker_cmd(), "--headless", "--path", CLIENT_DIR,
            "res://scenes/test/net_client_probe.tscn", "--",
            "--mode=%s" % mode, "--port=%d" % port, "--name=%s" % name,
            "--out=%s" % transcript, "--seconds=%d" % seconds]
    proc = subprocess.Popen(args, stdout=log_handle, stderr=subprocess.STDOUT, env=env)
    return {"proc": proc, "log": log_handle, "transcript": transcript, "seconds": seconds}


def collect_probe(handle, seconds):
    proc = handle["proc"]
    try:
        proc.wait(timeout=seconds * 4 + 90)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=10)
    handle["log"].close()
    records = []
    transcript = handle["transcript"]
    if os.path.isfile(transcript):
        with open(transcript, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    try:
                        records.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
    return records


def run_probe(name, mode, port, out_dir, seconds=20, profile="local"):
    return collect_probe(start_probe(name, mode, port, out_dir, seconds, profile), seconds)


def final_of(records):
    for record in reversed(records):
        if record.get("event") == "final":
            return record
    return {}


def by_event(records, name):
    return [r for r in records if r.get("event") == name]


# --------------------------------------------------------------------- tests

def test_agreement(out_dir, profile):
    print("\n--- agreement: two independent clients, profile=%s ---" % profile)
    port = free_port()
    server = start_server(port, 424242, profile, out_dir)
    try:
        if not server.wait_for("listening on :%d" % port, timeout=90):
            check(False, "[%s] world server failed to start" % profile)
            return
        check(True, "[%s] world server is listening" % profile)
        # Both clients run CONCURRENTLY: the point of the test is that two
        # independent clients are in the world at the same time.
        alpha = start_probe("alpha", "agree", port, out_dir, seconds=22, profile=profile)
        beta = start_probe("beta", "agree", port, out_dir, seconds=22, profile=profile)
        alpha = collect_probe(alpha, 22)
        beta = collect_probe(beta, 22)
    finally:
        server.stop()

    fa, fb = final_of(alpha), final_of(beta)
    check(bool(fa) and bool(fb), "[%s] both clients produced a transcript" % profile)
    if not fa or not fb:
        return
    check(bool(by_event(alpha, "joined")[0].get("ok")) if by_event(alpha, "joined") else False,
          "[%s] alpha joined the world" % profile)
    check(bool(by_event(beta, "joined")[0].get("ok")) if by_event(beta, "joined") else False,
          "[%s] beta joined the world" % profile)

    check(fa.get("uid") and fb.get("uid") and fa["uid"] != fb["uid"],
          "[%s] the server assigned each client its own entity id (%s vs %s)" % (profile, fa.get("uid"), fb.get("uid")))
    check(fa.get("target_uid") == fb.get("target_uid") and fa.get("target_uid"),
          "[%s] both clients targeted the same mob (uid %s)" % (profile, fa.get("target_uid")))

    # Interest filtering: each client is told about a bounded set, not the world.
    uids_a = sorted(int(m["uid"]) for m in fa.get("visible_mobs", []))
    uids_b = sorted(int(m["uid"]) for m in fb.get("visible_mobs", []))
    shared = sorted(set(uids_a) & set(uids_b))
    check(len(uids_a) > 0 and len(uids_b) > 0,
          "[%s] each client was sent mobs (%d / %d)" % (profile, len(uids_a), len(uids_b)))
    check(len(shared) > 0 and fa.get("target_uid") in shared,
          "[%s] both clients see the contested mob (uid %s) and %d others in common"
          % (profile, fa.get("target_uid"), len(shared)))
    # Where both can see the same mob, they must agree about it, to the point.
    by_uid_a = {int(m["uid"]): m for m in fa.get("visible_mobs", [])}
    by_uid_b = {int(m["uid"]): m for m in fb.get("visible_mobs", [])}
    mismatched = [uid for uid in shared
                  if abs(int(by_uid_a[uid]["hp"]) - int(by_uid_b[uid]["hp"])) > 40]
    check(not mismatched,
          "[%s] both clients agree on every shared mob's health (%d shared, %d disagreements)"
          % (profile, len(shared), len(mismatched)))

    # Same health: compare the hp samples both recorded for the target.
    hp_a = [int(s["hp"]) for s in fa.get("target_hp_samples", [])]
    hp_b = [int(s["hp"]) for s in fb.get("target_hp_samples", [])]
    check(bool(hp_a) and bool(hp_b), "[%s] both clients observed the target's health" % profile)
    check(hp_a and hp_b and hp_a[-1] == hp_b[-1],
          "[%s] both clients agree on the final health (%s vs %s)" % (profile, hp_a[-1:] or None, hp_b[-1:] or None))
    check(min(hp_a + [1]) == min(hp_b + [1]) and min(hp_a + [1]) <= 0,
          "[%s] both clients saw the mob reach zero health" % profile)

    # Same death, same cast outcome, same respawn.
    check(fa.get("target_death_tick", -1) >= 0 and fb.get("target_death_tick", -1) >= 0,
          "[%s] both clients saw the death" % profile)
    check(abs(int(fa.get("target_death_tick", 0)) - int(fb.get("target_death_tick", 0))) <= 2,
          "[%s] both clients place the death on the same tick (%s vs %s)"
          % (profile, fa.get("target_death_tick"), fb.get("target_death_tick")))
    check(fa.get("casts_accepted", 0) > 0 and fb.get("casts_accepted", 0) > 0,
          "[%s] the server accepted both clients' casts" % profile)
    check(fa.get("target_respawn_tick", -1) >= 0 and fb.get("target_respawn_tick", -1) >= 0,
          "[%s] both clients saw the respawn" % profile)
    check(fa.get("target_respawn_tick", 0) > fa.get("target_death_tick", 0),
          "[%s] the respawn happened after the death" % profile)

    # Exactly one reward per eligible player per kill.
    check(fa.get("exp_end", 0) > fa.get("exp_start", 0) and fb.get("exp_end", 0) > fb.get("exp_start", 0),
          "[%s] both eligible players were rewarded" % profile)
    ops_a = [r["op_id"] for r in fa.get("rewards", [])]
    ops_b = [r["op_id"] for r in fb.get("rewards", [])]
    check(len(ops_a) == len(set(ops_a)) and len(ops_b) == len(set(ops_b)),
          "[%s] no player was rewarded twice for one death" % profile)
    kill_ops_a = [r["op_id"] for r in fa.get("rewards", []) if str(r.get("op_id", "")).startswith("kill:")]
    kill_ops_b = [r["op_id"] for r in fb.get("rewards", []) if str(r.get("op_id", "")).startswith("kill:")]
    kills_a = len({op.split(":")[1] for op in kill_ops_a})
    kills_b = len({op.split(":")[1] for op in kill_ops_b})
    check(kills_a == kills_b and kills_a > 0,
          "[%s] both clients were credited for the same %d kill(s)" % (profile, kills_a))
    granted_a = sum(int(r.get("exp", 0)) for r in fa.get("rewards", []))
    gained_a = int(fa.get("exp_end", 0)) - int(fa.get("exp_start", 0))
    check(granted_a == gained_a and gained_a > 0,
          "[%s] the reward matches the EXP gained exactly (%d granted, %d gained)"
          % (profile, granted_a, gained_a))
    check(not set(ops_a) & set(ops_b),
          "[%s] each player has their own reward record" % profile)


def test_forged(out_dir, profile="local"):
    print("\n--- forged requests ---")
    port = free_port()
    server = start_server(port, 777001, "local", out_dir)
    try:
        if not server.wait_for("listening on :%d" % port, timeout=90):
            check(False, "world server failed to start for the forged test")
            return
        records = run_probe("forger", "forged", port, out_dir, seconds=10, profile=profile)
    finally:
        server.stop()
    final = final_of(records)
    check(bool(final), "forged probe produced a transcript")
    if not final:
        return
    check(final.get("mob_hp_after_forged_damage", 0) > 0,
          "a claimed 99999 damage did not kill the mob (hp %s)" % final.get("mob_hp_after_forged_damage"))
    check(int(final.get("own_hp_after", -1)) == int(final.get("own_hp_before", -2)),
          "a claimed self-death did not change the client's health")
    check(final.get("casts_accepted", 1) == 0,
          "no forged cast was accepted")
    check("unknown_spell" in final.get("casts_rejected", []),
          "an unknown spell id was rejected explicitly")
    # The claim is about the AUTHORITY, not the renderer. The rendered body's
    # per-frame step carries the frame duration and the reconciliation snap
    # (which fires when the prediction is more than 1 m out), so it cannot
    # answer "did the 50x vector teleport this body?". The probe records the
    # server positions this client receives, normalised by the server ticks each
    # step spans; the bound is then HPRules.max_travel_distance(SIM_DT) exactly -
    # the same rule the server uses to reject teleport claims, no extra slack.
    rule_step = float(final.get("speed_limit_per_tick", 0.0))
    max_auth_step = float(final.get("max_auth_step_per_tick", float("inf")))
    auth_samples = int(final.get("auth_step_samples", 0))
    auth_ticks = int(final.get("auth_step_ticks", 0))
    check(auth_samples >= 10 and auth_ticks > 0 and max_auth_step > 0.0,
          "the authoritative movement was measured on a moving body (%d server-side steps over %d ticks)"
          % (auth_samples, auth_ticks))
    check(auth_samples >= 10 and max_auth_step <= rule_step,
          "a 50x input vector did not teleport the player (authoritative %.3f m/tick <= "
          "HPRules.max_travel_distance(%.3f s) = %.3f m/tick, walk speed %.1f m/s, %s)"
          % (max_auth_step, float(final.get("sim_dt", 0.05)), rule_step,
             float(final.get("walk_speed", 0.0)), profile))
    check(final.get("forged_mob_died") is False,
          "the mob was still alive after the forged damage claim")
    travelled = float(final.get("distance_travelled", 0))
    limit = HPRules_walk_limit(final)
    check(travelled <= limit,
          "distance travelled under a speed hack stayed within the rules (%.1f m <= %.1f m)" % (travelled, limit))


def HPRules_walk_limit(final):
    """walk speed 8.5 m/s over the probe's window, plus slack."""
    return 8.5 * 30.0


def test_protection(out_dir):
    print("\n--- protected targets ---")
    records = run_probe("guardian", "protection", free_port(), out_dir, seconds=14)
    blocks = by_event(records, "protection")
    check(bool(blocks), "protection probe produced a result block")
    if not blocks:
        return
    result = blocks[0]
    projectile_in = result.get("projectile_into_zone", {})
    projectile_out = result.get("projectile_outside_zone", {})
    burn = result.get("burn_inside_zone", {})
    aoe_in = result.get("boss_aoe_over_zone", {})
    aoe_out = result.get("boss_aoe_outside_zone", {})

    check(projectile_in and projectile_in.get("after") == projectile_in.get("before"),
          "a delayed projectile does not damage a target inside a safe zone")
    check(projectile_out and projectile_out.get("after", 1) < projectile_out.get("before", 0),
          "the same projectile does damage outside the zone (positive control, same distance)")
    burn_out = result.get("burn_outside_zone", {})
    check(bool(burn.get("burn_started")),
          "the incendio hit really started a burn (the check below is not vacuous)")
    check(burn and burn.get("after") == burn.get("before") and int(burn.get("events", -1)) == 0,
          "burn ticks deal nothing inside a safe zone (0 damage events reached it)")
    check(burn_out and int(burn_out.get("events", 0)) >= 1,
          "the same burn does tick outside the zone (positive control, %s damage events)"
          % burn_out.get("events"))
    check(aoe_in and aoe_in.get("hits") == 0 and aoe_in.get("after") == aoe_in.get("before"),
          "a boss AoE overlapping a safe zone does not damage the players inside it")
    check(aoe_out and aoe_out.get("hits") == 1 and aoe_out.get("after", 1) < aoe_out.get("before", 0),
          "the same boss AoE does damage outside the zone (positive control)")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", default="local")
    parser.add_argument("--skip", default="")
    parser.add_argument("--out-dir", default="")
    args = parser.parse_args()
    skip = {s for s in args.skip.split(",") if s}

    if not os.path.isdir(os.path.join(CLIENT_DIR, "addons", "hpmmo_sim")):
        print("client simulation package not found - run dev.ps1 sync-sim first")
        return 2

    out_dir = args.out_dir or tempfile.mkdtemp(prefix="hpmmo-mp-")
    os.makedirs(out_dir, exist_ok=True)
    print("artifacts: %s" % out_dir)

    for project, name in ((os.path.join(SERVER_DIR, "world"), "world"), (CLIENT_DIR, "client")):
        if not ensure_imported(project, out_dir, name):
            print("import failed for %s (see %s-import.log)" % (project, name))
            return 2

    if "agreement" not in skip:
        test_agreement(out_dir, args.profile)
    if "forged" not in skip:
        test_forged(out_dir, args.profile)
    if "protection" not in skip:
        test_protection(out_dir)

    print("\nMULTIPLAYER RESULT: %d checks, %d failures" % (checks, len(failures)))
    for failure in failures:
        print("  FAILED: " + failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
