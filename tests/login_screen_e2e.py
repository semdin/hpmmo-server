#!/usr/bin/env python3
"""The game's login screen against the real stack (PostgreSQL + C++ service +
world server), including the deployment maintenance gate.

  1. register a fresh account through the login screen; it must log in, join
     the world and open character selection;
  2. write <state_dir>/maintenance.flag (what deploy/hpmmo_deploy.sh does when
     it announces an update): the same screen must refuse with the maintenance
     notice, and /api/status must report it;
  3. remove the flag: /api/status is ONLINE again.

Drives client/scenes/test/login_screen_e2e.tscn headless. Needs the dev
PostgreSQL cluster and the built service (see test_stack.py).
"""

import json
import os
import secrets
import shutil
import sys
import tempfile
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import test_stack  # noqa: E402

FAILURES = 0


def check(ok, what, detail=""):
    global FAILURES
    print("%s: %s" % ("PASS" if ok else "FAIL", what))
    if not ok:
        FAILURES += 1
        if detail:
            print("      " + detail[-1500:].replace("\n", "\n      "))


def status(api_port):
    with urllib.request.urlopen("http://127.0.0.1:%d/api/status" % api_port, timeout=5) as response:
        return json.loads(response.read())


def drive(stack, mode, user, password):
    env = dict(os.environ, HPMMO_API_URL="http://127.0.0.1:%d" % stack.api_port, LOGIN_E2E_MODE=mode,
               LOGIN_E2E_USER=user, LOGIN_E2E_PASS=password)
    env.pop("HPMMO_TICKET", None)
    result = test_stack.run([test_stack.marker_cmd(), "--headless", "--path", test_stack.CLIENT_DIR,
                             "res://scenes/test/login_screen_e2e.tscn",
                             "--ip", "127.0.0.1", "--port", str(stack.world_port), "--no-autologin"],
                            env=env, timeout=300)
    lines = [line for line in (result.stdout + result.stderr).splitlines() if line.startswith("LOGIN_E2E")]
    for line in lines:
        print("   " + line)
    return result.returncode == 0 and any("RESULT: 0 failure" in line for line in lines), result.stdout + result.stderr


def main():
    out = os.path.join(HERE, "out", "login")
    os.makedirs(out, exist_ok=True)
    state_dir = tempfile.mkdtemp(prefix="hpmmo-login-state-")
    os.environ["HPMMO_STATE_DIR"] = state_dir  # inherited by the service
    flag = os.path.join(state_dir, "maintenance.flag")
    stack = test_stack.Stack(out)
    try:
        stack.start()
        user = "login%s" % secrets.token_hex(3)
        password = "Wand%s9" % secrets.token_hex(4)

        doc = status(stack.api_port)
        check(doc.get("state") == "ONLINE" and doc.get("maintenance") is False, "/api/status is ONLINE", str(doc))
        ok, log = drive(stack, "register", user, password)
        check(ok, "the login screen registers, logs in and reaches character selection", log)

        with open(flag, "w", encoding="utf-8") as handle:
            handle.write('{"state":"ANNOUNCING","since":"","until":"","reason":"server update test"}\n')
        doc = status(stack.api_port)
        check(doc.get("maintenance") is True, "/api/status reports the announced maintenance", str(doc))
        ok, log = drive(stack, "maintenance", user, password)
        check(ok, "the login screen refuses with the maintenance notice", log)

        os.remove(flag)
        doc = status(stack.api_port)
        check(doc.get("state") == "ONLINE", "/api/status is ONLINE once the flag is gone", str(doc))
    finally:
        stack.stop()
        shutil.rmtree(state_dir, ignore_errors=True)
    print("LOGIN SCREEN RESULT: %d failure(s)" % FAILURES)
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
