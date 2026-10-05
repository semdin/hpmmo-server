#!/usr/bin/env python3
"""Phase 8 map-state and map-transfer proof (plan.md Phase 8).

Starts world servers and real headless clients - the same probe the Phase 5
suite uses, in its `transfer` mode - and asserts:

  1. cross-map invisibility in BOTH directions, with same-map visibility as the
     positive control, and a client-side teleport claim across maps corrected by
     the authority (forged transfer messages are refused);
  2. the full transfer exchange with the client ending on the new map
     (request -> validate -> reserve -> pending -> load -> ready -> ownership ->
     spawn from a server-approved location);
  3. a transfer interrupted by the client dying mid-flight leaves a valid,
     persisted location and the relog produces no duplicate character;
  4. two players transferring in opposite directions both end up correct;
  5. repeated transfers do not grow the server's entity registry;
  6. a mounted rider is refused entry into the flight-prohibited interior;
  7. an unacknowledged reservation expires (bounded): the body returns to its
     last valid safe spawn, input works again, and the door can be used again;
  8. a full destination refuses the transfer;
  9. authority-level refusals and the map-scoped interest filter, in process:
     dead, mounted, out of range, pending, bad token, unknown portal and
     unknown destination.

The persistence path is exercised through a stub service that speaks the same
request/response shapes as the Phase 4 service (integration_api.py covers the
real PostgreSQL build; this suite is about the world server's half of the
contract).

Usage: python tests/maps_sim.py [--out-dir DIR]

Environment: HPMMO_GODOT (godot binary), HPMMO_CLIENT_DIR / HPMMO_SERVER_DIR
to point at the two checkouts (defaults assume the standard workspace layout).
"""

import argparse
import http.server
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER_DIR = os.environ.get("HPMMO_SERVER_DIR", os.path.dirname(HERE))
WORKSPACE = os.path.dirname(SERVER_DIR)
CLIENT_DIR = os.environ.get("HPMMO_CLIENT_DIR", os.path.join(WORKSPACE, "client"))
GODOT = os.environ.get("HPMMO_GODOT", "godot")
CATALOG = os.path.join(SERVER_DIR, "world", "addons", "hpmmo_sim", "data", "maps.json")

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


def catalog():
    with open(CATALOG, encoding="utf-8") as handle:
        return json.load(handle)


MAPS = catalog()


def spawn_point(map_id, spawn_id):
    points = MAPS["maps"][map_id]["spawn_points"]
    return points.get(spawn_id, points["default"])


def near(a, b, tolerance=1.0):
    return all(abs(float(a[i]) - float(b[i])) <= tolerance for i in range(3))


# ------------------------------------------------------------------ stub service

class StubService:
    """A contract-faithful stand-in for the Phase 4 persistence service.

    Implements the four endpoints the world server's bridge calls
    (session/introspect, characters/load, characters/save, reward) with the
    same JSON shapes, and records every save so a test can assert what the
    server persisted at disconnect time.
    """

    def __init__(self):
        self.token = "maps-sim-service-token"
        self.lock = threading.Lock()
        self.characters = {}
        self.tokens = {}
        self.revisions = {}
        self.saves = []
        self.httpd = None
        self.thread = None

    def add_character(self, token, character):
        with self.lock:
            cid = int(character["id"])
            character.setdefault("revision", 1)
            # The real service returns the owning account on every character
            # sheet (Phase 14 D14-1): the world server proves a bind belongs to
            # the session's account by comparing it, so the stub must carry it.
            character.setdefault("account_id", 1)
            self.characters[cid] = character
            self.tokens[token] = cid
            self.revisions[cid] = int(character["revision"])

    def saved(self, character_id, since=0):
        with self.lock:
            return [s for s in self.saves[since:] if int(s.get("character_id", 0)) == character_id]

    def start(self):
        service = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _json(self, code, payload):
                body = json.dumps(payload).encode("utf-8")
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                if self.headers.get("X-Service-Token") != service.token:
                    return self._json(403, {"success": False, "message": "forbidden"})
                length = int(self.headers.get("Content-Length", 0))
                try:
                    body = json.loads(self.rfile.read(length) or b"{}")
                except json.JSONDecodeError:
                    return self._json(400, {"success": False, "message": "bad json"})
                route = self.path
                with service.lock:
                    if route == "/api/session/introspect":
                        cid = service.tokens.get(str(body.get("token", "")))
                        if cid is None:
                            return self._json(404, {"success": False, "message": "Session not found."})
                        name = str(body.get("token", ""))
                        return self._json(200, {"success": True, "account_id": 1, "username": name,
                                                "character_id": cid, "expires_in_seconds": 3600})
                    if route == "/api/characters/load":
                        character = service.characters.get(int(body.get("character_id", 0)))
                        if character is None:
                            return self._json(404, {"success": False, "message": "Character not found."})
                        payload = dict(character)
                        payload["revision"] = service.revisions.get(int(character["id"]), 1)
                        return self._json(200, {"success": True, "character": payload})
                    if route == "/api/characters/save":
                        cid = int(body.get("character_id", 0))
                        character = service.characters.get(cid)
                        if character is None:
                            return self._json(404, {"success": False, "message": "Character not found."})
                        current = service.revisions.get(cid, 1)
                        base = body.get("base_revision")
                        if base is not None and int(base) >= 0 and int(base) != current:
                            return self._json(409, {"success": False, "message": "Stale revision.",
                                                    "revision": current})
                        service.saves.append(dict(body))
                        for key in ("map_id", "pos", "rot_y", "level", "exp", "current_hp", "max_hp",
                                    "current_mana", "max_mana", "galleons", "wand_tier"):
                            if key in body:
                                character[key] = body[key]
                        service.revisions[cid] = current + 1
                        return self._json(200, {"success": True, "revision": current + 1})
                    if route == "/api/reward":
                        return self._json(200, {"success": True, "replayed": False})
                return self._json(404, {"error": "Endpoint not found"})

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.httpd.service = self
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()
        return self

    def stop(self):
        if self.httpd is not None:
            self.httpd.shutdown()
            self.httpd.server_close()
            self.httpd = None


def seeded_character(cid, token, pos, map_id):
    return {
        "id": cid,
        "name": token,
        "house": "Gryffindor",
        "level": 5,
        "exp": 400,
        "max_hp": 600,
        "current_hp": 600,
        "max_mana": 400,
        "current_mana": 400,
        "galleons": 500,
        "wand_tier": 1,
        "revision": 1,
        "pos": list(pos),
        "rot_y": 0.0,
        "map_id": map_id,
        "inventory": [],
    }


# ------------------------------------------------------------------- processes

class Proc:
    def __init__(self, args, env, log_path):
        self.log_path = log_path
        self.log = open(log_path, "wb")
        self.proc = subprocess.Popen(args, stdout=self.log, stderr=subprocess.STDOUT, env=env)

    def wait_for(self, needle, timeout=90.0):
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
    log = os.path.join(out_dir, "%s-import.log" % name)
    with open(log, "wb") as handle:
        proc = subprocess.run([marker_cmd(), "--headless", "--path", project_dir, "--editor", "--import", "--quit"],
                              stdout=handle, stderr=subprocess.STDOUT)
    return proc.returncode == 0


def start_server(port, seed, out_dir, extra=None):
    env = base_env({
        "HPMMO_WORLD_PORT": port,
        "HPMMO_WORLD_SEED": seed,
        "HPMMO_NET_PROFILE": "local",
        "HPMMO_ADMIN_PORT": free_port(),
    })
    if extra:
        env.update({k: str(v) for k, v in extra.items()})
    log = os.path.join(out_dir, "world-server-%d.log" % port)
    return Proc([marker_cmd(), "--headless", "--path", os.path.join(SERVER_DIR, "world"),
                 "res://server/world_server.tscn"], env, log)


def start_probe(name, port, out_dir, scenario, seconds, extra_args=None, env_extra=None, label=None):
    """`name` is also the join token (the stub resolves it); `label` only names
    the artifacts, so a relog with the same token gets its own transcript."""
    label = label or name
    transcript = os.path.join(out_dir, "%s.jsonl" % label)
    env = base_env({"HPMMO_NET_PROFILE": "local"})
    if env_extra:
        env.update(env_extra)
    log = os.path.join(out_dir, "%s.log" % label)
    log_handle = open(log, "wb")
    args = [marker_cmd(), "--headless", "--path", CLIENT_DIR,
            "res://scenes/test/net_client_probe.tscn", "--",
            "--mode=transfer", "--scenario=%s" % scenario, "--port=%d" % port,
            "--name=%s" % name, "--out=%s" % transcript, "--seconds=%d" % seconds]
    args.extend(extra_args or [])
    proc = subprocess.Popen(args, stdout=log_handle, stderr=subprocess.STDOUT, env=env)
    return {"proc": proc, "log": log_handle, "transcript": transcript, "name": name}


def collect_probe(handle, seconds):
    proc = handle["proc"]
    try:
        proc.wait(timeout=seconds * 3 + 60)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=10)
    handle["log"].close()
    records = []
    if os.path.isfile(handle["transcript"]):
        with open(handle["transcript"], encoding="utf-8") as handle_file:
            for line in handle_file:
                line = line.strip()
                if line:
                    try:
                        records.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
    return records


def run_probe(name, port, out_dir, scenario, seconds, extra_args=None, env_extra=None, label=None):
    return collect_probe(start_probe(name, port, out_dir, scenario, seconds, extra_args, env_extra, label), seconds)


def final_of(records):
    for record in reversed(records):
        if record.get("event") == "final":
            return record
    return {}


def by_event(records, name):
    return [r for r in records if r.get("event") == name]


def transfer_events(final):
    return final.get("transfer_events", [])


def event_names(final):
    return [str(e.get("event", "")) for e in transfer_events(final)]


ROSTER_RE = re.compile(r"roster\((\w+)\): players=(\d+) entities=(\d+) \| (.*)")
STATUS_RE = re.compile(r"tick=(\d+) state=(\S*) entities=(\d+) players=(\d+) inputs=(\d+) casts=(\d+) \| (.*)")


def log_lines(path, timeout=0.0):
    deadline = time.time() + timeout
    while True:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                return handle.read().splitlines()
        except OSError:
            if time.time() >= deadline:
                return []
        time.sleep(0.2)


def rosters(path):
    out = []
    for line in log_lines(path):
        match = ROSTER_RE.search(line)
        if match:
            out.append({"event": match.group(1), "players": int(match.group(2)),
                        "entities": int(match.group(3)), "tail": match.group(4)})
    return out


def statuses(path, uid=None):
    out = []
    for line in log_lines(path):
        match = STATUS_RE.search(line)
        if not match:
            continue
        entry = {"tick": int(match.group(1)), "entities": int(match.group(3)),
                 "players": int(match.group(4)), "tail": match.group(7)}
        if uid is None or ("uid %d " % uid) in entry["tail"]:
            out.append(entry)
    return out


def wait_for_roster(path, predicate, timeout=20.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        lines = rosters(path)
        if lines and predicate(lines):
            return lines
        time.sleep(0.3)
    return rosters(path)


def named(name, out_dir, port, scenario, seconds, extra=None, env_extra=None, label=None, attempts=2):
    """Run one probe and hand back (records, final). A probe that produced no
    transcript at all is retried once: the shared probe script is edited by
    other workstreams, and a file caught mid-write makes the process start
    without its script."""
    label = label or name
    final = {}
    records = []
    for attempt in range(attempts):
        print("  - probe %-12s scenario=%-9s %ss%s" % (label, scenario, seconds,
              " (retry)" if attempt else ""))
        records = run_probe(name, port, out_dir, scenario, seconds, extra, env_extra, label)
        final = final_of(records)
        if final:
            break
    check(bool(final), "%s produced a transcript" % label)
    return records, final


def ordered(final, first, second):
    names = event_names(final)
    return first in names and second in names and names.index(first) < names.index(second)


# --------------------------------------------------------------------- tests

def visibility_of(records):
    blocks = by_event(records, "visibility")
    return blocks[-1] if blocks else {}


def test_cross_map(out_dir, port, server, stub):
    print("\n--- cross-map invisibility and the teleport claim ---")
    gwen_records, gale_records, ines_records = [], [], []
    for attempt in range(2):
        gwen_handle = start_probe("gwen", port, out_dir, "teleport", 12, ["--teleport-at=4"])
        gale_handle = start_probe("gale", port, out_dir, "observer", 9)
        ines_handle = start_probe("ines", port, out_dir, "observer", 9)
        gwen_records = collect_probe(gwen_handle, 12)
        gale_records = collect_probe(gale_handle, 9)
        ines_records = collect_probe(ines_handle, 9)
        if final_of(gwen_records) and final_of(gale_records) and final_of(ines_records):
            break
        print("    a viewer produced no transcript; retrying once")
    gwen, gale, ines = final_of(gwen_records), final_of(gale_records), final_of(ines_records)
    check(bool(gwen) and bool(gale) and bool(ines), "all three viewers produced a transcript")
    if not (gwen and gale and ines):
        return
    check(gwen.get("map_id") == "grounds", "the grounds viewer starts on grounds (%s)" % gwen.get("map_id"))
    check(ines.get("map_id") == "castle_interior",
          "the interior viewer is on castle_interior (%s)" % ines.get("map_id"))
    gwen_uid, gale_uid, ines_uid = gwen.get("uid"), gale.get("uid"), ines.get("uid")
    check(gwen_uid and gale_uid and ines_uid and len({gwen_uid, gale_uid, ines_uid}) == 3,
          "each client has its own entity id")
    # Both viewers are alive at the same instant, so a mid-flight snapshot is the
    # fair comparison. Positive control: the two grounds players see each other.
    seen = {"gwen": visibility_of(gwen_records), "gale": visibility_of(gale_records),
            "ines": visibility_of(ines_records)}
    check(bool(seen["gwen"]) and bool(seen["gale"]) and bool(seen["ines"]),
          "all three clients recorded a visibility snapshot")
    check(gale_uid in seen["gwen"].get("players", []),
          "two players on the same map see each other (positive control)")
    check(gwen_uid in seen["gale"].get("players", []),
          "same-map visibility holds in both directions")
    # The map filter, both directions.
    check(ines_uid not in seen["gwen"].get("uids", []) and gwen_uid not in seen["ines"].get("uids", []),
          "neither map's client is sent the other map's player")
    check(gale_uid not in seen["ines"].get("uids", []),
          "the interior client is sent nothing from the grounds")
    check(int(ines.get("replica_count", 0)) == 1,
          "the interior client's whole replica set is its own body (%s)" % ines.get("replica_count"))
    check(int(gwen.get("replica_count", 0)) > 1,
          "the grounds client was sent the outdoor entities (%s replicas)" % gwen.get("replica_count"))
    # A client-side teleport claim across maps is corrected, not obeyed.
    claims = by_event(gwen_records, "teleport_claim")
    after = by_event(gwen_records, "teleport_after")
    check(bool(claims), "the teleport claim was attempted")
    check(bool(claims) and claims[0].get("map") == "grounds",
          "the claim happened while the body belonged to the grounds")
    auth = gwen.get("auth_samples", [])
    check(bool(auth) and all(float(sample[1]) < 185.0 for sample in auth),
          "the authoritative position never left the grounds (%d samples)" % len(auth))
    check(gwen.get("commit_map", "") == "" and gwen.get("map_id") == "grounds",
          "the teleport claim did not change the client's map")
    check(bool(after) and float(after[0].get("error", 99)) < 3.0,
          "the local body was reconciled back to the authoritative position (%.2f m)"
          % float(after[0].get("error", -1) if after else -1))
    # Forged protocol messages were refused.
    refused = [e.get("reason") for e in transfer_events(gwen) if e.get("event") == "refused"]
    check("bad_transfer_token" in refused, "an acknowledgement for a reservation this client never got is refused")
    check("no_portal" in refused, "a door that does not exist is refused")
    return gwen


def test_happy(out_dir, port, server, stub):
    print("\n--- happy path: grounds -> castle_interior ---")
    records, final = named("hank", out_dir, port, "happy", 12)
    if not final:
        return
    check(final.get("map_id") == "castle_interior",
          "the client ends on the new map (%s)" % final.get("map_id"))
    check(final.get("granted_map") == "castle_interior" and final.get("granted_spawn") == "vestibule",
          "the grant named the catalog destination and spawn")
    check(final.get("commit_map") == "castle_interior", "the commit moved entity ownership")
    expected = spawn_point("castle_interior", "vestibule")
    check(near(final.get("commit_pos", [999, 999, 999]), expected, 0.01),
          "the commit spawned at the server-approved location %s (got %s)"
          % (expected, final.get("commit_pos")))
    check(ordered(final, "granted", "committed"),
          "the grant precedes the commit (request -> load -> ready -> ownership)")
    check(final.get("refusal", "") == "" and float(final.get("commit_at", -1)) >= 0.0,
          "the transfer completed without a refusal")
    position = final.get("authoritative_pos", [])
    check(len(position) == 3 and float(position[1]) >= 185.0 and abs(float(position[0])) < 3
          and abs(float(position[2]) - 30.0) < 3,
          "the authoritative body is inside the interior map (%s)" % position)
    # And the server agrees about the map: its periodic status lines name every
    # connected player's map.
    needle = "uid %d map=castle_interior" % int(final.get("uid", 0))
    deadline = time.time() + 15
    found = False
    while time.time() < deadline and not found:
        found = any(needle in line["tail"] for line in statuses(server.log_path))
        if not found:
            time.sleep(0.5)
    check(found, "the server's status lines report the player on castle_interior")


def test_interior_collision(out_dir, port, server, stub):
    """Bug 2 regression: an authoritative body indoors must rest on the interior
    floor. Two runs, one per claim - enter and hold still, enter and walk a few
    metres - both entered through the real door handshake. What is asserted is
    the SERVER's own position samples (the client's body is only a prediction of
    them) and the server log's fall rescue, which must never have to fire."""
    print("\n--- interior collision: stand still and walk inside the castle ---")
    interior_floor = spawn_point("castle_interior", "vestibule")[1] - 0.5   # authored floor, 200.0
    for label, extra in (
            ("orin", ["--stand-seconds=5", "--walk-seconds=0"]),
            ("peri", ["--stand-seconds=0", "--walk-seconds=4"])):
        marker = len(log_lines(server.log_path))
        records, final = named(label, out_dir, port, "stand", 16, extra)
        if not final:
            continue
        uid = int(final.get("uid", 0))
        check(final.get("map_id") == "castle_interior" and final.get("commit_map") == "castle_interior",
              "%s entered the castle through the door (%s)" % (label, final.get("commit_map")))
        reports = by_event(records, "stand_report")
        check(bool(reports), "%s produced the stand/walk report" % label)
        if not reports:
            continue
        report = reports[-1]
        for phase, samples, seconds in (
                ("standing still", report.get("stand_samples", []), float(report.get("stand_seconds", 0.0))),
                ("walking", report.get("walk_samples", []), float(report.get("walk_seconds", 0.0)))):
            if seconds <= 0.0:
                continue   # this run measures the other half only
            auth_y = [float(s["auth"][1]) for s in samples if len(s.get("auth", [])) == 3]
            local_y = [float(s["local"][1]) for s in samples if len(s.get("local", [])) == 3]
            context = "%s while %s (%d samples)" % (label, phase, len(auth_y))
            if not auth_y:
                check(False, "the server position was sampled " + context)
                continue
            # The client renders its own predicted body; it must not be dragged
            # off the floor by the server's answer either.
            check(min(auth_y) >= interior_floor - 0.6,
                  "the server keeps the body on the interior floor %s (lowest y=%.2f, floor=%.1f)"
                  % (context, min(auth_y), interior_floor))
            if local_y:
                check(min(local_y) >= interior_floor - 0.6,
                      "the rendered body stays on the interior floor %s (lowest y=%.2f)"
                      % (context, min(local_y)))
            check(max(auth_y) - min(auth_y) <= 1.2,
                  "the body does not cycle through the floor %s (height range=%.2f m)"
                  % (context, max(auth_y) - min(auth_y)))
        if float(report.get("walk_seconds", 0.0)) > 0.0:
            check(float(report.get("walk_distance", 0.0)) >= 2.0,
                  "%s walked %.1f m along the interior floor"
                  % (label, float(report.get("walk_distance", 0.0))))
        fell = [line for line in log_lines(server.log_path)[marker:]
                if ("player %d fell out of" % uid) in line]
        check(not fell, "%s: the per-map fall rescue never fired (%d warnings)" % (label, len(fell)))
        if fell:
            print("    fall warnings: %s" % fell[:3])


def test_roundtrips(out_dir, port, server, stub):
    print("\n--- repeated transfers ---")
    before = len(statuses(server.log_path))
    records, final = named("rob", out_dir, port, "roundtrips", 20, ["--roundtrips=3"])
    if not final:
        return
    uid = final.get("uid")
    check(int(final.get("transfers_done", 0)) == 3,
          "three repeated transfers committed (%s)" % final.get("transfers_done"))
    if int(final.get("transfers_done", 0)) != 3:
        print("    commits: %s" % [e for e in transfer_events(final) if e.get("event") == "committed"])
    check(not final.get("roundtrip_failed") and final.get("refusal", "") == "",
          "no leg of the repeated transfer was refused")
    check(final.get("map_id") in ("grounds", "castle_interior"),
          "the client ends on a real map (%s)" % final.get("map_id"))
    commits = [e for e in transfer_events(final) if e.get("event") == "committed"]
    check(len(commits) == 3 and all(int(c.get("token", 0)) > 0 for c in commits),
          "every leg has its own reservation token")
    mined = statuses(server.log_path, uid=uid)
    check(len(mined) >= 2, "the server logged this session while it moved (%d status lines)" % len(mined))
    if len(mined) >= 2:
        check(mined[-1]["entities"] <= mined[0]["entities"],
              "repeated transfers did not grow the entity registry (%d -> %d)"
              % (mined[0]["entities"], mined[-1]["entities"]))
        check(mined[-1]["players"] == 1, "the session still owns exactly one player entity")
    # The same uid was carried through every leg.
    joined = by_event(records, "joined")
    check(bool(joined) and int(joined[0].get("uid", 0)) == int(uid),
          "every leg kept the same entity id")


def test_opposite(out_dir, port, server, stub):
    print("\n--- two players, opposite directions ---")
    inside_handle = start_probe("olive", port, out_dir, "opposite", 14)
    outside_handle = start_probe("otto", port, out_dir, "opposite", 14)
    inside = final_of(collect_probe(inside_handle, 14))
    outside = final_of(collect_probe(outside_handle, 14))
    check(bool(inside) and bool(outside), "both opposite-direction clients produced a transcript")
    if not (inside and outside):
        return
    check(inside.get("commit_map") == "grounds", "the interior player ended on the grounds (%s)" % inside.get("commit_map"))
    check(outside.get("commit_map") == "castle_interior",
          "the grounds player ended in the castle (%s)" % outside.get("commit_map"))
    check(near(inside.get("commit_pos", [999, 999, 999]), spawn_point("grounds", "castle_approach"), 0.01),
          "the returning player landed on the authored grounds spawn")
    check(near(outside.get("commit_pos", [999, 999, 999]), spawn_point("castle_interior", "vestibule"), 0.01),
          "the entering player landed on the authored vestibule spawn")
    check(inside.get("uid") != outside.get("uid"), "the two players are distinct entities")


def test_mounted(out_dir, port, server, stub):
    print("\n--- mounted entry into the castle ---")
    records, final = named("mira", out_dir, port, "mounted", 10)
    if not final:
        return
    check(bool(final.get("mounted_seen")), "the rider really was mounted before requesting")
    check(final.get("refusal", "") == "no_flight",
          "mounted entry was refused with no_flight (%s)" % final.get("refusal"))
    check(final.get("commit_map", "") == "" and final.get("map_id") == "grounds",
          "the rider stayed on the grounds")
    notices = " ".join(str(n.get("text", "")) for n in final.get("notices", []))
    check("no_flight" in notices, "the refusal carried a player-facing reason")


def test_interrupted_relog(out_dir, port, server, stub, character_id):
    print("\n--- interrupted transfer, then relog ---")
    before = len(stub.saves)
    before_lines = len(rosters(server.log_path))
    records, final = named("kate", out_dir, port, "interrupt", 8)
    if not final:
        return
    check(final.get("granted_map") == "castle_interior", "the transfer was granted before the interruption")
    check(final.get("commit_map", "") == "", "the interruption happened before ownership moved")
    # The server must drop the session and settle the body before saving.
    new_lines = []
    deadline = time.time() + 15
    while time.time() < deadline:
        new_lines = rosters(server.log_path)[before_lines:]
        if new_lines and new_lines[-1]["players"] == 0 and any(r["event"] == "leave" for r in new_lines):
            break
        time.sleep(0.3)
    check(bool(new_lines) and new_lines[-1]["players"] == 0 and any(r["event"] == "leave" for r in new_lines),
          "the interrupted session was removed cleanly (players=0)")
    deadline = time.time() + 10
    saved = []
    while time.time() < deadline:
        saved = stub.saved(character_id, before)
        if saved:
            break
        time.sleep(0.25)
    check(bool(saved), "the disconnect persisted the character through the save path")
    pos = []
    if saved:
        payload = saved[-1]
        check(payload.get("map_id") == "grounds",
              "the persisted map is the map the body was really on (%s)" % payload.get("map_id"))
        pos = payload.get("pos", [])
        check(len(pos) == 3 and float(pos[1]) < 185.0,
              "the persisted position is inside the grounds band (%s)" % pos)
        door = MAPS["portals"][0]["trigger"]["center"]
        check(len(pos) == 3 and abs(float(pos[0]) - door[0]) < 8 and abs(float(pos[2]) - door[2]) < 8,
              "the persisted position is the last valid spot at the door (%s)" % pos)
    # Relog with the SAME token: one body, at the persisted location, no
    # duplicate character.
    before_relog = len(rosters(server.log_path))
    records2, final2 = named("kate", out_dir, port, "observer", 9, label="kate-relog")
    if not final2:
        return
    check(final2.get("map_id") == "grounds", "the relog lands on the persisted map (%s)" % final2.get("map_id"))
    if pos:
        check(near(final2.get("authoritative_pos", [999, 999, 999]), pos, 6.0),
              "the relog resumed at the persisted location (%s vs %s)"
              % (final2.get("authoritative_pos"), pos))
    check(int(final2.get("uid", 0)) != int(final.get("uid", 0)),
          "the relog is a fresh entity, not a recycled one")
    relog_lines = rosters(server.log_path)[before_relog:]
    joins = [r for r in relog_lines if r["event"] == "join"]
    check(bool(joins) and all(r["players"] == 1 for r in joins),
          "exactly one character session existed after the relog (join players=%s)"
          % ([r["players"] for r in joins] or "?"))
    check(not any(r["players"] > 1 for r in relog_lines),
          "the server never held two sessions for the interrupted character")


def test_expire(out_dir, stub):
    print("\n--- unacknowledged reservation expiry ---")
    port = free_port()
    server = start_server(port, 515151, out_dir, {
        "HPMMO_API_URL": "http://127.0.0.1:%d" % stub.httpd.server_address[1],
        "HPMMO_SERVICE_TOKEN": stub.token,
        "HPMMO_DEV_TRANSFER_TIMEOUT_MS": 2000,
    })
    try:
        if not server.wait_for("listening on :%d" % port, timeout=90):
            check(False, "world server failed to start for the expiry test")
            return
        check(True, "expiry-test world server is listening")
        records, final = named("eve", out_dir, port, "expire", 22)
    finally:
        server.stop()
    if not final:
        return
    names = event_names(final)
    check("granted" in names, "the reservation was granted")
    check(bool(final.get("expired")), "the unacknowledged reservation expired")
    check("committed" in names, "the retry after expiry completed")
    if "expired" in names and "committed" in names:
        check(names.index("expired") < names.index("committed"),
              "the expiry happened before any commit (nothing moved mid-flight)")
    check(float(final.get("post_expiry_move", -1)) > 1.5,
          "the player can move again after the expiry (%.2f m)" % float(final.get("post_expiry_move", -1)))
    check(final.get("refusal", "") == "", "the expired transfer itself was not reported as another refusal")


def test_full(out_dir, stub):
    print("\n--- full destination ---")
    port = free_port()
    server = start_server(port, 616161, out_dir, {
        "HPMMO_API_URL": "http://127.0.0.1:%d" % stub.httpd.server_address[1],
        "HPMMO_SERVICE_TOKEN": stub.token,
        "HPMMO_DEV_MAP_CAPACITY": 1,
    })
    try:
        if not server.wait_for("listening on :%d" % port, timeout=90):
            check(False, "world server failed to start for the full-destination test")
            return
        check(True, "full-destination world server is listening")
        # Both must overlap: the seat has to still be taken when the second
        # player asks for it.
        print("  - probe finn         scenario=happy     18s")
        finn_handle = start_probe("finn", port, out_dir, "happy", 18)
        time.sleep(7)
        print("  - probe dana         scenario=happy     9s")
        dana_handle = start_probe("dana", port, out_dir, "happy", 9)
        second = final_of(collect_probe(dana_handle, 9))
        first = final_of(collect_probe(finn_handle, 18))
        check(bool(first), "finn produced a transcript")
        check(bool(second), "dana produced a transcript")
    finally:
        server.stop()
    if not first or not second:
        return
    check(first.get("commit_map") == "castle_interior", "the first player took the only seat")
    check(second.get("refusal", "") == "map_full",
          "the second transfer was refused as map_full (%s)" % second.get("refusal"))
    check(second.get("commit_map", "") == "" and second.get("map_id") == "grounds",
          "the refused player stayed on the grounds")


def test_local(out_dir):
    print("\n--- in-process authority checks ---")
    records = run_probe("solo", free_port(), out_dir, "local", 8)
    blocks = by_event(records, "transfer_local")
    check(bool(blocks), "local transfer block produced")
    if not blocks:
        return
    result = blocks[0]
    check(result.get("dead_refused") == "dead", "a dead player's transfer is refused (dead)")
    check(bool(result.get("mount_ok")), "the mount itself was accepted (the refusal below is not vacuous)")
    check(result.get("mounted_refused") == "no_flight", "a mounted player is refused entry (no_flight)")
    check(result.get("range_refused") == "out_of_range", "a request away from the door is refused (range)")
    check(result.get("unknown_portal") == "no_portal", "an unknown portal is refused")
    check(result.get("wrong_map") == "wrong_map", "a destination that is not the door's is refused")
    check(result.get("unknown_destination") == "map_unavailable", "a portal to an unknown map is refused")
    check(bool(result.get("grant_ok")), "the valid request was granted")
    check(result.get("pending_refused") == "transfer_pending", "a second request while pending is refused")
    check(result.get("bad_token") == "bad_transfer_token", "a forged readiness token is refused")
    check(bool(result.get("ready_ok")), "the real token commits")
    check(result.get("map_after_commit") == "castle_interior", "ownership moved on the commit")
    check(near(result.get("pos_after_commit", [999, 999, 999]), result.get("spawn_after_commit", [0, 0, 0]), 0.01),
          "the commit placed the body at the server-approved spawn")
    filt = result.get("filter", {})
    check(bool(filt.get("same_map_visible")), "a same-map player 2 m away is replicated (positive control)")
    check(bool(filt.get("cross_map_hidden")), "the same player on another map is not replicated")
    check(bool(filt.get("reverse_hidden")), "cross-map invisibility holds in the reverse direction")
    check(bool(filt.get("reverse_same_visible")), "the reverse direction still replicates a same-map player")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default="")
    args = parser.parse_args()

    if not os.path.isdir(os.path.join(CLIENT_DIR, "addons", "hpmmo_sim")):
        print("client simulation package not found - run dev.ps1 sync-sim first")
        return 2

    # Absolute on purpose: the client probes inherit the launcher's working
    # directory, which is not this script's, so a relative --out-dir silently
    # writes every probe transcript somewhere else (the run then looks like
    # every probe hung, with no transcript at all).
    out_dir = os.path.abspath(args.out_dir) if args.out_dir else tempfile.mkdtemp(prefix="hpmmo-maps-")
    os.makedirs(out_dir, exist_ok=True)
    print("artifacts: %s" % out_dir)

    for project, name in ((os.path.join(SERVER_DIR, "world"), "world"), (CLIENT_DIR, "client")):
        if not ensure_imported(project, out_dir, name):
            print("import failed for %s (see %s-import.log)" % (project, name))
            return 2

    print("\nkind: %s" % MAPS["maps"]["castle_interior"]["display"])

    ines_pos = spawn_point("castle_interior", "vestibule")
    ground_pos = MAPS["portals"][0]["trigger"]["center"]
    ground_stand = [ground_pos[0], 0.6, ground_pos[2] + 1.5]

    # --- core server: cross-map, happy path, round trips, opposite, mounted,
    # --- interrupted transfer + relog (one boot, sequential sessions).
    stub = StubService().start()
    port = free_port()
    server = start_server(port, 808080, out_dir, {
        "HPMMO_API_URL": "http://127.0.0.1:%d" % stub.httpd.server_address[1],
        "HPMMO_SERVICE_TOKEN": stub.token,
    })
    try:
        if not server.wait_for("listening on :%d" % port, timeout=90):
            check(False, "core world server failed to start")
            return 1
        check(True, "core world server is listening")
        stub.add_character("gwen", seeded_character(101, "gwen", ground_stand, "grounds"))
        stub.add_character("gale", seeded_character(102, "gale", [0.0, 0.6, -34.0], "grounds"))
        stub.add_character("ines", seeded_character(103, "ines", ines_pos, "castle_interior"))
        stub.add_character("hank", seeded_character(104, "hank", ground_stand, "grounds"))
        stub.add_character("rob", seeded_character(110, "rob", ground_stand, "grounds"))
        stub.add_character("olive", seeded_character(106, "olive", ines_pos, "castle_interior"))
        stub.add_character("otto", seeded_character(107, "otto", ground_stand, "grounds"))
        stub.add_character("mira", seeded_character(108, "mira", ground_stand, "grounds"))
        stub.add_character("kate", seeded_character(109, "kate", ground_stand, "grounds"))
        stub.add_character("orin", seeded_character(111, "orin", ground_stand, "grounds"))
        stub.add_character("peri", seeded_character(112, "peri", ground_stand, "grounds"))

        test_cross_map(out_dir, port, server, stub)
        test_happy(out_dir, port, server, stub)
        test_interior_collision(out_dir, port, server, stub)
        test_roundtrips(out_dir, port, server, stub)
        test_opposite(out_dir, port, server, stub)
        test_mounted(out_dir, port, server, stub)
        test_interrupted_relog(out_dir, port, server, stub, 109)
    finally:
        server.stop()
        stub.stop()

    # --- expiry uses a compressed reservation timeout.
    stub_expire = StubService().start()
    stub_expire.add_character("eve", seeded_character(201, "eve", ground_stand, "grounds"))
    test_expire(out_dir, stub_expire)
    stub_expire.stop()

    # --- capacity refusal uses a clamped map capacity.
    stub_full = StubService().start()
    stub_full.add_character("finn", seeded_character(301, "finn", ground_stand, "grounds"))
    stub_full.add_character("dana", seeded_character(302, "dana", ground_stand, "grounds"))
    test_full(out_dir, stub_full)
    stub_full.stop()

    # --- in-process authority-level checks (no server needed).
    test_local(out_dir)

    print("\nMAPS RESULT: %d checks, %d failures" % (checks, len(failures)))
    for failure in failures:
        print("  FAILED: " + failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
