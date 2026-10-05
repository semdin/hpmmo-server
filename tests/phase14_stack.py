#!/usr/bin/env python3
"""Phase 14 test stack: PostgreSQL + C++ service + authoritative world server.

Brought up and torn down as one unit, exactly the production layout (the service
owns accounts and characters; the world server is the only writer of live state).
Shared by `phase14_journey.py`-style drivers and the launcher-path driver, so
both exercise the same stack. Small and dependency-free on purpose.
"""

import os
import socket
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER_DIR = os.path.dirname(HERE)
WORKSPACE = os.path.dirname(SERVER_DIR)
CLIENT_DIR = os.environ.get("HPMMO_CLIENT_DIR", os.path.join(WORKSPACE, "client"))
PG_ROOT = os.environ.get("HPMMO_PG_ROOT", os.path.join(WORKSPACE, "_tools", "pgsql"))
PG_DATA = os.environ.get("HPMMO_PG_DATA", os.path.join(os.path.dirname(PG_ROOT.rstrip("/\\")), "pgdata"))
PG_PORT = 55432
SERVICE = os.environ.get("HPMMO_SERVICE_EXE",
                         os.path.join(SERVER_DIR, "services", "cpp", "build", "hpmmo_service.exe"))
GODOT = os.environ.get("HPMMO_GODOT", "godot")


def marker_cmd():
    if os.path.isfile(GODOT) and GODOT.lower().endswith("godot.exe"):
        console = GODOT[: -len("godot.exe")] + "godot_console.exe"
        if os.path.isfile(console):
            return console
    return GODOT


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


def excluded_udp_ports():
    """Windows reserves UDP ranges for Hyper-V/WSL/Docker; binding inside one
    fails with ENet's 'couldn't create host'. A TCP-free port is therefore not
    automatically UDP-bindable."""
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


def free_port(kind=socket.SOCK_STREAM):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def free_udp_port():
    for _ in range(30):
        candidate = free_port(socket.SOCK_DGRAM)
        if candidate not in EXCLUDED_UDP:
            return candidate
    return free_port(socket.SOCK_DGRAM)


def pg_password():
    password = os.environ.get("HPMMO_PG_PASSWORD")
    path = os.path.join(HERE, ".pg-dev.pw")
    if not password and os.path.isfile(path):
        password = open(path, encoding="utf-8").read().strip()
    return password or ""


class Stack:
    """The production stack, up or down as one unit."""

    def __init__(self, out_dir, seed="20261005", service_token=None, api_port=0):
        self.out_dir = out_dir
        self.seed = seed
        self.service_token = service_token or "phase14-token-%d" % int(time.time())
        self.service = None
        self.world = None
        self.service_log = None
        self.db_name = "hpmmo_phase14_%d" % int(time.time())
        self.password = pg_password()
        self.api_port = api_port      # fixed when a caller needs a known port
        self.world_port = 0
        self.admin_port = 0
        self.pg_env = {}
        self.world_log_path = ""

    def start(self):
        if not self.password or not os.path.isfile(pg_tool("pg_ctl")) or not os.path.isfile(SERVICE):
            raise RuntimeError("needs PostgreSQL at %s and the built service at %s" % (PG_ROOT, SERVICE))
        if run([pg_tool("pg_isready"), "-h", "127.0.0.1", "-p", str(PG_PORT)]).returncode != 0:
            started = run([pg_tool("pg_ctl"), "-D", PG_DATA, "-l", os.path.join(PG_DATA, "pg.log"),
                           "-o", "-p %d -c listen_addresses=127.0.0.1" % PG_PORT, "-w", "start"])
            if started.returncode != 0:
                raise RuntimeError("PostgreSQL did not start: %s" % started.stdout[-300:])
        self.pg_env = dict(os.environ, PGPASSWORD=self.password)
        run([pg_tool("psql"), "-h", "127.0.0.1", "-p", str(PG_PORT), "-U", "hpmmo", "-d", "postgres",
             "-tAc", "CREATE DATABASE %s OWNER hpmmo;" % self.db_name], env=self.pg_env)
        dsn = "postgresql://hpmmo:%s@127.0.0.1:%d/%s" % (self.password, PG_PORT, self.db_name)
        service_env = dict(os.environ, DATABASE_URL=dsn,
                           HPMMO_MIGRATIONS_DIR=os.path.join(SERVER_DIR, "db", "migrations"))
        migrated = run([SERVICE, "migrate"], env=service_env, cwd=os.path.join(SERVER_DIR, "services", "cpp"))
        if migrated.returncode != 0:
            raise RuntimeError("migrate failed: %s" % (migrated.stdout[-400:] + migrated.stderr[-400:]))

        if not self.api_port:
            self.api_port = free_port()
        self.world_port = free_udp_port()
        self.admin_port = free_port()
        service_env.update(HPMMO_HTTP_PORT=str(self.api_port), HPMMO_SERVICE_TOKEN=self.service_token,
                           HPMMO_BIND="127.0.0.1", HPMMO_ARGON2_M="8192")
        service_log_path = os.path.join(self.out_dir, "stack-service.log")
        self.service_log = open(service_log_path, "wb")
        self.service = subprocess.Popen([SERVICE, "serve"], stdout=self.service_log,
                                        stderr=subprocess.STDOUT, env=service_env,
                                        cwd=os.path.join(SERVER_DIR, "services", "cpp"))
        ready = False
        for _ in range(240):
            if self.service.poll() is not None:
                break
            try:
                with urllib.request.urlopen("http://127.0.0.1:%d/api/ready" % self.api_port, timeout=2) as response:
                    ready = response.status == 200
            except Exception:
                ready = False
            if ready:
                break
            time.sleep(0.5)
        if not ready:
            raise RuntimeError("the account service never became ready (see %s)" % service_log_path)

        world_dir = os.path.join(SERVER_DIR, "world")
        run([marker_cmd(), "--headless", "--path", world_dir, "--editor", "--import", "--quit"], timeout=900)
        world_env = dict(os.environ, HPMMO_WORLD_PORT=str(self.world_port), HPMMO_WORLD_SEED=self.seed,
                         HPMMO_API_URL="http://127.0.0.1:%d" % self.api_port,
                         HPMMO_SERVICE_TOKEN=self.service_token,
                         HPMMO_ADMIN_PORT=str(self.admin_port), HPMMO_RELEASE="phase14")
        world_env.pop("HPMMO_ALLOW_DEV_JOIN", None)
        self.world_log_path = os.path.join(self.out_dir, "stack-world.log")
        world_log = open(self.world_log_path, "wb")
        self.world = subprocess.Popen([marker_cmd(), "--headless", "--path", world_dir,
                                       "res://server/world_server.tscn"],
                                      stdout=world_log, stderr=subprocess.STDOUT, env=world_env)
        if not wait_for(self.world_log_path, "listening on :%d" % self.world_port, 240):
            raise RuntimeError("the world server never listened (see %s)" % self.world_log_path)
        return self

    def stop(self):
        if self.world is not None and self.world.poll() is None:
            self.world.terminate()
            try:
                self.world.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.world.kill()
        if self.service is not None and self.service.poll() is None:
            self.service.terminate()
            try:
                self.service.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.service.kill()
        if self.service_log is not None:
            self.service_log.close()
        if self.pg_env:
            run([pg_tool("psql"), "-h", "127.0.0.1", "-p", str(PG_PORT), "-U", "hpmmo", "-d", "postgres",
                 "-tAc", "DROP DATABASE IF EXISTS %s WITH (FORCE);" % self.db_name], env=self.pg_env)


if __name__ == "__main__":
    out = os.path.join(HERE, "out", "phase14")
    os.makedirs(out, exist_ok=True)
    stack = Stack(out)
    try:
        stack.start()
        print("STACK OK api=%d world=%d admin=%d" % (stack.api_port, stack.world_port, stack.admin_port))
    finally:
        stack.stop()
    sys.exit(0)
