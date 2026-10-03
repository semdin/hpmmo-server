#!/usr/bin/env python3
"""End-to-end proof of the path a real player takes (plan.md Phase 6 VERIFYING).

The multiplayer suite joins with dev joins (no auth backend). This one runs the
whole stack the way the deployment controller does:

    PostgreSQL  ->  C++ service  ->  world server  ->  synthetic client check

and asserts the synthetic check PASSES. A second run with a wrong password must
FAIL, so the check cannot be a rubber stamp.

SKIPs (exit 2) when the local PostgreSQL binaries or the built service are
missing, with instructions - same convention as tests/integration_api.py.

Environment: HPMMO_PG_ROOT, HPMMO_PG_PASSWORD, HPMMO_PG_DATA, HPMMO_GODOT.
"""

import os
import socket
import subprocess
import sys
import tempfile
import time

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

    # 1. database cluster
    if run([pg_tool("pg_isready"), "-h", "127.0.0.1", "-p", str(PG_PORT)]).returncode != 0:
        started = run([pg_tool("pg_ctl"), "-D", PG_DATA, "-l", os.path.join(PG_DATA, "pg.log"),
                       "-o", "-p %d -c listen_addresses=127.0.0.1" % PG_PORT, "-w", "start"])
        if started.returncode != 0:
            skip("could not start PostgreSQL: %s" % started.stdout[-300:])
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
        smoke_env = dict(os.environ, HPMMO_SMOKE_API_URL="http://127.0.0.1:%d" % api_port,
                         HPMMO_SMOKE_WORLD_PORT=str(world_port), HPMMO_SMOKE_USER="smoke_player",
                         HPMMO_SMOKE_PASSWORD="SmokeTest123", HPMMO_SMOKE_TIMEOUT="45")
        smoke = run([marker_cmd(), "--headless", "--path", os.path.join(SERVER_DIR, "world"),
                     os.path.join(SERVER_DIR, "world", "server", "smoke_client.tscn")],
                    env=smoke_env, timeout=120)
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
        bad = run([marker_cmd(), "--headless", "--path", os.path.join(SERVER_DIR, "world"),
                   os.path.join(SERVER_DIR, "world", "server", "smoke_client.tscn")],
                  env=bad_env, timeout=120)
        check(bad.returncode != 0, "a wrong password makes the check fail (exit %d)" % bad.returncode)
        check("SMOKE FAIL" in bad.stdout, "the failure names the step that failed")

        # 5. no secret may appear in the output of either run
        leaked = [s for s in ("SmokeTest123", "WrongPassword123", SERVICE_TOKEN) if s in smoke.stdout + bad.stdout]
        check(not leaked, "no password or token is printed by the check")
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
