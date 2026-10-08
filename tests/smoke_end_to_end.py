#!/usr/bin/env python3
"""End-to-end proof of the path a real player takes (VERIFYING).

The multiplayer suite joins with dev joins (no auth backend). This one runs the
whole stack the way the deployment controller does:

    PostgreSQL  ->  C++ service  ->  world server  ->  synthetic client check

and asserts the synthetic check PASSES. A second run with a wrong password must
FAIL, so the check cannot be a rubber stamp.

SKIPs (exit 2) when the local PostgreSQL binaries or the built service are
missing, with instructions - same convention as tests/integration_api.py.

Environment: HPMMO_PG_ROOT, HPMMO_PG_PASSWORD, HPMMO_PG_DATA, HPMMO_GODOT.
"""

import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER_DIR = os.path.dirname(HERE)
WORKSPACE = os.path.dirname(SERVER_DIR)
PG_ROOT = os.environ.get("HPMMO_PG_ROOT", os.path.join(WORKSPACE, "_tools", "pgsql"))
PG_DATA = os.environ.get("HPMMO_PG_DATA", os.path.join(os.path.dirname(PG_ROOT.rstrip("/\\")), "pgdata"))
PG_PORT = 55432
SERVICE = os.environ.get("HPMMO_SERVICE_EXE", os.path.join(SERVER_DIR, "services", "cpp", "build", "hpmmo_service.exe"))
GODOT = os.environ.get("HPMMO_GODOT", "godot")
SERVICE_TOKEN = "smoke-token-%d" % int(time.time())

checks = 0
failures = []


def check(condition, message):
    global checks
    checks += 1
    print(("PASS: " if condition else "FAIL: ") + message)
    if not condition:
        failures.append(message)


def skip(reason):
    print("SKIP: %s" % reason)
    sys.exit(2)


def marker_cmd():
    if os.path.isfile(GODOT) and GODOT.lower().endswith("godot.exe"):
        console = GODOT[: -len("godot.exe")] + "godot_console.exe"
        if os.path.isfile(console):
            return console
    return GODOT


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def pg_tool(name):
    return os.path.join(PG_ROOT, "bin", name + ".exe" if os.name == "nt" else name)


def run(args, env=None, timeout=120, cwd=None):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                          env=env, cwd=cwd, errors="replace")


def service_post(port, path, body, bearer="", service_token=""):
    """One POST to the account service, returning (status, parsed_body)."""
    headers = {"Content-Type": "application/json"}
    if bearer:
        headers["Authorization"] = "Bearer " + bearer
    if service_token:
        headers["X-Service-Token"] = service_token
    request = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path),
                                     data=json.dumps(body).encode("utf-8"),
                                     headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        try:
            return error.code, json.loads(error.read().decode("utf-8"))
        except Exception:
            return error.code, {}
    except Exception:
        return 0, {}


SMOKE_CLIENT_ARGS = None   # filled in main(); the scene command shared by every run


def run_smoke_client(env, timeout=180, label="smoke client"):
    """Run the scene; a hung client is reported with its own last lines rather
    than crashing the driver with a traceback."""
    try:
        return run(SMOKE_CLIENT_ARGS, env=env, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        output = error.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", "replace")
        print("      | %s hit the %ds bound; its last lines were:" % (label, timeout))
        for line in output.splitlines()[-20:]:
            print("      | " + line)
        return subprocess.CompletedProcess(SMOKE_CLIENT_ARGS, 124, output, "")


def main():
    password_file = os.path.join(HERE, ".pg-dev.pw")
    password = os.environ.get("HPMMO_PG_PASSWORD")
    if not password and os.path.isfile(password_file):
        password = open(password_file, encoding="utf-8").read().strip()
    if not password:
        skip("no database password (tests/.pg-dev.pw or HPMMO_PG_PASSWORD)")
    if not os.path.isfile(pg_tool("pg_ctl")):
        skip("no PostgreSQL binaries at %s (set HPMMO_PG_ROOT)" % PG_ROOT)
    if not os.path.isfile(SERVICE):
        skip("no built service at %s (see server/README.md)" % SERVICE)

    # 1. database cluster. The start is NOT run through the capturing helper:
    # pg_ctl leaves the postgres daemon holding its inherited stdout/stderr
    # handles, so a captured-pipe run would block until the server exits (it
    # hung forever on a machine where the cluster was down). A file handle
    # instead is inherited harmlessly.
    if run([pg_tool("pg_isready"), "-h", "127.0.0.1", "-p", str(PG_PORT)]).returncode != 0:
        pg_log = open(os.path.join(PG_DATA, "pg.log"), "ab")
        started = subprocess.run([pg_tool("pg_ctl"), "-D", PG_DATA, "-l", os.path.join(PG_DATA, "pg.log"),
                                  "-o", "-p %d -c listen_addresses=127.0.0.1" % PG_PORT, "-w", "start"],
                                 stdout=pg_log, stderr=pg_log, timeout=120)
        pg_log.close()
        if started.returncode != 0:
            skip("could not start PostgreSQL (rc %d)" % started.returncode)
    check(True, "PostgreSQL is up on 127.0.0.1:%d" % PG_PORT)

    db_name = "hpmmo_smoke_%d" % int(time.time())
    env = dict(os.environ, PGPASSWORD=password)
    created = run([pg_tool("psql"), "-h", "127.0.0.1", "-p", str(PG_PORT), "-U", "hpmmo", "-d", "postgres",
                   "-tAc", "CREATE DATABASE %s OWNER hpmmo;" % db_name], env=env)
    check(created.returncode == 0, "throwaway database created")

    dsn = "postgresql://hpmmo:%s@127.0.0.1:%d/%s" % (password, PG_PORT, db_name)
    service_env = dict(os.environ, DATABASE_URL=dsn,
                       HPMMO_MIGRATIONS_DIR=os.path.join(SERVER_DIR, "db", "migrations"))
    migrated = run([SERVICE, "migrate"], env=service_env, cwd=os.path.join(SERVER_DIR, "services", "cpp"))
    check(migrated.returncode == 0, "migrations applied by the service binary")

    api_port = free_port()
    world_port = free_port()
    admin_port = free_port()
    service_env.update(HPMMO_HTTP_PORT=str(api_port), HPMMO_SERVICE_TOKEN=SERVICE_TOKEN,
                       HPMMO_BIND="127.0.0.1", HPMMO_ARGON2_M="8192")
    service_log = open(os.path.join(tempfile.gettempdir(), "hpmmo-smoke-service.log"), "wb")
    service = subprocess.Popen([SERVICE, "serve"], stdout=service_log, stderr=subprocess.STDOUT,
                               env=service_env, cwd=os.path.join(SERVER_DIR, "services", "cpp"))
    world = None
    try:
        ready = False
        for _ in range(60):
            if service.poll() is not None:
                break
            try:
                import urllib.request
                with urllib.request.urlopen("http://127.0.0.1:%d/api/ready" % api_port, timeout=2) as r:
                    ready = r.status == 200
            except Exception:
                ready = False
            if ready:
                break
            time.sleep(0.25)
        check(ready, "C++ service is ready with the new schema")
        if not ready:
            return finish()

        # The exported world must be re-imported after an export, or Godot spends
        # minutes importing on first run (and resolves no class_name globals).
        world_dir = os.path.join(SERVER_DIR, "world")
        run([marker_cmd(), "--headless", "--path", world_dir, "--editor", "--import", "--quit"], timeout=600)

        # 2. world server, this time WITH persistence (auth required, no dev joins)
        world_env = dict(os.environ, HPMMO_WORLD_PORT=str(world_port), HPMMO_WORLD_SEED="20261003",
                         HPMMO_API_URL="http://127.0.0.1:%d" % api_port, HPMMO_SERVICE_TOKEN=SERVICE_TOKEN,
                         HPMMO_ADMIN_PORT=str(admin_port), HPMMO_RELEASE="smoke-test")
        world_env.pop("HPMMO_ALLOW_DEV_JOIN", None)
        world_log_path = os.path.join(tempfile.gettempdir(), "hpmmo-smoke-world.log")
        world_log = open(world_log_path, "wb")
        world = subprocess.Popen([marker_cmd(), "--headless", "--path", os.path.join(SERVER_DIR, "world"),
                                  "res://server/world_server.tscn"], stdout=world_log, stderr=subprocess.STDOUT,
                                 env=world_env)
        listening = False
        for _ in range(90):
            if world.poll() is not None:
                break
            try:
                if "listening on :%d" % world_port in open(world_log_path, encoding="utf-8", errors="replace").read():
                    listening = True
                    break
            except OSError:
                pass
            time.sleep(0.25)
        check(listening, "world server is listening with persistence enabled")
        if not listening:
            return finish()

        # 3. the synthetic check, exactly as the deployment controller runs it
        global SMOKE_CLIENT_ARGS
        SMOKE_CLIENT_ARGS = [marker_cmd(), "--headless", "--path", os.path.join(SERVER_DIR, "world"),
                             os.path.join(SERVER_DIR, "world", "server", "smoke_client.tscn")]
        smoke_env = dict(os.environ, HPMMO_SMOKE_API_URL="http://127.0.0.1:%d" % api_port,
                         HPMMO_SMOKE_WORLD_PORT=str(world_port), HPMMO_SMOKE_USER="smoke_player",
                         HPMMO_SMOKE_PASSWORD="SmokeTest123", HPMMO_SMOKE_TIMEOUT="45")
        smoke = run_smoke_client(smoke_env, timeout=120)
        if smoke.returncode != 0:
            # Show why, in the test's own output: the check's diagnosis is the
            # whole point of running it.
            for line in (smoke.stdout + smoke.stderr).splitlines():
                if "SMOKE FAIL" in line or "[smoke]" in line:
                    print("      | " + line.strip())
        check("SMOKE OK" in smoke.stdout, "synthetic login+join check passes (exit %d)" % smoke.returncode)
        check(smoke.returncode == 0, "the smoke check exits 0")
        check("smoke_player" in smoke.stdout or "SMOKE OK" in smoke.stdout,
              "the check reports what it did")

        # 4. negative control: the same check with a wrong password must FAIL,
        #    otherwise it proves nothing about the login it claims to verify.
        bad_env = dict(smoke_env, HPMMO_SMOKE_PASSWORD="WrongPassword123")
        bad = run_smoke_client(bad_env, timeout=120)
        check(bad.returncode != 0, "a wrong password makes the check fail (exit %d)" % bad.returncode)
        check("SMOKE FAIL" in bad.stdout, "the failure names the step that failed")

        # 5. no secret may appear in the output of either run
        leaked = [s for s in ("SmokeTest123", "WrongPassword123", SERVICE_TOKEN) if s in smoke.stdout + bad.stdout]
        check(not leaked, "no password or token is printed by the check")

        # 6. the character-bind fix, the end-to-end persistence promise: the launcher
        #    shape (an UNBOUND ticket, a session that names its character after
        #    the join) plays, earns, disconnects, and the numbers are still
        #    there when the character is reloaded.
        persist_env = dict(smoke_env, HPMMO_SMOKE_PERSIST="1", HPMMO_SMOKE_TIMEOUT="240",
                           HPMMO_SMOKE_FIGHT_SECONDS="150")
        persist = run_smoke_client(persist_env, timeout=300, label="the persistence run")
        persist_line = next((line for line in persist.stdout.splitlines() if "SMOKE PERSIST OK" in line), "")
        for line in (persist.stdout + persist.stderr).splitlines():
            if "[smoke]" in line:
                print("      | " + line.strip())
        check(bool(persist_line), "the persistence run reached its own OK line (exit %d)" % persist.returncode)
        match = re.search(
            r"character=(\d+) exp=(-?\d+) galleons=(-?\d+) pos=([-\d.]+),([-\d.]+),([-\d.]+) "
            r"map=(\S+) kills=(\d+) loot=(\d+)", persist_line)
        check(bool(match), "the persistence run reported its numbers")
        if not match:
            return finish()
        char_id = int(match.group(1))
        earned = {"exp": int(match.group(2)), "galleons": int(match.group(3)),
                  "pos": [float(match.group(4)), float(match.group(5)), float(match.group(6))],
                  "map": match.group(7), "kills": int(match.group(8)), "loot": int(match.group(9))}
        print("      | earned: %s" % earned)
        check(earned["kills"] > 0, "the session killed a mob online (%d)" % earned["kills"])
        check(earned["exp"] > 0, "the session gained experience online (exp %d)" % earned["exp"])
        check(earned["loot"] > 0, "the session picked up dropped loot (%d item(s))" % earned["loot"])

        # 7. the driver reloads the character through the service itself (the
        #    same read the journey's measurement used) and compares the numbers.
        character = {}
        deadline = time.time() + 30
        while time.time() < deadline:
            status, body = service_post(api_port, "/api/characters/load", {"character_id": char_id},
                                        service_token=SERVICE_TOKEN)
            character = body.get("character", {}) if status == 200 else {}
            if character and int(character.get("exp", -1)) >= earned["exp"]:
                break
            time.sleep(1.0)
        check(bool(character), "the character reloads from the service after the disconnect")
        if character:
            saved_pos = character.get("pos", [0.0, 0.0, 0.0])
            distance = sum((float(saved_pos[i]) - earned["pos"][i]) ** 2 for i in range(3)) ** 0.5
            inventory = character.get("inventory", [])
            print("      | reloaded: exp=%s level=%s galleons=%s map=%s pos=%s rev=%s items=%d" % (
                character.get("exp"), character.get("level"), character.get("galleons"),
                character.get("map_id"), saved_pos, character.get("revision"), len(inventory)))
            check(int(character.get("exp", -1)) >= earned["exp"],
                  "the earned experience survived the disconnect (saved %s, session %d)"
                  % (character.get("exp"), earned["exp"]))
            check(int(character.get("level", 0)) >= 1, "the level survived (%s)" % character.get("level"))
            check(int(character.get("galleons", -1)) >= earned["galleons"],
                  "the galleons survived (saved %s, session %d)"
                  % (character.get("galleons"), earned["galleons"]))
            check(character.get("map_id") == "grounds",
                  "the map survived (saved %s)" % character.get("map_id"))
            check(distance <= 8.0,
                  "the position survived (saved %s, session %s, %.1f m apart)"
                  % (saved_pos, earned["pos"], distance))
            check(len(inventory) > 0, "the inventory survived (%d stack(s))" % len(inventory))
            check(int(character.get("revision", 0)) > 1,
                  "the save is a real write, not the creation row (revision %s)" % character.get("revision"))

        # 8. control: a ticket redeemed WITH the character id binds the session
        #    at join, without a second exchange.
        reload_env = dict(smoke_env, HPMMO_SMOKE_RELOAD="1", HPMMO_SMOKE_EXPECT_EXP=str(earned["exp"]),
                          HPMMO_SMOKE_TIMEOUT="90")
        reload_run = run_smoke_client(reload_env, timeout=150, label="the reload control")
        for line in reload_run.stdout.splitlines():
            if "[smoke]" in line:
                print("      | " + line.strip())
        check("SMOKE RELOAD OK" in reload_run.stdout,
              "a character-bound ticket binds the session at join (exit %d)" % reload_run.returncode)

        # 9. control: another account's character must be refused, and must stay
        #    untouched. This is the ownership rule, proved end to end through the
        #    real service, not with a stub.
        foreign_user = "smoke_foreign_%d" % int(time.time())
        foreign_pass = "ForeignTest123"
        service_post(api_port, "/api/register", {"username": foreign_user, "password": foreign_pass})
        status, body = service_post(api_port, "/api/login", {"username": foreign_user, "password": foreign_pass})
        foreign_token = body.get("token", "")
        check(status == 200 and bool(foreign_token), "the foreign control account exists")
        status, body = service_post(api_port, "/api/characters/create",
                                    {"name": "Foreign%d" % (int(time.time()) % 10000), "house": "Slytherin"},
                                    bearer=foreign_token)
        foreign_id = int(body.get("character", {}).get("id", 0))
        check(status == 200 and foreign_id > 0, "the foreign account has a character (id %d)" % foreign_id)
        if foreign_id > 0:
            foreign_env = dict(smoke_env, HPMMO_SMOKE_FOREIGN=str(foreign_id), HPMMO_SMOKE_TIMEOUT="90")
            foreign = run_smoke_client(foreign_env, timeout=150, label="the foreign control")
            for line in (foreign.stdout + foreign.stderr).splitlines():
                if "[smoke]" in line:
                    print("      | " + line.strip())
            check("SMOKE FOREIGN OK" in foreign.stdout,
                  "the server refused another account's character (exit %d)" % foreign.returncode)
            status, body = service_post(api_port, "/api/characters/load", {"character_id": foreign_id},
                                        service_token=SERVICE_TOKEN)
            untouched = body.get("character", {}) if status == 200 else {}
            check(int(untouched.get("exp", -1)) == 0 and int(untouched.get("level", 0)) == 1
                  and int(untouched.get("revision", 0)) == 1,
                  "the refused character was never touched (exp %s, level %s, revision %s)"
                  % (untouched.get("exp"), untouched.get("level"), untouched.get("revision")))
            leaked = [s for s in (foreign_pass, SERVICE_TOKEN)
                      if s in persist.stdout + reload_run.stdout + foreign.stdout]
            check(not leaked, "no password or token is printed by the persistence runs")
    finally:
        if world is not None and world.poll() is None:
            world.terminate()
            try:
                world.wait(timeout=10)
            except subprocess.TimeoutExpired:
                world.kill()
        if service.poll() is None:
            service.terminate()
            try:
                service.wait(timeout=10)
            except subprocess.TimeoutExpired:
                service.kill()
        service_log.close()
        run([pg_tool("psql"), "-h", "127.0.0.1", "-p", str(PG_PORT), "-U", "hpmmo", "-d", "postgres",
             "-tAc", "DROP DATABASE IF EXISTS %s WITH (FORCE);" % db_name], env=env)
    return finish()


def finish():
    print("\nSMOKE RESULT: %d checks, %d failures" % (checks, len(failures)))
    for failure in failures:
        print("  FAILED: " + failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
