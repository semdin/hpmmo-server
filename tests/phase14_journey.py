#!/usr/bin/env python3
"""Phase 14 complete-journey driver (plan.md Phase 14: the section 1 journey,
end to end, on a packaged build).

Brings up the real stack the way production does -

    PostgreSQL -> C++ account/persistence service -> authoritative world server
    -> client

- and runs `client/scripts/test/phase14_journey.gd` as the client. That scene is
a real client (real autoloads, real transport, real intents); the only thing it
replaces is the keyboard. It registers and logs in through the service, selects
a character, joins with the session token (NO dev join), plays the journey
(courtyard, reactive pack, reward, mount, flight, castle transfer, moving
staircase, logout) and then reloads the character from the service to prove the
state survived.

The client can be either the project (`godot --path client <scene>`) or a
packaged build (`--client-exe path/to/HPMMO.exe`), which is what the launcher
starts. A packaged build cannot be pointed at another scene (the official export
templates are compiled with `disable_path_overrides=yes`), so the QA package's
main scene is the journey driver; see `docs/phase14-acceptance.md`.

Usage:
  python tests/phase14_journey.py [--client-exe PATH] [--seconds 900]
                                  [--out-dir DIR] [--keep-scene]
"""

import argparse
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER_DIR = os.path.dirname(HERE)
WORKSPACE = os.path.dirname(SERVER_DIR)
CLIENT_DIR = os.environ.get("HPMMO_CLIENT_DIR", os.path.join(WORKSPACE, "client"))
PG_ROOT = os.environ.get("HPMMO_PG_ROOT", os.path.join(WORKSPACE, "_tools", "pgsql"))
PG_DATA = os.environ.get("HPMMO_PG_DATA", os.path.join(os.path.dirname(PG_ROOT.rstrip("/\\")), "pgdata"))
PG_PORT = 55432
SERVICE = os.environ.get("HPMMO_SERVICE_EXE", os.path.join(SERVER_DIR, "services", "cpp", "build", "hpmmo_service.exe"))
GODOT = os.environ.get("HPMMO_GODOT", "godot")
SERVICE_TOKEN = "journey-token-%d" % int(time.time())
PASSWORD = "JourneyTest123"


def excluded_udp_ports():
    """Windows: netsh lists the UDP ranges reserved by the OS (Hyper-V, WSL,
    Docker). Binding inside one fails with ENet's 'couldn't create host'."""
    try:
        out = subprocess.run(["netsh", "int", "ipv4", "show", "excludedportrange", "protocol=udp"],
                             capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return set()
    ports = set()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
            try:
                start, end = int(parts[0]), int(parts[1])
            except ValueError:
                continue
            if end - start <= 1000:
                ports.update(range(start, end + 1))
    return ports


EXCLUDED_UDP = excluded_udp_ports()


def marker_cmd():
    if os.path.isfile(GODOT) and GODOT.lower().endswith("godot.exe"):
        console = GODOT[: -len("godot.exe")] + "godot_console.exe"
        if os.path.isfile(console):
            return console
    return GODOT


def free_port(kind=socket.SOCK_STREAM):
    """A port nothing is listening on. The kind matters: Windows keeps UDP port
    ranges excluded (Hyper-V/WSL), so a TCP-free port is not automatically
    UDP-bindable - the world server needs a UDP one."""
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def free_udp_port():
    for _ in range(20):
        candidate = free_port(socket.SOCK_DGRAM)
        if candidate not in EXCLUDED_UDP:
            return candidate
    return free_port(socket.SOCK_DGRAM)


def pg_tool(name):
    return os.path.join(PG_ROOT, "bin", name + ".exe" if os.name == "nt" else name)


def run(args, env=None, timeout=600, cwd=None):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                          env=env, cwd=cwd, errors="replace")


def wait_for(path, needle, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                if needle in handle.read():
                    return True
        except OSError:
            pass
        time.sleep(0.5)
    return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--client-exe", default="", help="packaged HPMMO.exe (launcher path)")
    parser.add_argument("--seconds", type=float, default=900.0)
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--keep-scene", action="store_true")
    parser.add_argument("--user", default="")
    args = parser.parse_args()
    out_dir = args.out_dir or os.path.join(HERE, "out", "phase14")
    os.makedirs(out_dir, exist_ok=True)

    password_file = os.path.join(HERE, ".pg-dev.pw")
    password = os.environ.get("HPMMO_PG_PASSWORD")
    if not password and os.path.isfile(password_file):
        password = open(password_file, encoding="utf-8").read().strip()
    if not password or not os.path.isfile(pg_tool("pg_ctl")) or not os.path.isfile(SERVICE):
        print("JOURNEY SKIP: needs PostgreSQL at %s and the built service at %s" % (PG_ROOT, SERVICE))
        return 2

    if run([pg_tool("pg_isready"), "-h", "127.0.0.1", "-p", str(PG_PORT)]).returncode != 0:
        # Not through the capturing helper: pg_ctl leaves the postgres daemon
        # holding the inherited pipe handles, so a captured-pipe run would block
        # until the server exits (it hung forever when the cluster was down).
        pg_log = open(os.path.join(PG_DATA, "pg.log"), "ab")
        started = subprocess.run([pg_tool("pg_ctl"), "-D", PG_DATA, "-l", os.path.join(PG_DATA, "pg.log"),
                                  "-o", "-p %d -c listen_addresses=127.0.0.1" % PG_PORT, "-w", "start"],
                                 stdout=pg_log, stderr=pg_log, timeout=120)
        pg_log.close()
        if started.returncode != 0:
            print("JOURNEY SKIP: PostgreSQL did not start (rc %d)" % started.returncode)
            return 2

    db_name = "hpmmo_journey_%d" % int(time.time())
    pg_env = dict(os.environ, PGPASSWORD=password)
    run([pg_tool("psql"), "-h", "127.0.0.1", "-p", str(PG_PORT), "-U", "hpmmo", "-d", "postgres",
         "-tAc", "CREATE DATABASE %s OWNER hpmmo;" % db_name], env=pg_env)
    dsn = "postgresql://hpmmo:%s@127.0.0.1:%d/%s" % (password, PG_PORT, db_name)
    service_env = dict(os.environ, DATABASE_URL=dsn,
                       HPMMO_MIGRATIONS_DIR=os.path.join(SERVER_DIR, "db", "migrations"))
    migrated = run([SERVICE, "migrate"], env=service_env, cwd=os.path.join(SERVER_DIR, "services", "cpp"))
    if migrated.returncode != 0:
        print("JOURNEY FAIL: migrate failed: %s" % (migrated.stdout[-400:] + migrated.stderr[-400:]))
        return 1

    api_port = free_port()
    world_port = free_udp_port()
    admin_port = free_port()
    service_env.update(HPMMO_HTTP_PORT=str(api_port), HPMMO_SERVICE_TOKEN=SERVICE_TOKEN,
                       HPMMO_BIND="127.0.0.1", HPMMO_ARGON2_M="8192")
    service_log_path = os.path.join(out_dir, "journey-service.log")
    service_log = open(service_log_path, "wb")
    service = subprocess.Popen([SERVICE, "serve"], stdout=service_log, stderr=subprocess.STDOUT,
                               env=service_env, cwd=os.path.join(SERVER_DIR, "services", "cpp"))
    world = None
    try:
        ready = False
        for _ in range(240):
            if service.poll() is not None:
                break
            try:
                with urllib.request.urlopen("http://127.0.0.1:%d/api/ready" % api_port, timeout=2) as response:
                    ready = response.status == 200
            except Exception:
                ready = False
            if ready:
                break
            time.sleep(0.5)
        if not ready:
            print("JOURNEY FAIL: the account service never became ready (see %s)" % service_log_path)
            return 1

        world_dir = os.path.join(SERVER_DIR, "world")
        run([marker_cmd(), "--headless", "--path", world_dir, "--editor", "--import", "--quit"], timeout=900)

        world_env = dict(os.environ, HPMMO_WORLD_PORT=str(world_port), HPMMO_WORLD_SEED="20261005",
                         HPMMO_API_URL="http://127.0.0.1:%d" % api_port, HPMMO_SERVICE_TOKEN=SERVICE_TOKEN,
                         HPMMO_ADMIN_PORT=str(admin_port), HPMMO_RELEASE="phase14-journey")
        world_env.pop("HPMMO_ALLOW_DEV_JOIN", None)
        world_log_path = os.path.join(out_dir, "journey-world.log")
        world_log = open(world_log_path, "wb")
        world = subprocess.Popen([marker_cmd(), "--headless", "--path", world_dir,
                                  "res://server/world_server.tscn"],
                                 stdout=world_log, stderr=subprocess.STDOUT, env=world_env)
        if not wait_for(world_log_path, "listening on :%d" % world_port, 240):
            print("JOURNEY FAIL: the world server never listened (see %s)" % world_log_path)
            return 1

        user = args.user or "journey_%d" % (int(time.time()) % 100000)
        transcript = os.path.join(out_dir, "journey-%s.jsonl" % user)
        client_args = [f"--ip=127.0.0.1", f"--port={world_port}", f"--api=http://127.0.0.1:{api_port}",
                       f"--user={user}", f"--pass={PASSWORD}", f"--seconds={int(args.seconds)}",
                       f"--out={transcript}"]
        if args.keep_scene:
            client_args.append("--keep-scene")
        # Headless on purpose: a measurement must never put a game window on the
        # owner's desktop. user:// is the run's own folder too, so settings and
        # saves cannot land in the shared %APPDATA% profile.
        user_dir = os.path.join(out_dir, "user")
        os.makedirs(user_dir, exist_ok=True)
        run_env = dict(os.environ)
        run_env["HPMMO_USER_DIR"] = user_dir
        if args.client_exe:
            # A packaged Godot binary takes its user arguments after `--`; without
            # the separator the driver would never see --ip/--user/--out.
            command = [args.client_exe, "--headless", "--"] + client_args
            cwd = os.path.dirname(os.path.abspath(args.client_exe))
        else:
            command = [marker_cmd(), "--headless", "--path", CLIENT_DIR,
                       "res://scenes/test/phase14_journey.tscn", "--"] + client_args
            cwd = CLIENT_DIR
        client_log_path = os.path.join(out_dir, "journey-client.log")
        print("[journey] running %s" % (os.path.basename(command[0])))
        with open(client_log_path, "wb") as client_log:
            client = subprocess.run(command, stdout=client_log, stderr=subprocess.STDOUT,
                                    env=run_env, cwd=cwd, timeout=args.seconds + 300)
        text = open(client_log_path, "r", encoding="utf-8", errors="replace").read()
        for line in text.splitlines():
            if line.startswith("[Journey]") or line.startswith("JOURNEY"):
                print("      | " + line)
        print("JOURNEY RESULT: exit=%d log=%s" % (client.returncode, client_log_path))
        return client.returncode
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
             "-tAc", "DROP DATABASE IF EXISTS %s WITH (FORCE);" % db_name], env=pg_env)


if __name__ == "__main__":
    sys.exit(main())
