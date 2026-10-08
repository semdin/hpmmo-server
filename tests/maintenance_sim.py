#!/usr/bin/env python3
"""maintenance proof: drain / save / disconnect over real processes.

Proves the application-side exit checks with real processes:

  1. cycle   - one world server and two headless clients. `begin` announces a
               countdown to every connected client, new joins are refused with
               `maintenance`, the state sequence ONLINE -> ANNOUNCING -> DRAINING
               -> SAVING -> DISCONNECTING -> MAINTENANCE is observed in order, a
               cast during SAVING is refused and costs no mana, the client
               receives the announcement and the DISCONNECTING notice, and the
               server ends the cycle reporting zero players.
  2. abort   - abort before the save barrier returns to ONLINE and joins work
               again; abort once SAVING has started is refused with 409.
  3. surface - /admin/status answers during MAINTENANCE (maintenance, not
               unreachable) and reports an idle simulation; a wrong or missing
               token is 403; a server with no configured token never starts the
               admin API at all.

Usage:
  python tests/maintenance_sim.py [--out-dir DIR]

Environment: HPMMO_GODOT (godot binary), HPMMO_CLIENT_DIR / HPMMO_SERVER_DIR to
point at the two checkouts (defaults assume the standard workspace layout). The
service token is generated per run and is never printed.
"""

import argparse
import json
import os
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

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


def free_port(kind):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def free_udp_port():
    return free_port(socket.SOCK_DGRAM)


def free_tcp_port():
    return free_port(socket.SOCK_STREAM)


def marker_cmd():
    """Prefer the console build: the GUI build returns before the run finishes."""
    path = GODOT
    if os.path.isfile(path) and path.lower().endswith("godot.exe"):
        console = path[: -len("godot.exe")] + "godot_console.exe"
        if os.path.isfile(console):
            return console
    return GODOT


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


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
                return needle in read_text(self.log_path)
            if needle in read_text(self.log_path):
                return True
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


def start_server(port, admin_port, token, seed, out_dir, extra=None, log_name="world-server.log"):
    env = base_env({
        "HPMMO_WORLD_PORT": port,
        "HPMMO_WORLD_SEED": seed,
        "HPMMO_ALLOW_DEV_JOIN": "1",
        # Persistence stays unconfigured (no HPMMO_API_URL) on purpose: the save
        # barrier must complete by itself with no acknowledgements to wait for.
        "HPMMO_SERVICE_TOKEN": token,
        "HPMMO_ADMIN_PORT": admin_port,
        # Short but fully observable phases: 5 s countdown, 10 s drain, >=3 s save.
        "HPMMO_MAINTENANCE_DRAIN_SECONDS": "10",
        "HPMMO_MAINTENANCE_SAVE_MIN_MS": "3000",
        "HPMMO_MAINTENANCE_ANNOUNCE_MS": "1000",
        "HPMMO_NET_PROFILE": "local",
    })
    if extra:
        env.update(extra)
    log = os.path.join(out_dir, log_name)
    proc = Proc("world-server", [marker_cmd(), "--headless", "--path", os.path.join(SERVER_DIR, "world"),
                                 "res://server/world_server.tscn"], env, log)
    return proc


def start_probe(name, mode, port, admin_port, out_dir, seconds=90, extra_env=None):
    """Launch a probe without waiting for it (clients must overlap in time)."""
    transcript = os.path.join(out_dir, "%s.jsonl" % name)
    env = base_env(extra_env)
    env["HPMMO_NET_PROFILE"] = "local"
    log = os.path.join(out_dir, "%s.log" % name)
    log_handle = open(log, "wb")
    args = [marker_cmd(), "--headless", "--path", CLIENT_DIR,
            "res://scenes/test/net_client_probe.tscn", "--",
            "--mode=%s" % mode, "--port=%d" % port, "--name=%s" % name,
            "--out=%s" % transcript, "--seconds=%d" % seconds,
            "--admin-port=%d" % admin_port]
    proc = subprocess.Popen(args, stdout=log_handle, stderr=subprocess.STDOUT, env=env)
    return {"proc": proc, "log": log_handle, "transcript": transcript, "seconds": seconds}


def read_transcript(path):
    records = []
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return records


def collect_probe(handle, wait=120.0):
    if handle is None:
        return []
    proc = handle["proc"]
    try:
        proc.wait(timeout=wait)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=10)
    handle["log"].close()
    return read_transcript(handle["transcript"])


def final_of(records):
    for record in reversed(records):
        if record.get("event") == "final":
            return record
    return {}


def by_event(records, name):
    return [r for r in records if r.get("event") == name]


def wait_for_admin_state(handle, state, timeout=60.0):
    """The maintenance probe rewrites its transcript while it runs, so its state
    observations are readable before it exits."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for record in read_transcript(handle["transcript"]):
            if record.get("event") == "admin_state" and record.get("state") == state:
                return record
        if handle["proc"].poll() is not None:
            break
        time.sleep(0.1)
    return None


def admin(method, port, path, token=None, body=None, timeout=5.0):
    """One admin request. Returns (status, payload); status 0 means the port did
    not answer at all. The token is never logged or printed."""
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path), data=data, method=method)
    if body is not None:
        request.add_header("Content-Type", "application/json")
    if token is not None:
        request.add_header("X-Service-Token", token)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as error:
        try:
            payload = json.loads(error.read().decode("utf-8") or "{}")
        except (ValueError, OSError):
            payload = {}
        return error.code, payload
    except (urllib.error.URLError, TimeoutError, ConnectionError, OSError):
        return 0, {}


def is_subsequence(wanted, observed):
    index = 0
    for item in observed:
        if item == wanted[index]:
            index += 1
            if index == len(wanted):
                return True
    return False


# --------------------------------------------------------------------- tests

def test_cycle(out_dir):
    print("\n--- maintenance cycle: announce, drain, save, disconnect ---")
    port = free_udp_port()
    admin_port = free_tcp_port()
    token = secrets.token_hex(24)          # never printed
    server = start_server(port, admin_port, token, 606060, out_dir,
                          extra={"HPMMO_RELEASE": "maintenance-test"})
    keeper = None
    victim = None
    latecomer = None
    latecomer2 = None
    sequence = []
    online_state = "ONLINE"
    log_path = server.log_path
    try:
        if not server.wait_for("listening on :%d" % port, timeout=90):
            check(False, "world server failed to start")
            return
        check(True, "the world server is listening")
        check(server.wait_for("[AdminApi] maintenance API on 127.0.0.1:%d" % admin_port, timeout=30),
              "the maintenance API is bound to 127.0.0.1 on the configured port")

        # --- the surface, before anything happens
        status, payload = admin("GET", admin_port, "/admin/state", token)
        check(status == 200 and payload.get("state") == "ONLINE",
              "GET /admin/state answers ONLINE before maintenance")
        online_state = str(payload.get("state", "ONLINE"))
        check(isinstance(payload.get("protocol"), int) and payload.get("protocol") > 0,
              "the status payload publishes the protocol version (%s)" % payload.get("protocol"))
        check(payload.get("release") == "maintenance-test",
              "the status payload publishes the release identifier")
        check(int(payload.get("players", -1)) == 0, "the status payload counts zero players")
        check(int(payload.get("uptime_ms", 0)) > 0, "the status payload publishes uptime")
        check(admin("GET", admin_port, "/admin/state", "0" * 48)[0] == 403,
              "a request with a wrong token is refused with 403")
        check(admin("GET", admin_port, "/admin/state", None)[0] == 403,
              "a request with no token is refused with 403")
        check(admin("GET", admin_port, "/admin/does-not-exist", token)[0] == 404,
              "an unknown route is 404")

        # --- abort before the save barrier: back to ONLINE, joins work again
        status, first = admin("POST", admin_port, "/admin/maintenance/begin", token,
                              {"reason": "abort rehearsal", "countdown_seconds": 30})
        check(status == 200 and first.get("state") == "ANNOUNCING",
              "begin enters ANNOUNCING and answers with the state")
        check(int(first.get("deadline_ms", 0)) > 0, "the begin answer carries the deadline")
        status, aborted = admin("POST", admin_port, "/admin/maintenance/abort", token, {})
        check(status == 200 and aborted.get("state") == "ONLINE",
              "abort before the save barrier returns to ONLINE")

        # --- a client can join again after the abort
        victim = start_probe("victim", "maintenance", port, admin_port, out_dir, seconds=30,
                             extra_env={"HPMMO_SERVICE_TOKEN": token})
        check(server.wait_for("as 'victim'", timeout=90),
              "a client joins after the abort (joins work again)")

        # --- POST /admin/admin/save: flush and acknowledge on demand
        status, saved = admin("POST", admin_port, "/admin/admin/save", token, {})
        check(status == 200 and saved.get("failed") == 0 and isinstance(saved.get("saved"), int),
              "POST /admin/admin/save flushes and answers {saved, failed} (saved=%s failed=%s)"
              % (saved.get("saved"), saved.get("failed")))

        # --- POST /admin/disconnect-all: the DISCONNECTING step on its own
        status, kicked = admin("POST", admin_port, "/admin/disconnect-all", token, {})
        check(status == 200 and kicked.get("disconnected") == 1,
              "POST /admin/disconnect-all removes the connected session (disconnected=%s)"
              % kicked.get("disconnected"))
        check(server.wait_for("disconnect-all: 1 session(s) removed", timeout=15),
              "the server verified the disconnect step on its own")
        status, after_kick = admin("GET", admin_port, "/admin/state", token)
        check(status == 200 and after_kick.get("state") == "ONLINE"
              and int(after_kick.get("players", -1)) == 0,
              "the world is still ONLINE with zero players after disconnect-all")

        # --- the real cycle
        keeper = start_probe("keeper", "maintenance", port, admin_port, out_dir, seconds=120,
                             extra_env={"HPMMO_SERVICE_TOKEN": token})
        check(server.wait_for("as 'keeper'", timeout=90), "the keeper probe joined the world")
        # The client has to have seen the world ONLINE before the countdown
        # starts, or its independent state sequence legitimately begins later.
        check(bool(wait_for_admin_state(keeper, "ONLINE", timeout=60)),
              "the connected client observed the world ONLINE before the countdown")

        # --- the real cycle
        status, begin = admin("POST", admin_port, "/admin/maintenance/begin", token,
                              {"reason": "rolling restart", "countdown_seconds": 5})
        check(status == 200 and begin.get("state") == "ANNOUNCING",
              "begin enters ANNOUNCING and returns {state, deadline_ms, players}")
        check(int(begin.get("deadline_ms", 0)) > 0 and int(begin.get("players", -1)) == 1,
              "the begin answer reports the deadline and the 1 connected player")
        status, second = admin("POST", admin_port, "/admin/maintenance/begin", token,
                               {"reason": "again", "countdown_seconds": 5})
        check(status == 409 and second.get("error") == "already_in_maintenance",
              "a second begin while maintenance is running is refused with 409")

        # --- a join while the world is closed is refused with `maintenance`
        latecomer = start_probe("latecomer", "maintenance", port, admin_port, out_dir, seconds=20,
                                extra_env={"HPMMO_SERVICE_TOKEN": token})

        # --- follow the sequence, hit SAVING with an abort, watch MAINTENANCE
        # The loop starts after `begin`, so ONLINE (observed by the checks above)
        # is seeded here to cover the full contract sequence.
        sequence = [online_state]
        abort_status = None
        abort_body = {}
        state_at_abort = ""
        saving_snapshot = {}
        maintenance_snapshot = {}
        launch_state_of_latecomer2 = ""
        deadline = time.time() + 60.0
        while time.time() < deadline:
            status, payload = admin("GET", admin_port, "/admin/status", token)
            if status != 200:
                time.sleep(0.05)
                continue
            state = str(payload.get("state", ""))
            if state and (not sequence or sequence[-1] != state):
                sequence.append(state)
                print("    state: %-13s players=%s tick=%s" % (state, payload.get("players"), payload.get("tick")))
            if state == "DRAINING" and latecomer2 is None:
                latecomer2 = start_probe("latecomer2", "maintenance", port, admin_port, out_dir,
                                         seconds=20, extra_env={"HPMMO_SERVICE_TOKEN": token})
                launch_state_of_latecomer2 = state
            if state == "SAVING":
                if abort_status is None:
                    state_at_abort = state
                    abort_status, abort_body = admin("POST", admin_port, "/admin/maintenance/abort", token, {})
                saving_snapshot = payload
            if state == "MAINTENANCE":
                maintenance_snapshot = payload
                break
            time.sleep(0.05)

        order = ["ONLINE", "ANNOUNCING", "DRAINING", "SAVING", "DISCONNECTING", "MAINTENANCE"]
        check(is_subsequence(order, sequence),
              "the state sequence was observed in order: %s" % " -> ".join(sequence))
        check(bool(saving_snapshot), "SAVING was observed")
        check(state_at_abort == "SAVING" and abort_status == 409
              and abort_body.get("error") == "too_late" and abort_body.get("state") == "SAVING",
              "abort during SAVING is refused with 409 (state=%s error=%s)"
              % (abort_body.get("state"), abort_body.get("error")))
        check(bool(maintenance_snapshot), "the cycle reached MAINTENANCE")

        # --- /admin/status keeps answering in MAINTENANCE: maintenance, not unreachable
        status_a, payload_a = admin("GET", admin_port, "/admin/status", token)
        time.sleep(0.4)
        status_b, payload_b = admin("GET", admin_port, "/admin/status", token)
        check(status_a == 200 and status_b == 200 and payload_b.get("state") == "MAINTENANCE",
              "GET /admin/status answers during MAINTENANCE")
        check(payload_a.get("tick") == payload_b.get("tick"),
              "the simulation is idle in MAINTENANCE (tick stayed %s)" % payload_b.get("tick"))
        check(payload_b.get("simulation_paused") is True,
              "the status payload reports the simulation paused in MAINTENANCE")
        # "Maintenance, not unreachable" has to be fast too: the launcher and the
        # deployment controller poll this endpoint while the world is stopped.
        latencies = []
        for _ in range(3):
            started = time.time()
            status_probe, _ = admin("GET", admin_port, "/admin/status", token)
            latencies.append((time.time() - started) * 1000.0)
            if status_probe != 200:
                break
        check(status_probe == 200 and max(latencies) < 500.0,
              "the status endpoint answers in milliseconds while the simulation is stopped (max %.0f ms)"
              % max(latencies))
        check(int(payload_b.get("players", -1)) == 0, "the server reports zero players in MAINTENANCE")
        status, again = admin("POST", admin_port, "/admin/maintenance/abort", token, {})
        check(status == 409 and again.get("error") == "too_late",
              "abort after the save barrier is refused with 409 and a message")
        check(bool(again.get("message")), "the refused abort explains itself")
        check(admin("GET", admin_port, "/admin/status", "wrong")[0] == 403,
              "the token is still required in MAINTENANCE")
    finally:
        server.stop()
        keeper_records = collect_probe(keeper, wait=90)
        victim_records = collect_probe(victim, wait=45)
        late_records = collect_probe(latecomer, wait=60)
        late2_records = collect_probe(latecomer2, wait=60)
        server_log = read_text(log_path)

    check(token not in server_log, "the service token never reached the server log")

    # --- disconnect-all was observed by the client it removed
    victim_final = final_of(victim_records)
    check(any(e.get("state") == "DISCONNECTING" for e in victim_final.get("events", [])),
          "the disconnect-all client received the DISCONNECTING notice")
    check(bool(victim_final.get("disconnect_reason")),
          "the disconnect-all client was actually closed (%s)" % victim_final.get("disconnect_reason"))

    # --- what the clients were told
    keeper_final = final_of(keeper_records)
    check(bool(keeper_final), "the connected client produced a transcript")
    events = keeper_final.get("events", [])
    announcing = [e for e in events if e.get("state") == "ANNOUNCING"]
    check(any(int(e.get("seconds_remaining", 0)) > 0 for e in announcing),
          "the client received the maintenance announcement with a countdown (%d announcement(s))" % len(announcing))
    check(any(e.get("state") == "DISCONNECTING" for e in events),
          "the client received the DISCONNECTING notice")
    check(any(e.get("reason") == "rolling restart" for e in announcing),
          "the announcement carries the operator's reason")
    observed = [str(s.get("state")) for s in keeper_final.get("states", [])]
    check(is_subsequence(order, observed),
          "the client independently observed the same state order: %s" % " -> ".join(observed))
    check(bool(keeper_final.get("disconnect_reason")),
          "the server closed the client's connection (%s)" % keeper_final.get("disconnect_reason"))

    # --- the freeze is real: a cast during SAVING is refused and costs no mana
    casts = keeper_final.get("casts", [])
    check(bool(casts), "the client tried to cast during the cycle")
    during_saving = [c for c in casts if c.get("state_at_ack") == "SAVING" or c.get("state") == "SAVING"]
    check(bool(during_saving), "a cast was attempted and answered during SAVING")
    check(during_saving and all(c.get("ok") is False for c in during_saving),
          "every cast during SAVING was refused")
    check(during_saving and all(c.get("reason") == "invalid_state" for c in during_saving),
          "the refusals report the frozen state (invalid_state)")
    measured = [c for c in casts if int(c.get("mana_after", -1)) >= 0]
    spent = [c for c in measured if c.get("ok") is False
             and int(c["mana_after"]) < int(c["mana_before"])]
    check(not spent,
          "no refused cast cost mana (%d refusal(s) measured)" % len(measured))
    check(any(c.get("ok") is True for c in measured),
          "the same cast is accepted before the freeze (the check above is not vacuous)")

    # --- the late joiners were refused, in the announce and in the drain window
    late = by_event(late_records, "joined")
    check(bool(late) and late[0].get("ok") is False and late[0].get("reason") == "maintenance",
          "a join during ANNOUNCING is refused with reason 'maintenance' (%s)" % (late[0].get("reason") if late else None))
    late2 = by_event(late2_records, "joined")
    check(bool(late2) and late2[0].get("ok") is False and late2[0].get("reason") == "maintenance",
          "a join launched in %s is refused with reason 'maintenance' (%s)"
          % (launch_state_of_latecomer2 or "the closed window", late2[0].get("reason") if late2 else None))


def test_no_token(out_dir):
    print("\n--- the admin API refuses to start without a configured token ---")
    port = free_udp_port()
    admin_port = free_tcp_port()
    server = start_server(port, admin_port, "", 606061, out_dir,
                          extra={"HPMMO_SERVICE_TOKEN": ""}, log_name="world-server-notoken.log")
    try:
        if not server.wait_for("listening on :%d" % port, timeout=90):
            check(False, "the token-less world server failed to start")
            return
        check(server.wait_for("[AdminApi] REFUSING TO START", timeout=30),
              "the server logs that the admin API refuses to start without a token")
        status, _ = admin("GET", admin_port, "/admin/state", "anything", timeout=3.0)
        check(status == 0, "the admin port has no listener when no token is configured")
        status, _ = admin("POST", admin_port, "/admin/maintenance/begin", "anything",
                          {"reason": "x", "countdown_seconds": 1}, timeout=3.0)
        check(status == 0, "no maintenance cycle can be started without a token")
    finally:
        server.stop()
    log = read_text(server.log_path)
    check("HPMMO_SERVICE_TOKEN is empty" in log,
          "the log explains why the admin API stayed closed")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--skip", default="")
    args = parser.parse_args()
    skip = {s for s in args.skip.split(",") if s}

    if not os.path.isdir(os.path.join(CLIENT_DIR, "addons", "hpmmo_sim")):
        print("client simulation package not found - run dev.ps1 sync-sim first")
        return 2

    out_dir = args.out_dir or tempfile.mkdtemp(prefix="hpmmo-maint-")
    os.makedirs(out_dir, exist_ok=True)
    print("artifacts: %s" % out_dir)

    for project, name in ((os.path.join(SERVER_DIR, "world"), "world"), (CLIENT_DIR, "client")):
        if not ensure_imported(project, out_dir, name):
            print("import failed for %s (see %s-import.log)" % (project, name))
            return 2

    if "cycle" not in skip:
        test_cycle(out_dir)
    if "notoken" not in skip:
        test_no_token(out_dir)

    print("\nMAINTENANCE RESULT: %d checks, %d failures" % (checks, len(failures)))
    for failure in failures:
        print("  FAILED: " + failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
