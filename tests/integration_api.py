#!/usr/bin/env python3
"""Phase 4 integration tests for the C++ service + PostgreSQL.

Self-contained: starts the local PostgreSQL cluster (if needed), creates a
throwaway database, migrates it, boots hpmmo_service.exe, and exercises the
plan.md Phase 4 exit checks end to end:

  register / login / create / save / RESTART / load-back (state survives)
  cross-account denial (a second account cannot load or save another's character)
  reward + trade idempotency (replayed op_id cannot duplicate items)
  trade exactness (sender debited in the same transaction; overdraw rejected)
  one-time game tickets (single use)
  session expiry/revocation paths (logout invalidates)
  stale revision rejection
  PostgreSQL outage => explicit 503 unavailable (never a fallback backend),
  and recovery once the database returns

Env overrides:
  HPMMO_PG_ROOT      PostgreSQL binaries dir (default: workspace _tools/pgsql)
  HPMMO_PG_PASSWORD  dev cluster password (default: tests/.pg-dev.pw)
  HPMMO_SERVICE_EXE  service binary (default: services/cpp/build/hpmmo_service.exe)

Exit code 0 = all checks passed.
"""

import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.dirname(HERE)
WORKSPACE = os.path.dirname(SERVER)
PG_ROOT = os.environ.get("HPMMO_PG_ROOT", os.path.join(WORKSPACE, "_tools", "pgsql"))
PG_BIN = os.path.join(PG_ROOT, "bin")
PG_DATA = os.path.join(WORKSPACE, "_tools", "pgdata")
PG_PORT = 55432
MIGRATIONS = os.path.join(SERVER, "db", "migrations")
SERVICE = os.environ.get("HPMMO_SERVICE_EXE", os.path.join(SERVER, "services", "cpp", "build", "hpmmo_service.exe"))
SERVICE_TOKEN = "ci-service-token-" + secrets.token_hex(8)

failures = []
checks = 0
proc = None
_log = None


def check(cond, message):
    global checks
    checks += 1
    if cond:
        print("PASS: " + message)
    else:
        failures.append(message)
        print("FAIL: " + message)


def pg_password():
    pw_file = os.path.join(HERE, ".pg-dev.pw")
    if os.path.exists(pw_file):
        return open(pw_file, encoding="utf-8").read().strip()
    return os.environ.get("HPMMO_PG_PASSWORD", "")


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=60, **kw)


def pg_ready():
    exe = os.path.join(PG_BIN, "pg_isready.exe")
    if not os.path.exists(exe):
        return False
    try:
        r = subprocess.run([exe, "-h", "127.0.0.1", "-p", str(PG_PORT), "-q"], timeout=20)
        return r.returncode == 0
    except OSError:
        return False


def pg_start():
    if pg_ready():
        return True
    log = open(os.path.join(WORKSPACE, "_tools", "pg-ci.log"), "ab")
    subprocess.Popen(
        [os.path.join(PG_BIN, "pg_ctl.exe"), "-D", PG_DATA, "-l",
         os.path.join(WORKSPACE, "_tools", "pg.log"), "-o",
         f"-p {PG_PORT} -c listen_addresses=127.0.0.1", "-w", "start"],
        stdout=log, stderr=log)
    for _ in range(40):
        if pg_ready():
            return True
        time.sleep(0.5)
    return False


def pg_stop():
    log = open(os.path.join(WORKSPACE, "_tools", "pg-ci.log"), "ab")
    subprocess.Popen([os.path.join(PG_BIN, "pg_ctl.exe"), "-D", PG_DATA, "-m", "fast", "-w", "stop"],
                     stdout=log, stderr=log)
    for _ in range(40):
        if not pg_ready():
            return True
        time.sleep(0.5)
    return False


def psql(db, sql):
    env = dict(os.environ, PGPASSWORD=pg_password())
    return run([os.path.join(PG_BIN, "psql.exe"), "-h", "127.0.0.1", "-p", str(PG_PORT),
                "-U", "hpmmo", "-d", db, "-tAc", sql], env=env)


def dsn(db):
    return f"postgresql://hpmmo:{pg_password()}@127.0.0.1:{PG_PORT}/{db}"


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def start_service(port, database):
    global proc, _log
    env = dict(os.environ)
    env["DATABASE_URL"] = dsn(database)
    env["HPMMO_MIGRATIONS_DIR"] = MIGRATIONS
    env["HPMMO_HTTP_PORT"] = str(port)
    env["HPMMO_SERVICE_TOKEN"] = SERVICE_TOKEN
    env["HPMMO_ARGON2_M"] = "8192"  # fast hashing for CI; production uses the default 64 MiB
    _log = open(os.path.join(tempfile.gettempdir(), "hpmmo-service-ci.log"), "ab")
    proc = subprocess.Popen([SERVICE, "serve"], env=env, stdout=_log, stderr=subprocess.STDOUT)
    for _ in range(60):
        try:
            status, _body = http(port, "GET", "/api/health")
            if status == 200:
                return True
        except Exception:
            time.sleep(0.25)
    return False


def stop_service():
    global proc
    if proc and proc.poll() is None:
        proc.kill()
        proc.wait(timeout=10)
    proc = None


def http(port, method, path, body=None, token=None, service_token=None):
    url = f"http://127.0.0.1:{port}{path}"
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    if service_token:
        headers["X-Service-Token"] = service_token
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, json.loads(exc.read() or b"{}")
        except Exception:
            return exc.code, {}


def main():
    pw = pg_password()
    if not pw:
        print("SKIP: no PostgreSQL password (tests/.pg-dev.pw or HPMMO_PG_PASSWORD)")
        return 2
    if not os.path.exists(SERVICE):
        print("SKIP: service binary not built at " + SERVICE)
        return 2
    if not os.path.exists(os.path.join(PG_BIN, "pg_isready.exe")):
        print("SKIP: PostgreSQL binaries not found under " + PG_ROOT)
        print("      set HPMMO_PG_ROOT to a PostgreSQL 17 binaries tree")
        print("      (EDB 'binaries only' zip extracted; see server README 'Database (development)')")
        return 2

    db_name = "hpmmo_ci_" + secrets.token_hex(4)
    port = free_port()
    try:
        check(pg_start(), "PostgreSQL cluster starts")
        if failures:
            return finish()
        r = psql("postgres", f"CREATE DATABASE {db_name} OWNER hpmmo;")
        check(r.returncode == 0, "throwaway test database created")

        # migrate first (runs as a one-shot process), then serve from it.
        r = run([SERVICE, "migrate"], env=dict(os.environ, DATABASE_URL=dsn(db_name),
                                               HPMMO_MIGRATIONS_DIR=MIGRATIONS))
        check(r.returncode == 0, "migrations apply cleanly (schema at required version)")

        check(start_service(port, db_name), "service boots and answers /api/health")

        status, body = http(port, "GET", "/api/ready")
        check(status == 200 and body.get("status") == "ready" and body.get("db") == "postgresql",
              "readiness reports ready with postgresql + schema level")

        # --- accounts & sessions -------------------------------------------------
        status, body = http(port, "POST", "/api/register", {"username": "alice", "password": "alicepass1"})
        check(status == 200 and body.get("success"), "register alice")
        alice_id = body.get("account_id")
        status, body = http(port, "POST", "/api/register", {"username": "bob", "password": "bobpass123"})
        check(status == 200, "register bob")
        bob_id = body.get("account_id")
        status, body = http(port, "POST", "/api/register", {"username": "alice", "password": "other999"})
        check(status == 409, "duplicate username rejected")
        status, body = http(port, "POST", "/api/register", {"username": "cc", "password": "short1"})
        check(status == 400, "weak password/username rejected")
        status, body = http(port, "POST", "/api/login", {"username": "alice", "password": "wrongpass1"})
        check(status == 401, "wrong password rejected")
        status, body = http(port, "POST", "/api/login", {"username": "alice", "password": "alicepass1"})
        check(status == 200 and body.get("token"), "login issues a session token")
        alice_tok = body["token"]
        status, body = http(port, "POST", "/api/login", {"username": "bob", "password": "bobpass123"})
        bob_tok = body["token"]

        # --- characters & ownership ----------------------------------------------
        status, body = http(port, "POST", "/api/characters/create", {"name": "Alice W", "house": "Gryffindor"}, token=alice_tok)
        check(status == 200 and body.get("character", {}).get("id"), "alice creates a character")
        alice_char = body["character"]["id"]
        status, body = http(port, "POST", "/api/characters/create", {"name": "Bob S", "house": "Slytherin"}, token=bob_tok)
        bob_char = body["character"]["id"]
        check(status == 200, "bob creates a character")
        status, body = http(port, "POST", "/api/characters/list", {}, token=bob_tok)
        check(status == 200 and len(body.get("characters", [])) == 1, "character list is scoped to the account")

        status, body = http(port, "POST", "/api/characters/load", {"character_id": alice_char}, token=bob_tok)
        check(status == 404, "bob cannot load alice's character (404, no disclosure)")
        status, body = http(port, "POST", "/api/characters/save",
                            {"character_id": alice_char, "level": 99}, token=bob_tok)
        check(status == 404, "bob cannot save alice's character")
        status, body = http(port, "POST", "/api/characters/load", {"character_id": alice_char})
        check(status == 401, "no session token -> 401")

        # --- save / restart / load back (state survives) -------------------------
        status, body = http(port, "POST", "/api/characters/save",
                            {"character_id": alice_char, "level": 3, "exp": 120, "galleons": 777,
                             "current_hp": 421, "pos": [1.5, 0.5, -8.25], "map_id": "grounds",
                             "inventory": [{"id": "potion_health", "amount": 3, "tier": 0},
                                           {"id": "wand_hawthorn", "amount": 1, "tier": 2}]},
                            token=alice_tok)
        check(status == 200 and body.get("revision", 0) >= 2, "save accepts a validated full state")
        rev = body.get("revision")

        stop_service()
        check(start_service(port, db_name), "service restarts against the same database")
        status, body = http(port, "POST", "/api/characters/load", {"character_id": alice_char}, token=alice_tok)
        char = body.get("character", {})
        check(status == 200 and char.get("level") == 3 and char.get("galleons") == 777
              and abs(char.get("pos", [0, 0, 0])[2] + 8.25) < 0.001
              and any(i["id"] == "wand_hawthorn" and i["tier"] == 2 for i in char.get("inventory", [])),
              "state survives the service restart (level, galleons, pos, tiered item)")

        status, body = http(port, "POST", "/api/characters/save",
                            {"character_id": alice_char, "base_revision": rev - 2, "level": 3},
                            token=alice_tok)
        check(status == 409, "stale base_revision is rejected (409)")
        status, body = http(port, "POST", "/api/characters/save",
                            {"character_id": alice_char, "base_revision": rev, "level": 4}, token=alice_tok)
        check(status == 200, "current base_revision accepted")

        # --- rewards: exactly-once -------------------------------------------------
        op = "ci-reward-" + secrets.token_hex(4)
        reward = {"op_id": op, "character_id": alice_char, "exp": 100, "galleons": 50,
                  "items": [{"id": "potion_mana", "amount": 2, "tier": 0}]}
        status, body = http(port, "POST", "/api/reward", reward)
        check(status == 403, "reward without the service token is refused")
        status, body = http(port, "POST", "/api/reward", reward, service_token=SERVICE_TOKEN)
        check(status == 200 and body.get("success"), "reward applies with the service token")
        status, body = http(port, "POST", "/api/reward", reward, service_token=SERVICE_TOKEN)
        check(status == 200 and body.get("replayed") is True, "replaying the same op_id returns the recorded result")
        status, body = http(port, "POST", "/api/characters/load", {"character_id": alice_char}, token=alice_tok)
        char = body["character"]
        mana_count = sum(i["amount"] for i in char["inventory"] if i["id"] == "potion_mana")
        check(char["galleons"] == 777 + 50 and mana_count == 2,
              "replayed reward did not duplicate items or currency (exactly once)")

        # --- trades: atomic, validated, idempotent ---------------------------------
        op2 = "ci-trade-" + secrets.token_hex(4)
        trade = {"op_id": op2, "from_id": alice_char, "to_id": bob_char,
                 "offer": {"galleons": 100, "items": [{"id": "wand_hawthorn", "amount": 1, "tier": 2}]},
                 "request": {"galleons": 30, "items": []}}
        status, body = http(port, "POST", "/api/trade", trade, service_token=SERVICE_TOKEN)
        check(status == 200 and body.get("success"), "trade executes")
        status, body = http(port, "POST", "/api/trade", trade, service_token=SERVICE_TOKEN)
        check(status == 200 and body.get("replayed") is True, "replayed trade op is a no-op")
        status, la = http(port, "POST", "/api/characters/load", {"character_id": alice_char}, token=alice_tok)
        status, lb = http(port, "POST", "/api/characters/load", {"character_id": bob_char}, token=bob_tok)
        alice, bobc = la["character"], lb["character"]
        alice_has_wand = any(i["id"] == "wand_hawthorn" for i in alice["inventory"])
        bob_has_wand = any(i["id"] == "wand_hawthorn" and i["tier"] == 2 for i in bobc["inventory"])
        check(not alice_has_wand and bob_has_wand, "sender debited and receiver credited in one trade")
        check(alice["galleons"] == 777 + 50 - 100 + 30 and bobc["galleons"] == 500 - 30 + 100,
              "galleons moved exactly once despite the replay")

        over = {"op_id": "ci-over-" + secrets.token_hex(4), "from_id": alice_char, "to_id": bob_char,
                "offer": {"galleons": 0, "items": [{"id": "wand_hawthorn", "amount": 9, "tier": 2}]},
                "request": {"galleons": 0, "items": []}}
        status, body = http(port, "POST", "/api/trade", over, service_token=SERVICE_TOKEN)
        check(status == 400, "overdraw offer rejected (ownership validated)")
        selftrade = dict(over, op_id="ci-self-" + secrets.token_hex(4), to_id=alice_char,
                         offer={"galleons": 0, "items": []})
        status, body = http(port, "POST", "/api/trade", selftrade, service_token=SERVICE_TOKEN)
        check(status == 400, "self-trade rejected")
        neg = dict(over, op_id="ci-neg-" + secrets.token_hex(4),
                   offer={"galleons": -50, "items": []}, request={"galleons": 0, "items": []})
        status, body = http(port, "POST", "/api/trade", neg, service_token=SERVICE_TOKEN)
        check(status == 400, "negative galleon offer rejected")

        # --- inventory capacity is enforced on the save path too --------------------
        many = [{"id": f"ci_kind_{i}", "amount": 1, "tier": 0} for i in range(41)]
        status, body = http(port, "POST", "/api/characters/save",
                            {"character_id": bob_char, "inventory": many}, token=bob_tok)
        check(status == 400, "save rejecting a 41-kind inventory (capacity enforced on save, not just trade)")
        forty = many[:40]
        status, body = http(port, "POST", "/api/characters/save",
                            {"character_id": bob_char, "inventory": forty}, token=bob_tok)
        check(status == 200, "save accepts a 40-kind inventory at the cap")

        # --- tickets: one-time handoff --------------------------------------------
        status, body = http(port, "POST", "/api/game-ticket", {"character_id": alice_char}, token=alice_tok)
        check(status == 200 and body.get("ticket"), "game ticket issued to the launcher session")
        ticket = body["ticket"]
        status, body = http(port, "POST", "/api/ticket/redeem", {"ticket": ticket})
        check(status == 200 and body.get("token") and body.get("character_id") == alice_char,
              "ticket redeems into a game session bound to the character")
        game_tok = body.get("token")
        status, body = http(port, "POST", "/api/ticket/redeem", {"ticket": ticket})
        check(status == 410, "ticket cannot be redeemed twice")
        # Regression pin (verification blocker): the launcher may issue the
        # ticket BEFORE character selection; character_id must be optional.
        status, body = http(port, "POST", "/api/game-ticket", {}, token=alice_tok)
        check(status == 200 and body.get("ticket"), "ticket without character_id succeeds (NULL binding)")
        unbound = body.get("ticket")
        status, body = http(port, "POST", "/api/ticket/redeem", {"ticket": unbound})
        check(status == 200 and body.get("character_id", -1) == 0, "unbound ticket redeems without a character")
        status, body = http(port, "POST", "/api/game-ticket", {"character_id": "1"}, token=alice_tok)
        check(status == 400, "non-integer character_id is rejected")
        status, body = http(port, "POST", "/api/characters/load", {"character_id": alice_char}, token=game_tok)
        check(status == 200, "game session can load its character")

        # --- logout revocation ------------------------------------------------------
        status, body = http(port, "POST", "/api/logout", {}, token=game_tok)
        check(status == 200, "logout revokes the session")
        status, body = http(port, "POST", "/api/characters/load", {"character_id": alice_char}, token=game_tok)
        check(status == 401, "revoked session is rejected")

        # --- PostgreSQL outage => explicit unavailable, then recovery --------------
        check(pg_stop(), "PostgreSQL stopped for the outage scenario")
        status, body = http(port, "GET", "/api/ready")
        check(status == 503 and body.get("status") == "unavailable",
              "readiness reports unavailable during the outage")
        status, body = http(port, "POST", "/api/characters/load", {"character_id": alice_char}, token=alice_tok)
        check(status == 503, "data endpoint returns 503 during the outage (no fallback backend)")
        check(pg_start(), "PostgreSQL restarted")
        recovered = False
        for _ in range(20):
            status, body = http(port, "GET", "/api/ready")
            if status == 200:
                recovered = True
                break
            time.sleep(0.5)
        check(recovered, "service recovers readiness once the database returns")

    finally:
        stop_service()
        try:
            psql("postgres", f"DROP DATABASE IF EXISTS {db_name} WITH (FORCE);")
        except Exception:
            pass
    return finish()


def finish():
    print(f"INTEGRATION RESULT: {checks} checks, {len(failures)} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
