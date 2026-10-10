#!/usr/bin/env python3
"""persistence integration tests for the C++ service + PostgreSQL.

Self-contained: starts the local PostgreSQL cluster (if needed), creates a
throwaway database, migrates it, boots hpmmo_service.exe, and exercises the
exit checks end to end:

  register / login / create / save / RESTART / load-back (state survives)
  cross-account denial (a second account cannot load or save another's character)
  reward + trade idempotency (replayed op_id cannot duplicate items)
  trade exactness (sender debited in the same transaction; overdraw rejected)
  one-time game tickets (single use)
  session expiry/revocation paths (logout invalidates)
  stale revision rejection
  service-token session introspection (launcher vs character-bound game sessions)
  world-server character access via the service token (ownership bypass) while
  bearer sessions keep the foreign-character 404
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
PG_DATA = os.environ.get("HPMMO_PG_DATA",
                         os.path.join(os.path.dirname(PG_ROOT.rstrip("/\\")), "pgdata"))
PG_LOG_DIR = os.path.dirname(PG_DATA)
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
    os.makedirs(PG_LOG_DIR, exist_ok=True)
    log = open(os.path.join(PG_LOG_DIR, "pg-ci.log"), "ab")
    subprocess.Popen(
        [os.path.join(PG_BIN, "pg_ctl.exe"), "-D", PG_DATA, "-l",
         os.path.join(PG_LOG_DIR, "pg.log"), "-o",
         f"-p {PG_PORT} -c listen_addresses=127.0.0.1", "-w", "start"],
        stdout=log, stderr=log)
    for _ in range(40):
        if pg_ready():
            return True
        time.sleep(0.5)
    return False


def pg_stop():
    log = open(os.path.join(PG_LOG_DIR, "pg-ci.log"), "ab")
    proc = subprocess.Popen([os.path.join(PG_BIN, "pg_ctl.exe"), "-D", PG_DATA, "-m", "fast", "-w", "stop"],
                            stdout=log, stderr=log)
    stopped = False
    for _ in range(40):
        if not pg_ready():
            stopped = True
            break
        time.sleep(0.5)
    if stopped:
        # `pg_ready` goes false as soon as the postmaster stops accepting
        # connections, while `pg_ctl -w` is still waiting for the process to
        # exit. Returning there let the next start race the dying postmaster,
        # whose inherited log-file handle made the new one fail with "the file
        # is being used by another process" (measured, and reproducible).
        # Waiting for the stop's pg_ctl is what makes the restart reliable.
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            pass
    log.close()
    return stopped


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
        check(status == 403, "bob cannot save alice's character")
        status, body = http(port, "POST", "/api/characters/load", {"character_id": alice_char})
        check(status == 401, "no session token -> 401")

        status, body = http(port, "POST", "/api/characters/save", {"character_id": alice_char, "galleons": 99999}, token=alice_tok)
        check(status == 403, "even the owning session cannot bypass world equipment validation")
        status, body = http(port, "POST", "/api/characters/load", {"character_id": alice_char}, token=alice_tok)
        starter = body["character"]
        check(len(starter["equipment"]) == 3 and starter["equipment_version"] == 1 and
              not any(i["id"] in ["wand_hawthorn", "robe_apprentice", "broom_nimbus2000"] for i in starter["inventory"]),
              "new characters start with a wand, robe and broom equipped once")

        # --- save / restart / load back (state survives) -------------------------
        status, body = http(port, "POST", "/api/characters/save",
                            {"character_id": alice_char, "level": 3, "exp": 120, "galleons": 777,
                             "equipment": {"main_hand":{"id":"wand_elder","tier":5.0}, "ring_left":{"id":"ring_apprentice","tier":0.0}, "ring_right":{"id":"ring_apprentice","tier":0}},
                             "equipment_version":1, "inventory_revision":8, "base_max_hp":580, "base_max_mana":350,
                             "current_hp": 421, "pos": [1.5, 0.5, -8.25], "map_id": "grounds",
                             "inventory": [{"id": "potion_health", "amount": 3, "tier": 0},
                                           {"id": "wand_hawthorn", "amount": 1, "tier": 2}]},
                            service_token=SERVICE_TOKEN)
        check(status == 200 and body.get("revision", 0) >= 2, "save accepts Godot JSON round-tripped whole-number equipment tiers")
        rev = body.get("revision")

        stop_service()
        check(start_service(port, db_name), "service restarts against the same database")
        status, body = http(port, "POST", "/api/characters/load", {"character_id": alice_char}, token=alice_tok)
        char = body.get("character", {})
        check(status == 200 and char.get("level") == 3 and char.get("galleons") == 777
              and abs(char.get("pos", [0, 0, 0])[2] + 8.25) < 0.001
              and any(i["id"] == "wand_hawthorn" and i["tier"] == 2 for i in char.get("inventory", [])),
              "state survives the service restart (level, galleons, pos, tiered item)")
        check(char["equipment"]["main_hand"] == {"id":"wand_elder","tier":5} and
              char["equipment"]["ring_left"] == char["equipment"]["ring_right"] and
              char["base_max_hp"] == 580 and char["base_max_mana"] == 350 and char["inventory_revision"] == 8,
              "equipment, two identical rings, base progression and inventory revision survive restart")

        status, body = http(port, "POST", "/api/characters/save",
                            {"character_id": alice_char, "base_revision": rev - 2, "level": 3},
                            service_token=SERVICE_TOKEN)
        check(status == 409, "stale base_revision is rejected (409)")
        status, body = http(port, "POST", "/api/characters/save",
                            {"character_id": alice_char, "base_revision": rev, "level": 4}, service_token=SERVICE_TOKEN)
        check(status == 200, "current base_revision accepted")

        # Equipment validation rejects the entire replacement, including currency.
        for invalid_tier in [0.5, -1.0, 10.0, "0", True]:
            status, invalid = http(port, "POST", "/api/characters/save",
                                  {"character_id":alice_char, "galleons":1,
                                   "equipment":{"feet":{"id":"boots_apprentice","tier":invalid_tier}},
                                   "inventory":[]}, service_token=SERVICE_TOKEN)
            check(status == 400, f"invalid equipment tier {invalid_tier!r} is rejected atomically")
        status, invalid = http(port, "POST", "/api/characters/save",
                              {"character_id":alice_char,"galleons":1,"equipment":{"feet":{"id":"boots_apprentice","tier":0}}},
                              service_token=SERVICE_TOKEN)
        check(status == 400, "equipment replacement without its bag is rejected")
        status, loaded = http(port,"POST","/api/characters/load",{"character_id":alice_char},token=alice_tok)
        check(loaded["character"]["galleons"] == 777 and loaded["character"]["equipment"] == char["equipment"],
              "rejected equipment save changes neither currency nor ownership")
        status, invalid = http(port,"POST","/api/trade",
                              {"op_id":"ci-equipped-"+secrets.token_hex(4),"from_id":alice_char,"to_id":bob_char,
                               "offer":{"items":[{"id":"wand_elder","amount":1,"tier":5}]},"request":{}},service_token=SERVICE_TOKEN)
        check(status == 400,"equipped wand is unavailable to trades")

        # A legacy sheet is migrated transactionally and the migration is replay-safe.
        legacy = psql(db_name, f"INSERT INTO characters(account_id,name,house,max_hp,max_mana,wand_tier) SELECT account_id,'Legacy CI','Gryffindor',660,400,5 FROM characters WHERE id={alice_char} RETURNING id")
        legacy_id = int(legacy.stdout.strip().splitlines()[0])
        seeded = psql(db_name, f"INSERT INTO character_items(character_id,item_id,amount,tier) VALUES ({legacy_id},'wand_hawthorn',2,2),({legacy_id},'wand_elder',1,7),({legacy_id},'robe_apprentice',1,0); SELECT initialize_character_equipment({legacy_id}); SELECT initialize_character_equipment({legacy_id});")
        check(seeded.returncode == 0,"legacy migration and replay execute successfully")
        status, legacy_sheet = http(port,"POST","/api/characters/load",{"character_id":legacy_id},service_token=SERVICE_TOKEN)
        legacy_char = legacy_sheet["character"]
        check(legacy_char["base_max_hp"] == 660 and legacy_char["max_hp"] == 710 and legacy_char["base_max_mana"] == 400,
              "migration records base resources once without bonus accumulation")
        check(legacy_char["equipment"] == {"main_hand":{"id":"wand_hawthorn","tier":5},"chest":{"id":"robe_apprentice","tier":0}}
              and sum(i["amount"] for i in legacy_char["inventory"]) == 2
              and any(i["id"] == "wand_elder" and i["tier"] == 7 for i in legacy_char["inventory"]),
              "migration preserves spare tiers and never invents a missing broom")

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
                            {"character_id": bob_char, "inventory": many}, service_token=SERVICE_TOKEN)
        check(status == 400, "save rejecting a 41-kind inventory (capacity enforced on save, not just trade)")
        forty = many[:40]
        status, body = http(port, "POST", "/api/characters/save",
                            {"character_id": bob_char, "inventory": forty}, service_token=SERVICE_TOKEN)
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

        # --- service-token session introspection (Authority world server) ------------
        schema_level = max(int(f[:4]) for f in os.listdir(MIGRATIONS) if f.endswith(".sql"))
        status, body = http(port, "GET", "/api/ready")
        check(status == 200 and body.get("schema") == schema_level,
              f"readiness reports schema level {schema_level} (all required migrations applied)")

        status, body = http(port, "POST", "/api/login", {"username": "alice", "password": "alicepass1"})
        check(status == 200 and body.get("token"), "launcher logs in again for introspection")
        launcher_tok = body["token"]
        status, body = http(port, "POST", "/api/session/introspect", {"token": launcher_tok},
                            service_token=SERVICE_TOKEN)
        check(status == 200 and body.get("success") and body.get("account_id") == alice_id
              and body.get("username") == "alice" and body.get("character_id") == 0
              and body.get("expires_in_seconds", 0) > 0 and launcher_tok not in json.dumps(body),
              "introspect maps a login session to its account (character_id 0, no token echo)")

        status, body = http(port, "POST", "/api/game-ticket", {"character_id": alice_char}, token=alice_tok)
        check(status == 200 and body.get("ticket"), "character-bound ticket issued for introspection")
        status, body = http(port, "POST", "/api/ticket/redeem", {"ticket": body["ticket"]})
        bound_tok = body.get("token")
        check(status == 200 and bound_tok, "character-bound ticket redeems for introspection")
        status, body = http(port, "POST", "/api/session/introspect", {"token": bound_tok},
                            service_token=SERVICE_TOKEN)
        check(status == 200 and body.get("account_id") == alice_id and body.get("character_id") == alice_char,
              "introspect returns the character bound to a redeemed game session")

        status, body = http(port, "POST", "/api/session/introspect", {"token": bound_tok}, token=alice_tok)
        check(status == 403, "introspect refuses a bearer session in place of the service token")
        status, body = http(port, "POST", "/api/session/introspect", {"token": launcher_tok})
        check(status == 403, "introspect without any service token header -> 403")
        status, body = http(port, "POST", "/api/session/introspect",
                            {"token": "bogus-" + secrets.token_hex(16)}, service_token=SERVICE_TOKEN)
        check(status == 404, "introspect unknown token -> 404")
        status, body = http(port, "POST", "/api/session/introspect", {"token": game_tok},
                            service_token=SERVICE_TOKEN)
        check(status == 404, "introspect revoked token -> 404 (indistinguishable from unknown)")
        status, body = http(port, "POST", "/api/session/introspect", {}, service_token=SERVICE_TOKEN)
        check(status == 400, "introspect missing token -> 400")
        status, body = http(port, "POST", "/api/session/introspect", {"token": 12345},
                            service_token=SERVICE_TOKEN)
        check(status == 400, "introspect malformed token -> 400")

        # --- service-token character access bypasses ownership ----------------------
        status, body = http(port, "POST", "/api/characters/load", {"character_id": bob_char}, token=alice_tok)
        check(status == 404, "bearer load of a foreign character still returns 404")
        status, body = http(port, "POST", "/api/characters/load", {"character_id": bob_char},
                            service_token=SERVICE_TOKEN)
        check(status == 200 and body.get("character", {}).get("id") == bob_char,
              "service-token load reads a character owned by a different account")

        status, body = http(port, "POST", "/api/characters/save", {"character_id": bob_char, "level": 7},
                            token=alice_tok)
        check(status == 403, "bearer sessions cannot save character gameplay state")
        status, body = http(port, "POST", "/api/characters/load", {"character_id": bob_char},
                            service_token=SERVICE_TOKEN)
        base_rev = body.get("character", {}).get("revision")
        status, body = http(port, "POST", "/api/characters/save",
                            {"character_id": bob_char, "level": 7, "galleons": 1234,
                             "base_revision": base_rev},
                            service_token=SERVICE_TOKEN)
        check(status == 200 and body.get("revision") == base_rev + 1,
              "service-token save updates a foreign character and bumps its revision")
        status, body = http(port, "POST", "/api/characters/load", {"character_id": bob_char}, service_token=SERVICE_TOKEN)
        check(status == 200 and body.get("character", {}).get("level") == 7
              and body.get("character", {}).get("galleons") == 1234,
              "the foreign-character save is visible to its owner")

        tampered = "tampered-" + secrets.token_hex(8)
        status, body = http(port, "POST", "/api/characters/load", {"character_id": bob_char},
                            service_token=tampered)
        check(status == 403, "tampered service token rejected on characters/load")
        status, body = http(port, "POST", "/api/characters/save", {"character_id": bob_char, "level": 1},
                            service_token=tampered)
        check(status == 403, "tampered service token rejected on characters/save")

        # --- PostgreSQL outage => explicit unavailable, then recovery --------------
        check(pg_stop(), "PostgreSQL stopped for the outage scenario")
        status, body = http(port, "GET", "/api/ready")
        check(status == 503 and body.get("status") == "unavailable",
              "readiness reports unavailable during the outage")
        status, body = http(port, "POST", "/api/characters/load", {"character_id": alice_char}, service_token=SERVICE_TOKEN)
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
