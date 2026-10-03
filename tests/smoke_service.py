#!/usr/bin/env python3
"""HPMMO server smoke test.

Boots services/db_service.py against a TEMP sqlite database (no PostgreSQL, no
real data) and exercises the current API surface end to end:
  /api/health, register, login, character create/load/save,
  the save contract (character_id required), and the Phase 1 trade disable.

Exits non-zero on any failure. Run via `dev.ps1 test` or directly:
  python tests/smoke_service.py
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVICE = os.path.join(HERE, "..", "services", "db_service.py")

failures = []


def check(condition, message):
    if condition:
        print("PASS: " + message)
    else:
        failures.append(message)
        print("FAIL: " + message)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def call(port, method, path, payload=None):
    url = f"http://127.0.0.1:{port}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, json.loads(exc.read() or b"{}")
        except Exception:
            return exc.code, {}


def main():
    tmp = tempfile.mkdtemp(prefix="hpmmo-smoke-")
    port = free_port()
    env = os.environ.copy()
    env["DB_PORT"] = str(port)
    env["DATABASE_URL"] = ""  # force the sqlite path; no PostgreSQL in the smoke
    env["HPMMO_SQLITE_PATH"] = os.path.join(tmp, "smoke.db")

    proc = subprocess.Popen([sys.executable, os.path.abspath(SERVICE)], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        ready = False
        for _ in range(50):
            if proc.poll() is not None:
                break
            try:
                status, body = call(port, "GET", "/api/health")
                if status == 200:
                    ready = True
                    break
            except Exception:
                time.sleep(0.2)
        check(ready, "service boots and answers /api/health")
        if not ready:
            out = proc.stdout.read() if proc.stdout else ""
            print(out[-2000:])
            return finish(tmp, proc)

        status, body = call(port, "GET", "/api/health")
        check(status == 200 and body.get("status") == "ok", "health reports ok")
        check(os.path.exists(env["HPMMO_SQLITE_PATH"]), "sqlite file created at HPMMO_SQLITE_PATH")

        name = f"smoke{port}"
        status, body = call(port, "POST", "/api/register", {"username": name, "password": "smoketest1"})
        check(status == 200 and body.get("success"), "register succeeds")
        account_id = body.get("account_id")

        status, body = call(port, "POST", "/api/login", {"username": name, "password": "smoketest1"})
        check(status == 200 and body.get("success") and body.get("account_id") == account_id,
              "login returns the account")

        status, body = call(port, "POST", "/api/characters/create",
                            {"account_id": account_id, "name": f"Smoke{port}", "house": "Gryffindor"})
        check(status == 200 and body.get("success"), "character create succeeds")
        char = body.get("character", {})
        char_id = char.get("id")
        check(isinstance(char_id, int) and char_id > 0, "created character has an id")
        check(isinstance(char.get("inventory"), list) and char["inventory"],
              "starter inventory present")

        status, body = call(port, "POST", "/api/characters/load", {"character_id": char_id})
        check(status == 200 and body.get("character", {}).get("id") == char_id, "character load round-trips")

        status, body = call(port, "POST", "/api/characters/save",
                            {"character_id": char_id, "level": 2, "pos": [1.0, 0.5, 5.0]})
        check(status == 200 and body.get("success"), "save with character_id succeeds")

        # Contract pin: the game currently posts the load-shaped dict keyed 'id'.
        status, body = call(port, "POST", "/api/characters/save", {"id": char_id, "level": 3})
        check(status == 400, "save without character_id is rejected (400) - client key contract pin")

        status, body = call(port, "POST", "/api/trade",
                            {"player1_id": char_id, "player2_id": char_id})
        check(status == 503, "trade endpoint stays disabled (503) until the Phase 4 rewrite")

        status, body = call(port, "POST", "/api/nonexistent", {})
        check(status == 404, "unknown route returns 404")

    finally:
        return finish(tmp, proc)


def finish(tmp, proc):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"SMOKE RESULT: {len(failures)} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
