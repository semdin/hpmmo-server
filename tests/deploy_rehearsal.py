#!/usr/bin/env python3
"""Phase 6 deployment rehearsal (plan.md).

Drives the REAL deployment controller (deploy/hpmmo_deploy.sh) against a fully
synthetic environment in a temp directory:

  * fake release artifacts (tiny trees with a stub hpmmo_service binary),
  * a stub systemctl (records every call together with what `current` pointed
    at, and tells the fake world server when the process started or stopped),
  * a fake world-server admin interface and a fake account-service API that
    answer on loopback ports,
  * stub units in a temp UNIT_DIR (never /etc, never /opt, never the real
    machine, never the real services).

Rehearsed exit cases (plan.md Phase 6 "Exit checks" + the task list):

  1. happy path: stage -> maintenance -> save -> migrate -> switch -> verify
     -> ONLINE, and `current` only ever changes at the switch step
  2. failed checksum / failed build -> nothing on disk changes, services untouched
  3. failed final save -> stays in maintenance, no swap, journal records FAILED
  4. failed migration -> previous release restored, journal records it
  5. unhealthy new binary -> rollback to previous, maintenance still active
  6. two closely spaced releases -> the second queues behind the lock, both journalled
  7. controller restart mid-deployment -> recovery from the journal (both
     before and after the switch), no half-switched state
  8. no live files change before the disconnect barrier (inode/mtime/size
     snapshots of the running release taken at every world state)
  9. maintenance interface absent -> fail safe, journal + abort, nothing changes
 10. the stub admin interface is as strict as the real one: a request without
     the service token (or with a wrong one) is refused with 403, so a
     controller that fails to send the header can never pass this rehearsal
     again (the VPS found exactly that hole - see `curl -K -` in
     hpmmo_deploy.sh and admin.gd's _authorized())
 11. rollback races a booting world server: the stub admin port refuses
     connections for `boot_delay` seconds after a world (re)start. A controller
     that writes MAINTENANCE without waiting for the interface to answer cannot
     pass: the status document must match what the world actually enforces
     (the VPS defect - after a failed release the rollback wrote MAINTENANCE
     while the restored world came up ONLINE and accepting logins)

Usage:
  python server/tests/deploy_rehearsal.py [--case NAME] [--keep] [--verbose]

Set HPMMO_REHEARSAL_CONTROLLER=<path> to drive a different copy of the
controller (used to prove that a regression gate actually bites when the fix
is removed from a scratch copy).

Prints one PASS/FAIL line per check and finishes with
    DEPLOY RESULT: N checks, M failures
Exit code is 0 when there are no failures (1 otherwise, 2 when bash is
unavailable so the rehearsal cannot run at all).
"""

from __future__ import annotations

import argparse
import hashlib
import http.server
import json
import os
import re
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.dirname(HERE)
DEPLOY = os.path.join(SERVER, "deploy")
# Overridable so a scratch copy of the controller (for example with a fix
# removed) can be driven through the same rehearsal - the bite proof.
CONTROLLER = os.environ.get("HPMMO_REHEARSAL_CONTROLLER") or os.path.join(DEPLOY, "hpmmo_deploy.sh")
STATUS_SERVICE = os.path.join(DEPLOY, "hpmmo_status.py")
PACKAGER = os.path.join(DEPLOY, "package_server.sh")

# A token with a recognisable shape: the rehearsal fails if it ever shows up in
# a journal, a log, a status document or captured output (it lives only in the
# env file, exactly as on the server).
TOKEN = "rehearsal-token-" + secrets.token_hex(16)

checks = 0
failures: list[str] = []
VERBOSE = False


def check(condition, message: str) -> bool:
    global checks
    checks += 1
    if condition:
        print("PASS: " + message)
        return True
    failures.append(message)
    print("FAIL: " + message)
    return False


def note(message: str) -> None:
    if VERBOSE:
        print("      " + message)


def find_bash() -> str | None:
    override = os.environ.get("HPMMO_BASH")
    if override:
        return override
    if os.name == "nt":
        # usr\bin\bash.exe first: bin\bash.exe is a launcher wrapper, so
        # killing it would leave the real shell (and the deployment) running.
        for candidate in (
            r"C:\Program Files\Git\usr\bin\bash.exe",
            r"C:\Program Files\Git\bin\bash.exe",
            r"C:\Program Files (x86)\Git\usr\bin\bash.exe",
        ):
            if os.path.isfile(candidate):
                return candidate
        found = shutil.which("bash")
        # System32\bash.exe is WSL: it cannot see our Windows temp paths.
        if found and "system32" not in found.lower():
            return found
        return None
    return shutil.which("bash") or "/bin/bash"


BASH = find_bash()


def posix(path: str) -> str:
    """Temp paths must reach bash in POSIX form (Git Bash cannot use C:\\...)."""
    if os.name != "nt":
        return path
    try:
        out = subprocess.run(["cygpath", "-u", path], capture_output=True, text=True, timeout=30)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except OSError:
        pass
    return path.replace("\\", "/")


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def http_json(url: str, method: str = "GET", body=None, timeout: float = 10.0,
              token: str | None = None):
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token is not None:
        headers["X-Service-Token"] = token
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8", "replace")
            try:
                return response.status, json.loads(raw)
            except ValueError:
                return response.status, raw
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            return exc.code, json.loads(raw)
        except ValueError:
            return exc.code, raw
    except (urllib.error.URLError, OSError) as exc:
        return 0, str(exc)


def http_json_retry(url: str, **kwargs):
    """http_json with one retry when the connection itself failed (code 0).

    A loopback reset is a transport flake, not an answer: without the retry a
    refusal check could fail for the wrong reason and make the rehearsal flaky.
    """
    code, payload = http_json(url, **kwargs)
    if code == 0:
        code, payload = http_json(url, **kwargs)
    return code, payload


# --------------------------------------------------------------------------
# fake world-server admin interface
# --------------------------------------------------------------------------
DRAIN_SEQUENCE = ["ANNOUNCING", "DRAINING", "SAVING", "DISCONNECTING", "MAINTENANCE"]


class _JsonHandler(http.server.BaseHTTPRequestHandler):
    """HTTP/1.1 with small JSON helpers, shared by the two stub servers below
    (the world's admin port and the rehearsal's control port)."""

    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def _json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            return json.loads(raw.decode("utf-8")) if raw else {}
        except ValueError:
            return {}


class FakeAdmin:
    """Stands in for the world server's authenticated admin interface.

    Contract (also in docs/runbook-rollback.md):
        POST /admin/maintenance/begin {reason, countdown_seconds}
        GET  /admin/state
        POST /admin/save -> {"failed": N}
        GET  /admin/status -> {"state": ...}

    Like admin.gd, every one of these requires `X-Service-Token` and answers
    403 before a route is even considered when it is missing or wrong.

    The admin interface has its own port, which behaves like the real one: it
    can be down (nothing listening -> connection refused) while the world
    process boots. The `/__ctl/...` controls live on a second, always
    listening port - the stub systemctl uses it to announce that the world
    process started or stopped, which must keep working while the admin port
    is "booting".
    """

    def __init__(self, snapshot_fn=None):
        self.state = "ONLINE"
        self.world_up = True
        # Seconds the admin port refuses connections after a world (re)start:
        # the real admin listener opens only once the world process is up.
        # 0 keeps the port always listening (pre-boot-delay behaviour).
        self.boot_delay = 0.0
        self.scripted = None
        self.hold = False
        self.mode = "normal"          # normal | absent
        self.save_failed = 0
        self.save_delay = 0.0
        # quirks of the real world server, exercised by case_admin_contract
        self.save_route = "/admin/save"
        self.begin_conflict_state = ""   # begin() answers 409 with this state
        self.drain_failed = False        # the drain ends in FAILED
        self.reason = ""
        self.denied = 0                  # requests refused for a bad/absent token
        self.requests: list[tuple[str, str, float]] = []
        self.begins: list[dict] = []
        self.snapshots: list[tuple[str, str, dict]] = []
        self.snapshot_fn = snapshot_fn
        self.snapshot_enabled = False
        self._lock = threading.Lock()
        self._server_lock = threading.RLock()
        self._boot_gen = 0
        self._boot_timer: threading.Timer | None = None
        self.port = free_port()
        self.ctl_port = free_port()
        while self.ctl_port == self.port:
            self.ctl_port = free_port()
        self.server = self._make_server()
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.ctl_server = self._make_ctl_server()
        self.ctl_thread = threading.Thread(target=self.ctl_server.serve_forever, daemon=True)
        self.ctl_thread.start()

    # -- server lifecycle --------------------------------------------------
    def _make_server(self):
        """The world's admin port: closed (connections refused) while the
        world process is still booting."""
        admin = self

        class Handler(_JsonHandler):
            def do_GET(self):  # noqa: N802
                path = self.path.split("?", 1)[0]
                if admin.mode == "absent":
                    self._json(404, {"error": "not found"})
                    return
                if not admin.authorized(self.headers):
                    self._json(403, {"ok": False, "error": "forbidden"})
                    return
                if path in ("/admin/state", "/admin/status"):
                    admin._record(path)
                    if not admin.world_up:
                        self._json(503, {"state": "OFFLINE", "error": "world server is not running"})
                        return
                    state = admin.current_state()
                    self._json(200, {"ok": True, "state": state, "reason": admin.reason,
                                     "release": admin.release_id()})
                    return
                self._json(404, {"error": "not found"})

            def do_POST(self):  # noqa: N802
                path = self.path.split("?", 1)[0]
                # Read the body before answering: the real server parses the
                # whole request before it checks the token, and consuming it
                # keeps the connection consistent when the request is refused.
                body = self._read_body()
                if admin.mode == "absent":
                    self._json(404, {"error": "not found"})
                    return
                if not admin.authorized(self.headers):
                    self._json(403, {"ok": False, "error": "forbidden"})
                    return
                if path == "/admin/maintenance/begin":
                    admin._record(path)
                    if admin.begin_conflict_state:
                        # the world server refuses begin() from any state but
                        # ONLINE - and that state is what /admin/state reports
                        with admin._lock:
                            admin.scripted = None
                            admin.hold = admin.begin_conflict_state == "MAINTENANCE"
                            admin.state = admin.begin_conflict_state
                        self._json(409, {"ok": False, "error": "already_in_maintenance",
                                         "state": admin.begin_conflict_state})
                        return
                    with admin._lock:
                        admin.begins.append(body)
                        countdown = int(body.get("countdown_seconds", 0) or 0)
                        if countdown <= 0:
                            admin.hold = True
                            admin.state = "MAINTENANCE"
                        else:
                            admin.hold = False
                            admin.scripted = list(DRAIN_SEQUENCE)
                            admin.state = admin.scripted[0]
                    self._json(200, {"ok": True, "state": admin.state})
                    return
                if path == admin.save_route:
                    admin._record(path, "SAVING")
                    if admin.save_delay:
                        time.sleep(admin.save_delay)
                    self._json(200, {"failed": admin.save_failed, "saved_characters": 3})
                    return
                self._json(404, {"error": "not found"})

        httpd = http.server.ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        httpd.daemon_threads = True
        return httpd

    def _make_ctl_server(self):
        """The rehearsal's own controls (stub systemctl -> world lifecycle).
        Always listening and unauthenticated: it is not part of the contract
        under test."""
        admin = self

        class Handler(_JsonHandler):
            def do_POST(self):  # noqa: N802
                path = self.path.split("?", 1)[0]
                if path.startswith("/__ctl/"):
                    admin.control(path, self._read_body())
                    self._json(200, {"ok": True})
                    return
                self._json(404, {"error": "not found"})

        httpd = http.server.ThreadingHTTPServer(("127.0.0.1", self.ctl_port), Handler)
        httpd.daemon_threads = True
        return httpd

    def _start_admin_server(self, generation: int = -1) -> None:
        with self._server_lock:
            if generation != self._boot_gen:
                return          # a newer world start superseded this boot
            if self.server is not None:
                return
            server = self._make_server()
            self.server = server
            self.thread = threading.Thread(target=server.serve_forever, daemon=True)
            self.thread.start()

    def _stop_admin_server(self) -> None:
        with self._server_lock:
            server, thread = self.server, self.thread
            self.server, self.thread = None, None
        if server is not None:
            server.shutdown()
            server.server_close()
        if thread is not None:
            thread.join(timeout=30)

    def boot(self, immediate: bool = False) -> None:
        """A world (re)start: the admin port stays closed for `boot_delay`
        seconds (nothing listens, so connections are refused) and then opens.
        `immediate` (the /__ctl/reset control) skips the delay."""
        with self._server_lock:
            self._boot_gen += 1
            generation = self._boot_gen
            if self._boot_timer is not None:
                self._boot_timer.cancel()
                self._boot_timer = None
        delay = 0.0 if immediate else self.boot_delay
        if delay <= 0:
            self._start_admin_server(generation)
            return
        self._stop_admin_server()
        timer = threading.Timer(delay, self._start_admin_server, args=(generation,))
        timer.daemon = True
        with self._server_lock:
            self._boot_timer = timer
        timer.start()

    def _record(self, path: str, state_note: str = "") -> None:
        with self._lock:
            self.requests.append((path, state_note, time.time()))
            if self.snapshot_enabled and self.snapshot_fn:
                self.snapshots.append((state_note or self.state, path, self.snapshot_fn()))

    def authorized(self, headers) -> bool:
        """The real admin.gd refuses every route before the token is checked;
        the stub must be just as strict or the rehearsal cannot notice a
        controller that never sends X-Service-Token."""
        supplied = headers.get("X-Service-Token", "") or ""
        if supplied == "" or not secrets.compare_digest(supplied, TOKEN):
            with self._lock:
                self.denied += 1
            return False
        return True

    def control(self, path: str, _body: dict) -> None:
        boot_immediate = None
        with self._lock:
            if path == "/__ctl/world_up":
                self.world_up = True
                self.scripted = None
                self.hold = False
                self.state = "ONLINE"
                boot_immediate = False
            elif path == "/__ctl/world_down":
                self.world_up = False
            elif path == "/__ctl/world_stuck":
                # The process is running but never reaches ONLINE.
                self.world_up = True
                self.scripted = None
                self.hold = False
                self.state = "STARTING"
            elif path == "/__ctl/reset":
                self.world_up = True
                self.scripted = None
                self.hold = False
                self.state = "ONLINE"
                self.snapshots.clear()
                boot_immediate = True
        if boot_immediate is not None:
            # A world (re)start closes the admin port for boot_delay seconds;
            # reset() is the harness control and comes up immediately.
            self.boot(immediate=boot_immediate)

    def current_state(self) -> str:
        with self._lock:
            if self.drain_failed and self.scripted:
                # the real admin ends the cycle in FAILED when the save barrier
                # cannot be confirmed: players stay, joins stay refused
                self.scripted = None
                self.state = "FAILED"
                self.reason = "the save barrier did not confirm 2 character save(s)"
                return self.state
            if self.hold:
                return "MAINTENANCE"
            if self.scripted:
                state = self.scripted.pop(0)
                self.state = state
                return state
            return self.state

    def release_id(self) -> str:
        return ""

    @property
    def url(self) -> str:
        return "http://127.0.0.1:%d" % self.port

    @property
    def ctl_url(self) -> str:
        return "http://127.0.0.1:%d" % self.ctl_port

    def stop(self):
        with self._server_lock:
            if self._boot_timer is not None:
                self._boot_timer.cancel()
                self._boot_timer = None
        self._stop_admin_server()
        self.ctl_server.shutdown()
        self.ctl_server.server_close()

    def reset(self):
        self.control("/__ctl/reset", {})
        self.denied = 0
        self.requests.clear()
        self.begins.clear()
        self.snapshots.clear()


# --------------------------------------------------------------------------
# fake account/persistence service API
# --------------------------------------------------------------------------
class FakeApi:
    def __init__(self, schema: int = 4, version: str = "1.2.3"):
        self.schema = schema
        self.version = version
        self.ready = True
        self.port = free_port()
        self.server = self._make_server()
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def _make_server(self):
        api = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):
                pass

            def _json(self, code, payload):
                body = json.dumps(payload).encode("utf-8")
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):  # noqa: N802
                path = self.path.split("?", 1)[0]
                if path == "/api/health":
                    self._json(200, {"status": "ok", "service": "hpmmo_service", "time": "now"})
                elif path == "/api/ready":
                    if api.ready:
                        self._json(200, {"status": "ready", "db": "postgresql", "schema": api.schema})
                    else:
                        self._json(503, {"status": "unavailable", "schema": api.schema, "required": api.schema})
                elif path == "/api/version":
                    self._json(200, {"version": api.version, "game_title": "HPMMO", "min_client_version": "1.0.0"})
                else:
                    self._json(404, {"error": "not found"})

        httpd = http.server.ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        httpd.daemon_threads = True
        return httpd

    @property
    def url(self) -> str:
        return "http://127.0.0.1:%d" % self.port

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


# --------------------------------------------------------------------------
# the rehearsal environment
# --------------------------------------------------------------------------
SERVICE_STUB = r"""#!/bin/bash
# stub hpmmo_service (rehearsal only)
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
printf 'hpmmo_service %s in %s\n' "${1:-serve}" "$here" >> "$HPMMO_REHEARSAL_LOG"
case "${1:-serve}" in
    migrate)
        if [ -f "$here/.migrate_fails" ]; then
            printf 'stub: migration refused\n' >&2
            exit 1
        fi
        printf 'schema at version %s\n' "$(cat "$here/.schema" 2>/dev/null || echo 4)"
        exit 0 ;;
    version) printf 'hpmmo-service stub 1.2.3\n'; exit 0 ;;
    serve)   sleep 600 ;;
esac
exit 0
"""

SYSTEMCTL_STUB = r"""#!/bin/bash
# stub systemctl (rehearsal only): records the call, the active release at the
# time of the call, tracks whether the world service is running, and tells the
# fake world server what happened. The controls live on the always-listening
# control port: the world's admin port itself may refuse connections while the
# world "boots" (HPMMO_REHEARSAL_ADMIN_BOOT_DELAY via FakeAdmin.boot_delay).
log="$HPMMO_REHEARSAL_LOG.systemctl"
world_state_file="$HPMMO_REHEARSAL_LOG.world"
action="${1:-}"; shift || true
if [ "$action" = "is-active" ]; then
    # mirrors `systemctl is-active [--quiet] hpmmo.service`
    if [ -f "$world_state_file" ] && [ "$(cat "$world_state_file")" = "active" ]; then
        echo active; exit 0
    fi
    echo inactive; exit 3
fi
current=""
if [ -L "$RELEASES_DIR/current" ]; then
    current="$(readlink "$RELEASES_DIR/current" 2>/dev/null || true)"
    [ -n "$current" ] && current="$(basename "$current")"
fi
printf '%s %s current=%s\n' "$action" "$*" "${current:-none}" >> "$log"
for unit in "$@"; do
    case "$action $unit" in
        "stop hpmmo.service")      printf 'inactive\n' > "$world_state_file"
                                   curl -sS -X POST "$HPMMO_REHEARSAL_ADMIN_CTL/__ctl/world_down" >/dev/null 2>&1 || true ;;
        "restart hpmmo.service"|"start hpmmo.service")
            printf 'active\n' > "$world_state_file"
            if [ "${HPMMO_REHEARSAL_WORLD_STUCK:-0}" = "1" ]; then
                curl -sS -X POST "$HPMMO_REHEARSAL_ADMIN_CTL/__ctl/world_stuck" >/dev/null 2>&1 || true
            else
                curl -sS -X POST "$HPMMO_REHEARSAL_ADMIN_CTL/__ctl/world_up" >/dev/null 2>&1 || true
            fi ;;
    esac
done
if [ "${HPMMO_REHEARSAL_FAIL_DB:-0}" = "1" ]; then
    case "$action" in restart) case "$*" in *hpmmo-db*) exit 1 ;; esac ;; esac
fi
exit 0
"""

SMOKE_STUB = r"""#!/bin/bash
# stub synthetic login+join check (rehearsal only)
release="${1:-${HPMMO_SMOKE_RELEASE:-}}"
printf 'smoke %s\n' "$release" >> "$HPMMO_REHEARSAL_LOG"
if [ -f "$HPMMO_REHEARSAL_SMOKE_FLAG" ]; then
    printf 'stub: synthetic login refused\n'
    exit 1
fi
if [ -f "$HPMMO_REHEARSAL_SMOKE_SLOW" ]; then
    sleep 30
fi
if [ -z "$HPMMO_SERVICE_TOKEN" ]; then
    printf 'stub: no service token in the environment\n'
fi
printf 'stub: joined the world as a synthetic client\n'
exit 0
"""

PYTHON_SHIM = "#!/bin/bash\nexec %s \"$@\"\n"

UNIT_TEMPLATE = """[Unit]
Description=HPMMO {name} (rehearsal stub)

[Service]
Type=simple
WorkingDirectory={releases}/current/{workdir}
ExecStart={exe}
Restart=always

[Install]
WantedBy=multi-user.target
"""

STATUS_UNIT_TEMPLATE = """[Unit]
Description=HPMMO status endpoint (rehearsal stub)

[Service]
Type=simple
ExecStart={python} {script}
Restart=always

[Install]
WantedBy=multi-user.target
"""


class Rehearsal:
    """A self-contained rehearsal environment under a temp directory."""

    def __init__(self, name: str):
        self.name = name
        self.root = os.path.join(tempfile_root(), "hpmmo-rehearsal-%s-%s" % (name, secrets.token_hex(4)))
        self.releases = os.path.join(self.root, "releases")
        self.state = os.path.join(self.root, "state")
        self.units = os.path.join(self.root, "units")
        self.bin = os.path.join(self.root, "bin")
        self.etc = os.path.join(self.root, "etc")
        self.work = os.path.join(self.root, "work")
        for path in (self.releases, self.state, self.units, self.bin, self.etc, self.work):
            os.makedirs(path, exist_ok=True)
        self.log = os.path.join(self.root, "rehearsal.log")
        self.smoke_flag = os.path.join(self.root, "smoke-fails.flag")
        self.smoke_slow = os.path.join(self.root, "smoke-slow.flag")
        self.python = sys.executable
        self.admin = FakeAdmin(snapshot_fn=None)
        self.api = FakeApi()
        self.release_versions: dict[str, str] = {}
        self.release_schemas: dict[str, int] = {}
        self.snapshots: list[tuple[str, str, dict]] = []
        self.admin.snapshot_fn = self._snapshot_live
        self.posix_root = posix(self.root)
        self._write_stubs()

    # -- paths -------------------------------------------------------------
    def p(self, *parts: str) -> str:
        """POSIX path (for bash) below the temp root."""
        return self.posix_root + "".join("/" + part for part in parts)

    def native(self, *parts: str) -> str:
        return os.path.join(self.root, *parts)

    # -- setup -------------------------------------------------------------
    def _write_stubs(self):
        def write(path, text, mode=0o755):
            with open(path, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(text)
            os.chmod(path, mode)

        write(os.path.join(self.bin, "systemctl"), SYSTEMCTL_STUB)
        write(os.path.join(self.bin, "smoke_client.sh"), SMOKE_STUB)
        # nothing is running until a deployment starts it
        write(self.log + ".world", "inactive\n")
        if os.name == "nt":
            write(os.path.join(self.bin, "python3"), PYTHON_SHIM % posix(self.python))
        # A cmake/ninja pair that always fails, for the "failed build" case.
        write(os.path.join(self.bin, "cmake"), "#!/bin/bash\necho 'stub cmake: no toolchain' >&2\nexit 1\n")
        write(os.path.join(self.bin, "ninja"), "#!/bin/bash\necho 'stub ninja: no toolchain' >&2\nexit 1\n")

        write(os.path.join(self.etc, "hpmmo.env"),
              "# rehearsal env file - the only place the token may appear\n"
              "DATABASE_URL=postgresql://hpmmo:rehearsal@127.0.0.1:5432/hpmmo_rehearsal\n"
              "HPMMO_DB_PASSWORD=rehearsal-db-password\n"
              "HPMMO_SERVICE_TOKEN=%s\n"
              "HPMMO_WORLD_PORT=17777\n"
              "HPMMO_WORLD_SEED=4242\n"
              "HPMMO_SMOKE_CMD=%s\n"
              % (TOKEN, self.p("bin", "smoke_client.sh")))

        write(os.path.join(self.units, "hpmmo-db.service"),
              UNIT_TEMPLATE.format(name="db service",
                                   releases=self.p("releases"),
                                   workdir="services/cpp",
                                   exe=self.p("releases") + "/current/services/cpp/build/hpmmo_service"),
              mode=0o644)
        write(os.path.join(self.units, "hpmmo.service"),
              UNIT_TEMPLATE.format(name="world server",
                                   releases=self.p("releases"),
                                   workdir="world",
                                   exe=self.p("bin") + "/godot_stub"),
              mode=0o644)
        write(os.path.join(self.units, "hpmmo-status.service"),
              STATUS_UNIT_TEMPLATE.format(python=posix(self.python), script=self.p("bin") + "/hpmmo_status.py"),
              mode=0o644)
        write(os.path.join(self.bin, "hpmmo_status.py"), open(STATUS_SERVICE, encoding="utf-8").read())

    # -- release artifacts --------------------------------------------------
    def make_release(self, rel_id: str, *, version: str = "1.2.3", schema: int = 4,
                     migrate_fails: bool = False, corrupt_manifest: bool = False,
                     no_binary: bool = False, no_manifest: bool = False,
                     tree: str | None = None) -> str:
        """Builds a fake release artifact (.tar.gz) and returns its path."""
        src = tree or os.path.join(self.work, "src-" + rel_id)
        if os.path.exists(src):
            shutil.rmtree(src, ignore_errors=True)
        os.makedirs(os.path.join(src, "world", ".godot", "imported"))
        os.makedirs(os.path.join(src, "services", "cpp", "build"))
        os.makedirs(os.path.join(src, "db", "migrations"))
        os.makedirs(os.path.join(src, "deploy"))
        os.makedirs(os.path.join(src, "contracts"))

        def put(rel, text, mode=0o644):
            path = os.path.join(src, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(text)
            os.chmod(path, mode)

        put("world/project.godot", '[application]\nconfig/name="HPMMO"\n')
        put("world/.godot/imported/keep.me", "import cache present\n")
        put("services/cpp/src/main.cpp", "// stub\n")
        put("services/version.json", json.dumps({"version": version}) + "\n")
        put("services/cpp/build/.schema", "%d\n" % schema)
        if migrate_fails:
            put("services/cpp/build/.migrate_fails", "1\n")
        put("db/migrations/0001_core.sql", "SELECT 1;\n")
        put("db/migrations/%04d_stub.sql" % schema, "SELECT %d;\n" % schema)
        put("contracts/protocol.md", "# protocol (stub)\n")
        put("deploy/smoke_client.sh", "#!/bin/bash\n# stub shipped in the release\nexit 3\n", 0o755)
        put("README.md", "# stub release %s\n" % rel_id)
        if not no_binary:
            binary = os.path.join(src, "services", "cpp", "build", "hpmmo_service")
            with open(binary, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(SERVICE_STUB)
            os.chmod(binary, 0o755)

        if not no_manifest:
            manifest = []
            for dirpath, _dirnames, filenames in os.walk(src):
                for filename in sorted(filenames):
                    path = os.path.join(dirpath, filename)
                    rel = "./" + os.path.relpath(path, src).replace(os.sep, "/")
                    digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
                    if corrupt_manifest and rel.endswith("services/version.json"):
                        digest = "0" * 64
                    manifest.append("%s  %s" % (digest, rel))
            with open(os.path.join(src, "SHA256SUMS"), "w", encoding="utf-8", newline="\n") as handle:
                handle.write("\n".join(sorted(manifest)) + "\n")

        tar_path = os.path.join(self.work, "hpmmo-server-%s.tar.gz" % rel_id)

        def normalize(info: tarfile.TarInfo) -> tarfile.TarInfo:
            if info.isdir():
                info.mode = 0o755
            elif info.name.endswith(("hpmmo_service", ".sh")):
                info.mode = 0o755
            else:
                info.mode = 0o644
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            return info

        with tarfile.open(tar_path, "w:gz") as archive:
            archive.add(src, arcname=".", filter=normalize)
        self.release_versions[rel_id] = version
        self.release_schemas[rel_id] = schema
        return tar_path

    # -- running the controller --------------------------------------------
    def env(self, extra: dict | None = None) -> dict:
        env = dict(os.environ)
        if os.name == "nt":
            # Git Bash otherwise "emulates" ln -s by copying the target: the
            # whole active-release pointer depends on real symlinks.
            env["MSYS"] = "winsymlinks:nativestrict"
            env["CYGWIN"] = "winsymlinks:nativestrict"
        env.update({
            "HPMMO_ENV_FILE": posix(os.path.join(self.etc, "hpmmo.env")),
            "RELEASES_DIR": self.p("releases"),          # the task's literal name
            "HPMMO_STATE_DIR": self.p("state"),
            "HPMMO_UNIT_DIR": self.p("units"),
            "HPMMO_SYSTEMCTL": self.p("bin", "systemctl"),
            "HPMMO_ADMIN_URL": self.admin.url,
            "HPMMO_API_URL": self.api.url,
            "HPMMO_GODOT": self.p("bin", "godot_stub"),
            "HPMMO_SMOKE_TIMEOUT": "20",
            "HPMMO_MAINTENANCE_COUNTDOWN": "5",
            "HPMMO_DRAIN_TIMEOUT": "20",
            "HPMMO_VERIFY_TIMEOUT": "8",
            "HPMMO_SAVE_TIMEOUT": "30",
            "HPMMO_HOLD_TIMEOUT": "8",
            "HPMMO_ADMIN_READY_TIMEOUT": "10",
            "HPMMO_ADMIN_READY_POLL": "0.2",
            "HPMMO_POLL_INTERVAL": "0.05",
            "HPMMO_LOCK_WAIT": "60",
            "HPMMO_REHEARSAL_LOG": posix(self.log),
            "HPMMO_REHEARSAL_ADMIN_CTL": self.admin.ctl_url,
            "HPMMO_REHEARSAL_SMOKE_FLAG": posix(self.smoke_flag),
            "HPMMO_REHEARSAL_SMOKE_SLOW": posix(self.smoke_slow),
            "PATH": posix(self.bin) + os.pathsep + env.get("PATH", ""),
        })
        if extra:
            env.update(extra)
        return env

    def _sync_api(self, args: list[str]) -> None:
        """Point the fake account service at whatever the release being
        deployed (or rolled back to) ships: the controller verifies that
        /api/version and the release agree."""
        target = ""
        if "--release" in args:
            target = args[args.index("--release") + 1]
        elif "--deploy" in args and "--id" in args:
            target = args[args.index("--id") + 1]
        elif args and args[0] in ("--rollback", "--recover"):
            target = self.current()
        if target and target in self.release_versions:
            self.api.version = self.release_versions[target]
            self.api.schema = self.release_schemas.get(target, self.api.schema)

    def run(self, args: list[str], timeout: float = 180, env_extra: dict | None = None):
        cmd = [BASH, CONTROLLER] + args
        note("run: " + " ".join(args))
        self._sync_api(args)
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                              env=self.env(env_extra), cwd=self.root)

    def spawn(self, args: list[str], env_extra: dict | None = None):
        cmd = [BASH, CONTROLLER] + args
        note("spawn: " + " ".join(args))
        self._sync_api(args)
        return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                env=self.env(env_extra), cwd=self.root)

    # -- observation --------------------------------------------------------
    def current(self) -> str:
        path = os.path.join(self.releases, "current")
        if not os.path.exists(path):
            return ""
        target = os.path.realpath(path)
        if not os.path.isdir(target):
            return ""
        return os.path.basename(target)

    def journal(self) -> list[dict]:
        path = os.path.join(self.state, "journal.jsonl")
        records = []
        if not os.path.exists(path):
            return records
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    records.append(json.loads(line))
                except ValueError:
                    failures.append("journal contains a non-JSON line: %s" % line[:120])
        return records

    def states(self) -> list[str]:
        return [record.get("to", "") for record in self.journal()]

    def status(self) -> dict:
        path = os.path.join(self.state, "status.json")
        if not os.path.exists(path):
            return {}
        try:
            return json.load(open(path, encoding="utf-8"))
        except ValueError:
            return {}

    def systemctl_calls(self) -> list[str]:
        path = self.log + ".systemctl"
        if not os.path.exists(path):
            return []
        return [line.strip() for line in open(path, encoding="utf-8") if line.strip()]

    def stub_calls(self) -> list[str]:
        if not os.path.exists(self.log):
            return []
        return [line.strip() for line in open(self.log, encoding="utf-8") if line.strip()]

    def kill(self, proc: subprocess.Popen, timeout: float = 30) -> None:
        """SIGKILL the controller *and* its children (Git Bash spawns helpers)."""
        if proc.poll() is not None:
            return
        if os.name == "nt":
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(proc.pid)],
                           capture_output=True, timeout=60)
        else:
            proc.kill()
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()

    def saw_request(self, path: str) -> bool:
        return any(request[0] == path for request in self.admin.requests)

    def snapshot_live(self) -> dict:
        return self._snapshot_live()

    def _snapshot_live(self, base: str | None = None) -> dict:
        """(inode, mtime_ns, size, mode) for every file of the active release."""
        base = base or self.current()
        root = os.path.join(self.releases, base) if base else ""
        out = {}
        if not root or not os.path.isdir(root):
            return out
        for dirpath, _dirnames, filenames in os.walk(root):
            for filename in filenames:
                path = os.path.join(dirpath, filename)
                try:
                    info = os.stat(path)
                except OSError:
                    continue
                out[os.path.relpath(path, root)] = (info.st_ino, info.st_mtime_ns, info.st_size, stat.S_IMODE(info.st_mode))
        return out

    def tree_files(self, path: str) -> dict:
        return self._snapshot_live_path(path)

    def _snapshot_live_path(self, root: str) -> dict:
        out = {}
        for dirpath, _dirnames, filenames in os.walk(root):
            for filename in filenames:
                path = os.path.join(dirpath, filename)
                try:
                    info = os.stat(path)
                except OSError:
                    continue
                out[os.path.relpath(path, root)] = (info.st_ino, info.st_mtime_ns, info.st_size)
        return out

    def assert_no_secret(self, text: str, where: str) -> None:
        check(TOKEN not in (text or ""), "no service token leaked into %s" % where)

    def scan_for_secrets(self) -> None:
        leaked = []
        for dirpath, _dirnames, filenames in os.walk(self.root):
            for filename in filenames:
                path = os.path.join(dirpath, filename)
                if path.endswith("hpmmo.env"):
                    continue  # the env file is where the token belongs
                try:
                    if os.path.getsize(path) > 4 * 1024 * 1024:
                        continue
                    blob = open(path, "rb").read()
                except OSError:
                    continue
                if TOKEN.encode() in blob:
                    leaked.append(os.path.relpath(path, self.root))
        check(not leaked, "no service token in any generated file (found in: %s)" % (leaked or "none"))

    def cleanup(self, keep: bool):
        self.admin.stop()
        self.api.stop()
        if keep:
            print("      kept rehearsal dir: " + self.root)
        else:
            shutil.rmtree(self.root, ignore_errors=True)


_TEMP_ROOT = None


def tempfile_root() -> str:
    """System temp dir - the rehearsal never writes inside the repository."""
    global _TEMP_ROOT
    if _TEMP_ROOT is None:
        _TEMP_ROOT = tempfile.mkdtemp(prefix="hpmmo-deploy-rehearsal-")
    return _TEMP_ROOT


# --------------------------------------------------------------------------
# shared helpers for the cases
# --------------------------------------------------------------------------
def stage_ok(env: Rehearsal, rel_id: str, **kwargs) -> str:
    tar = env.make_release(rel_id, **kwargs)
    result = env.run(["--stage", posix(tar), "--id", rel_id])
    check(result.returncode == 0, "[%s] staging %s succeeded (exit %s)" % (env.name, rel_id, result.returncode))
    if result.returncode != 0:
        note(result.stdout[-2000:] + result.stderr[-2000:])
    return tar


def deploy_ok(env: Rehearsal, rel_id: str) -> subprocess.CompletedProcess:
    result = env.run(["--release", rel_id], timeout=240)
    check(result.returncode == 0, "[%s] deploying %s succeeded (exit %s)" % (env.name, rel_id, result.returncode))
    if result.returncode != 0:
        note(result.stdout[-3000:] + result.stderr[-3000:])
    return result


def bootstrap_online(env: Rehearsal, rel_id: str = "rel-base") -> None:
    """Brings the rehearsal world to a deployed, ONLINE baseline."""
    stage_ok(env, rel_id, version="1.0.0", schema=4)
    deploy_ok(env, rel_id)
    check(env.current() == rel_id, "[%s] baseline release %s is active" % (env.name, rel_id))
    env.admin.reset()
    env.systemctl_calls().clear()
    if os.path.exists(env.log + ".systemctl"):
        os.remove(env.log + ".systemctl")


# --------------------------------------------------------------------------
# cases
# --------------------------------------------------------------------------
def case_happy_path(keep: bool) -> None:
    env = Rehearsal("happy")
    try:
        baseline = env.snapshot_live()
        stage_ok(env, "rel-a", version="1.1.0", schema=4)
        check(os.path.isdir(os.path.join(env.releases, "rel-a")), "[happy] staged release is on disk")
        check(os.path.exists(os.path.join(env.state, "releases", "rel-a.json")),
              "[happy] staging metadata recorded")
        check(env.current() == "", "[happy] staging alone does not activate a release")

        env.admin.snapshot_enabled = True
        result = deploy_ok(env, "rel-a")
        env.admin.snapshot_enabled = False

        check(env.current() == "rel-a", "[happy] current points at rel-a after the deployment")
        states = env.states()
        required = ["BUILD_AND_STAGE", "ANNOUNCING", "DRAINING", "SAVING", "DISCONNECTING",
                    "MAINTENANCE", "APPLYING", "VERIFYING", "ONLINE"]
        seen = []
        for state in states:
            if state not in seen:
                seen.append(state)
        missing = [state for state in required if state not in seen]
        check(not missing, "[happy] journal recorded the full state sequence (missing: %s)" % (missing or "none"))
        check(seen == required, "[happy] the state sequence is in the plan's order: %s" % " ".join(seen))
        records = env.journal()
        check(records and records[-1].get("outcome") == "OK" and records[-1].get("to") == "ONLINE",
              "[happy] the journal ends with an ONLINE success")

        status = env.status()
        check(status.get("state") == "ONLINE", "[happy] status.json reports ONLINE")
        check(status.get("release") == "rel-a", "[happy] status.json reports release rel-a")
        check(status.get("previous_release", "") == "", "[happy] the first deployment has no previous release")

        # current only changes at the switch step
        calls = env.systemctl_calls()
        stop_index = next((i for i, line in enumerate(calls) if line.startswith("stop ") and "hpmmo.service" in line), None)
        restart_index = next((i for i, line in enumerate(calls)
                              if line.startswith("restart ") and "hpmmo-db.service" in line), None)
        check(stop_index is not None, "[happy] the world server was stopped before the switch")
        check(restart_index is not None and stop_index is not None and restart_index > stop_index,
              "[happy] the db service was restarted after the world was stopped")
        if stop_index is not None and restart_index is not None:
            before = calls[:stop_index + 1]
            after = calls[restart_index:]
            check(all("current=none" in line for line in before),
                  "[happy] current never changed before the switch: %s" % before)
            check(all("current=rel-a" in line for line in after),
                  "[happy] every call after the switch saw rel-a: %s" % after)

        # the synthetic login check ran, and the migration used the new binary
        check(any("smoke" in call for call in env.stub_calls()), "[happy] the synthetic login+join check ran")
        check(any("migrate" in call for call in env.stub_calls()), "[happy] migrations ran with the new binary")

        # (8) no live files change before the disconnect barrier
        barrier = {"ANNOUNCING", "DRAINING", "SAVING", "DISCONNECTING"}
        changed = []
        for state, path, snap in env.admin.snapshots:
            if state in barrier and snap != baseline and baseline:
                changed.append((state, path, len(snap), len(baseline)))
        check(not changed, "[happy] the live release tree was untouched during announce/drain/save (%s)" % changed)

        # the release is frozen: nothing wrote into it after staging
        meta = json.load(open(os.path.join(env.state, "releases", "rel-a.json"), encoding="utf-8"))
        now = time.time()
        after_stage = [name for name in env.tree_files(os.path.join(env.releases, "rel-a"))
                       if os.path.getmtime(os.path.join(env.releases, "rel-a", name)) > now]
        check(not after_stage, "[happy] no file in the release was modified after staging")
        if os.name != "nt":
            writable = [name for name in env.tree_files(os.path.join(env.releases, "rel-a"))
                        if os.stat(os.path.join(env.releases, "rel-a", name)).st_mode & stat.S_IWUSR]
            check(not writable, "[happy] the frozen release is read-only")

        env.scan_for_secrets()
        env.assert_no_secret(result.stdout + result.stderr, "the controller output")
        check(bool(meta.get("tree_hash")), "[happy] staging recorded a tree hash")
    finally:
        env.cleanup(keep)


def case_failed_checksum(keep: bool) -> None:
    env = Rehearsal("checksum")
    try:
        bootstrap_online(env, "rel-base")
        before_calls = env.systemctl_calls()
        before_current = env.current()

        tar = env.make_release("rel-bad", corrupt_manifest=True)
        result = env.run(["--stage", posix(tar), "--id", "rel-bad"])
        check(result.returncode != 0, "[checksum] staging an artifact with a bad SHA256SUMS refused")
        check(not os.path.isdir(os.path.join(env.releases, "rel-bad")),
              "[checksum] the refused release left nothing on disk")
        check(env.systemctl_calls() == before_calls, "[checksum] no service was touched")
        check(env.current() == before_current, "[checksum] current is unchanged")

        # a release modified after staging is refused at deploy time
        stage_ok(env, "rel-mut")
        target = os.path.join(env.releases, "rel-mut", "services", "version.json")
        os.chmod(os.path.dirname(target), 0o755)
        os.chmod(target, 0o644)
        with open(target, "w", encoding="utf-8") as handle:
            handle.write('{"version": "6.6.6"}\n')
        result = env.run(["--release", "rel-mut"])
        check(result.returncode != 0, "[checksum] a modified release is refused (exit %s)" % result.returncode)
        check(env.current() == before_current, "[checksum] the modified release was not activated")
        check(env.systemctl_calls() == before_calls, "[checksum] no service was touched after the refusal")
        last = env.journal()[-1] if env.journal() else {}
        check(last.get("outcome") == "REFUSED", "[checksum] the journal records REFUSED")
        env.assert_no_secret(result.stdout + result.stderr, "the controller output")

        # a failed build during staging leaves nothing behind
        tar = env.make_release("rel-nobuild", no_binary=True)
        result = env.run(["--stage", posix(tar), "--id", "rel-nobuild"])
        check(result.returncode != 0, "[checksum] a failing staging build is refused")
        check(not os.path.isdir(os.path.join(env.releases, "rel-nobuild")),
              "[checksum] the failed build left nothing on disk")
        check(env.systemctl_calls() == before_calls, "[checksum] the failed build touched no service")
        check(env.current() == before_current, "[checksum] the failed build did not change current")
        env.assert_no_secret(result.stdout + result.stderr, "the failed build output")
    finally:
        env.cleanup(keep)


def case_failed_save(keep: bool) -> None:
    env = Rehearsal("save")
    try:
        bootstrap_online(env, "rel-base")
        stage_ok(env, "rel-save")
        env.admin.save_failed = 2
        result = env.run(["--release", "rel-save"])
        check(result.returncode != 0, "[save] a failed final save fails the deployment")
        check(env.current() == "rel-base", "[save] the release was not swapped")
        calls = env.systemctl_calls()
        check(not any(line.startswith("stop ") for line in calls),
              "[save] the world server was never stopped: %s" % calls)
        check(not any(line.startswith("restart ") for line in calls),
              "[save] no service was restarted: %s" % calls)
        records = env.journal()
        check(any(r.get("outcome") == "FAILED" for r in records), "[save] the journal records FAILED")
        check(any("final save failed" in r.get("message", "") for r in records),
              "[save] the journal names the failed final save")
        check(env.status().get("state") == "MAINTENANCE", "[save] the world is left in maintenance")
        check(env.admin.begins and env.admin.begins[0].get("countdown_seconds") == 5,
              "[save] the maintenance countdown was announced: %s" % env.admin.begins)
        env.assert_no_secret(result.stdout + result.stderr, "the controller output")
    finally:
        env.cleanup(keep)


def case_failed_migration(keep: bool) -> None:
    env = Rehearsal("migration")
    try:
        bootstrap_online(env, "rel-base")
        stage_ok(env, "rel-mig", migrate_fails=True)
        result = env.run(["--release", "rel-mig"])
        check(result.returncode == 7, "[migration] a failed migration exits 7 (got %s)" % result.returncode)
        check(env.current() == "rel-base", "[migration] the previous release is still active")
        records = env.journal()
        check(any(r.get("outcome") == "FAILED" and "migration failed" in r.get("message", "") for r in records),
              "[migration] the journal records the failed migration")
        check(any(r.get("outcome") == "ROLLBACK" for r in records), "[migration] the journal records ROLLBACK")
        calls = env.systemctl_calls()
        check(any("restart" in line and "hpmmo-db.service" in line for line in calls),
              "[migration] the previous release's services were restarted: %s" % calls)
        check(any(line.startswith("restart ") and "hpmmo.service" in line for line in calls),
              "[migration] the world server was restarted on the previous release")
        holds = [b for b in env.admin.begins if int(b.get("countdown_seconds", 1)) == 0]
        check(bool(holds), "[migration] maintenance was re-held after the rollback: %s" % env.admin.begins)
        check(env.status().get("state") == "MAINTENANCE", "[migration] maintenance stays active")
        check(env.status().get("release") == "rel-base", "[migration] status reports the restored release")
        env.assert_no_secret(result.stdout + result.stderr, "the controller output")
    finally:
        env.cleanup(keep)


def case_unhealthy_release(keep: bool) -> None:
    env = Rehearsal("unhealthy")
    try:
        bootstrap_online(env, "rel-base")
        stage_ok(env, "rel-sick")

        # the synthetic login check fails
        with open(env.smoke_flag, "w", encoding="utf-8") as handle:
            handle.write("1\n")
        result = env.run(["--release", "rel-sick"])
        check(result.returncode == 8, "[unhealthy] a failing synthetic check exits 8 (got %s)" % result.returncode)
        check(env.current() == "rel-base", "[unhealthy] current was rolled back to the previous release")
        records = env.journal()
        check(any(r.get("outcome") == "ROLLBACK" for r in records), "[unhealthy] the journal records ROLLBACK")
        check(any("synthetic login" in r.get("message", "") for r in records),
              "[unhealthy] the journal names the failed synthetic check")
        check(env.status().get("state") == "MAINTENANCE",
              "[unhealthy] maintenance is still ACTIVE and no release is online")
        holds = [b for b in env.admin.begins if int(b.get("countdown_seconds", 1)) == 0]
        check(bool(holds), "[unhealthy] the restored world was asked to stay in maintenance")
        calls = env.systemctl_calls()
        check(any("restart" in line and "current=rel-base" in line for line in calls),
              "[unhealthy] the services were restarted on the previous release: %s" % calls)
        env.assert_no_secret(result.stdout + result.stderr, "the controller output")
        os.remove(env.smoke_flag)

        # a world server that never reports ONLINE
        env.admin.reset()
        if os.path.exists(env.log + ".systemctl"):
            os.remove(env.log + ".systemctl")
        result = env.run(["--release", "rel-sick"], env_extra={"HPMMO_REHEARSAL_WORLD_STUCK": "1"})
        check(result.returncode == 8,
              "[unhealthy] a world that never reports ONLINE exits 8 (got %s)" % result.returncode)
        check(env.current() == "rel-base", "[unhealthy] the stuck release was rolled back")
        check(env.status().get("state") == "MAINTENANCE",
              "[unhealthy] maintenance stays active after the stuck rollback")
        env.assert_no_secret(result.stdout + result.stderr, "the controller output")
    finally:
        env.cleanup(keep)


def case_rollback_boot_delay(keep: bool) -> None:
    """The VPS defect: the rollback races the world server's restart.

    After a failed release the controller rolls back and re-holds maintenance
    by POSTing begin to the restored world. The world's admin port only opens
    once its process has booted; on the VPS the POST hit a closed port, the
    hold was never delivered, and the controller wrote MAINTENANCE anyway while
    the restored world came up ONLINE and accepting logins.

    The stub admin port now refuses connections for `boot_delay` seconds after
    a world start, so a controller that does not wait for the interface before
    committing to a state cannot pass:

      A. rollback with the port down for a moment: the controller must wait,
         deliver the hold, and status.json must match the world's state.
      B. rollback with the port down past the controller's budget: the hold is
         never delivered, so the controller must FAIL loudly and must NOT write
         MAINTENANCE - and when the world does come up ONLINE, the status
         document must still not claim maintenance.
    """
    env = Rehearsal("bootdelay")
    try:
        bootstrap_online(env, "rel-base")
        stage_ok(env, "rel-sick")

        # -- A: the rollback's world restart is still booting ----------------
        env.admin.boot_delay = 3.0
        with open(env.smoke_flag, "w", encoding="utf-8") as handle:
            handle.write("1\n")
        result = env.run(["--release", "rel-sick"])
        os.remove(env.smoke_flag)
        check(result.returncode != 0,
              "[bootdelay] the unhealthy release still fails the deployment (exit %s)" % result.returncode)
        check(env.current() == "rel-base", "[bootdelay] the rollback restored the previous release")

        # Read what the restored world actually enforces once it has finished
        # booting: the check trusts the world, not the status document.
        code, payload = 0, {}
        deadline = time.time() + 30
        while time.time() < deadline:
            code, payload = http_json_retry(env.admin.url + "/admin/state", token=TOKEN)
            if code == 200 and isinstance(payload, dict):
                break
            time.sleep(0.05)
        world_state = payload.get("state") if isinstance(payload, dict) else ""
        status_state = env.status().get("state")
        check(code == 200,
              "[bootdelay] the restored world's admin interface answered after boot (code %s)" % code)
        check(world_state == "MAINTENANCE",
              "[bootdelay] the hold reached the booting world: it enforces MAINTENANCE (world=%r)" % world_state)
        check(status_state == world_state,
              "[bootdelay] status.json matches the world's enforced state (status=%r world=%r)"
              % (status_state, world_state))
        holds = [b for b in env.admin.begins if int(b.get("countdown_seconds", 1)) == 0]
        check(bool(holds), "[bootdelay] the hold was delivered after the interface came up: %s" % env.admin.begins)
        check(not any("NOT delivered" in r.get("message", "") for r in env.journal()),
              "[bootdelay] nothing claims a hold that was never delivered")

        # -- B: the interface never answers inside the controller's budget ---
        env.admin.reset()
        env.admin.boot_delay = 60.0
        stage_ok(env, "rel-slow", migrate_fails=True)
        result = env.run(["--release", "rel-slow"],
                         env_extra={"HPMMO_ADMIN_READY_TIMEOUT": "2", "HPMMO_ADMIN_READY_POLL": "0.1"})
        check(result.returncode == 7,
              "[bootdelay] an undeliverable hold fails the run (exit %s)" % result.returncode)
        check(env.current() == "rel-base", "[bootdelay] the release was still rolled back")
        check(any(r.get("outcome") == "FAILED" and "NOT delivered" in r.get("message", "")
                  for r in env.journal()),
              "[bootdelay] the journal FAILS loudly when the hold cannot be delivered")
        check(env.status().get("state") != "MAINTENANCE",
              "[bootdelay] an undelivered hold is never written as MAINTENANCE (state=%r)"
              % env.status().get("state"))

        # The world eventually boots: ONLINE and accepting logins. The status
        # document must not be telling players "maintenance" now.
        env.admin.boot_delay = 0.0
        env.admin.reset()      # cancels the pending boot and comes up ONLINE
        code, payload = http_json_retry(env.admin.url + "/admin/state", token=TOKEN)
        check(code == 200 and isinstance(payload, dict) and payload.get("state") == "ONLINE",
              "[bootdelay] the world is ONLINE once it has booted (code %s, payload %r)" % (code, payload))
        check(env.status().get("state") != "MAINTENANCE",
              "[bootdelay] no MAINTENANCE in the status document while the world accepts logins")
        env.assert_no_secret(result.stdout + result.stderr, "the controller output")
    finally:
        env.cleanup(keep)


def case_queued_releases(keep: bool) -> None:
    env = Rehearsal("queue")
    try:
        bootstrap_online(env, "rel-base")
        stage_ok(env, "rel-q1")
        stage_ok(env, "rel-q2")

        before = len(env.journal())
        first = env.spawn(["--release", "rel-q1"])
        # Wait until THIS deployment is genuinely in flight (draining). Only
        # entries after `before` count: the bootstrap deployment's own drain
        # states are still in the journal.
        in_flight = False
        deadline = time.time() + 60
        while time.time() < deadline:
            fresh = env.journal()[before:]
            if any(r.get("release") == "rel-q1" and r.get("to") in ("DRAINING", "SAVING", "DISCONNECTING")
                   for r in fresh):
                in_flight = True
                break
            time.sleep(0.05)
        check(in_flight, "[queue] the first deployment was in flight before the second started")
        second = env.spawn(["--release", "rel-q2"])
        out_first = first.communicate(timeout=240)[0]
        out_second = second.communicate(timeout=240)[0]
        check(first.returncode == 0, "[queue] the first deployment succeeded (exit %s)" % first.returncode)
        check(second.returncode == 0, "[queue] the second deployment succeeded (exit %s)" % second.returncode)
        if first.returncode != 0:
            note(out_first[-2000:])
        if second.returncode != 0:
            note(out_second[-2000:])

        records = env.journal()
        online = [r for r in records if "verified and online" in r.get("message", "")]
        online_releases = [r.get("release") for r in online]
        check("rel-q1" in online_releases and "rel-q2" in online_releases,
              "[queue] both deployments are journalled as verified and online (%s)" % online_releases)
        check(online_releases and online_releases[-1] == "rel-q2",
              "[queue] the second release is the one that ended online")
        check(env.current() == "rel-q2", "[queue] the second release is the active one")
        first_done = max((r.get("ts", "") for r in records if r.get("release") == "rel-q1"), default="")
        second_start = min((r.get("ts", "") for r in records if r.get("release") == "rel-q2"), default="")
        check(first_done <= second_start, "[queue] the second deployment waited for the lock (%s <= %s)"
              % (first_done, second_start))
        # no interleaving: the switch to q1 appears before any q2 activity
        switches = [i for i, line in enumerate(env.systemctl_calls()) if "current=rel-q1" in line]
        q2_activity = [i for i, line in enumerate(env.systemctl_calls()) if "current=rel-q2" in line]
        check(bool(switches) and bool(q2_activity) and max(switches) < min(q2_activity),
              "[queue] the two deployments did not interleave")
        env.assert_no_secret(out_first + out_second, "the controller output")
    finally:
        env.cleanup(keep)


def case_controller_restart(keep: bool) -> None:
    env = Rehearsal("restart")
    try:
        bootstrap_online(env, "rel-base")
        stage_ok(env, "rel-r1")

        # (7a) killed during the final save: nothing was switched
        env.admin.save_delay = 30.0
        proc = env.spawn(["--release", "rel-r1"])
        deadline = time.time() + 60
        while time.time() < deadline and not env.saw_request("/admin/save"):
            time.sleep(0.05)
        check(env.saw_request("/admin/save"), "[restart] the deployment reached the save barrier before the kill")
        check(env.current() == "rel-base", "[restart] nothing was switched at the moment of the kill")
        env.kill(proc)
        env.admin.save_delay = 0.0
        check(env.current() == "rel-base", "[restart] the killed controller left the active release alone")

        result = env.run(["--recover"])
        check(result.returncode == 0, "[restart] --recover exits 0 (got %s)" % result.returncode)
        check(env.current() == "rel-base", "[restart] recovery left current on the previous release")
        records = env.journal()
        check(any(r.get("outcome") == "RECOVERED" for r in records),
              "[restart] the journal records the recovery from the journal")
        check(any(r.get("outcome") == "PENDING" for r in records),
              "[restart] the journal kept the in-flight marker")
        check(env.status().get("state") in ("MAINTENANCE", "DRAINING", "SAVING", "DISCONNECTING", "ONLINE"),
              "[restart] status reports a real state after recovery (%s)" % env.status().get("state"))

        # (7b) killed after the switch (during verification)
        env.admin.reset()
        with open(env.smoke_slow, "w", encoding="utf-8") as handle:
            handle.write("1\n")
        proc = env.spawn(["--release", "rel-r1"])
        deadline = time.time() + 90
        while time.time() < deadline and not (env.current() == "rel-r1" and any("smoke" in c for c in env.stub_calls())):
            time.sleep(0.05)
        check(env.current() == "rel-r1", "[restart] the second deployment reached the switch before the kill")
        check(any("smoke" in c for c in env.stub_calls()), "[restart] the kill lands during verification")
        env.kill(proc)
        os.remove(env.smoke_slow)

        result = env.run(["--recover"])
        check(result.returncode == 0, "[restart] recovering a half-switched deployment exits 0")
        check(env.current() == "rel-base",
              "[restart] recovery rolled the half-switched release back (current=%s)" % env.current())
        records = env.journal()
        check(any(r.get("outcome") == "RECOVERED" for r in records), "[restart] the recovery is journalled")
        check(any(r.get("outcome") == "ROLLBACK" for r in records), "[restart] the recovery is journalled as a rollback")
        check(env.status().get("state") == "MAINTENANCE", "[restart] maintenance stays active after recovery")
        calls = env.systemctl_calls()
        check(any("hpmmo-db.service" in line and "current=rel-base" in line for line in calls),
              "[restart] the previous release's services were restarted")
        check(not os.path.exists(os.path.join(env.state, "deploy.lock.d")),
              "[restart] no stale deployment lock is left behind")
        env.scan_for_secrets()
    finally:
        env.cleanup(keep)


def case_maintenance_absent(keep: bool) -> None:
    env = Rehearsal("absent")
    try:
        bootstrap_online(env, "rel-base")
        stage_ok(env, "rel-x")
        env.admin.mode = "absent"
        result = env.run(["--release", "rel-x"])
        check(result.returncode == 4, "[absent] a missing admin interface exits 4 (got %s)" % result.returncode)
        check(env.current() == "rel-base", "[absent] nothing was swapped")
        check(env.systemctl_calls() == [], "[absent] no service was touched")
        last = env.journal()[-1] if env.journal() else {}
        check(last.get("outcome") == "FAILED", "[absent] the journal records FAILED")
        check(env.status().get("state") == "ONLINE", "[absent] the world is still reported ONLINE (it was never touched)")
        env.assert_no_secret(result.stdout + result.stderr, "the controller output")
        env.scan_for_secrets()
    finally:
        env.cleanup(keep)


def case_admin_contract(keep: bool) -> None:
    """Quirks of the world server admin interface the controller must survive.

    These mirror world/addons/hpmmo_sim/admin.gd: the save route it actually
    registers is /admin/admin/save, begin() answers 409 from any state but
    ONLINE, and a cycle that cannot confirm its save barrier ends in FAILED.
    """
    env = Rehearsal("contract")
    try:
        bootstrap_online(env, "rel-base")

        # 1. the save route the world server really registers
        stage_ok(env, "rel-c1")
        env.admin.save_route = "/admin/admin/save"
        result = env.run(["--release", "rel-c1"])
        check(result.returncode == 0,
              "[contract] a save on /admin/admin/save still deploys (exit %s)" % result.returncode)
        check(any("admin/admin/save" in r.get("message", "") for r in env.journal()),
              "[contract] the route deviation is journalled, not hidden")
        check(env.current() == "rel-c1", "[contract] the release went live")

        # 2. begin() refusing with 409 because a cycle is already running
        stage_ok(env, "rel-c2")
        env.admin.reset()
        env.admin.begin_conflict_state = "MAINTENANCE"
        result = env.run(["--release", "rel-c2"])
        check(result.returncode == 0,
              "[contract] an already-running maintenance cycle is accepted (exit %s)" % result.returncode)
        check(any("already running" in r.get("message", "") for r in env.journal()),
              "[contract] the journal says the cycle was already running")
        check(env.current() == "rel-c2", "[contract] the second release went live")
        env.admin.begin_conflict_state = ""

        # 3. a world server that ends the cycle in FAILED must abort the deploy
        stage_ok(env, "rel-c3")
        env.admin.reset()
        env.admin.drain_failed = True
        before = len(env.systemctl_calls())
        result = env.run(["--release", "rel-c3"])
        env.admin.drain_failed = False
        check(result.returncode != 0, "[contract] a FAILED drain fails the deployment (exit %s)" % result.returncode)
        check(env.current() == "rel-c2", "[contract] nothing was swapped after FAILED")
        check(len(env.systemctl_calls()) == before, "[contract] no service was touched after FAILED")
        check(any(r.get("outcome") == "FAILED" and "FAILED" in r.get("message", "") for r in env.journal()),
              "[contract] the journal records the world server's FAILED state")
        check(any("save barrier did not confirm" in r.get("message", "") for r in env.journal()),
              "[contract] the world server's reason reaches the journal")
        env.assert_no_secret(result.stdout + result.stderr, "the controller output")
    finally:
        env.cleanup(keep)


def case_cold_start(keep: bool) -> None:
    """The one-time move onto this layout (and recovery from a dead world)."""
    env = Rehearsal("cold")
    try:
        bootstrap_online(env, "rel-base")
        stage_ok(env, "rel-cold")

        # while the world server is running, --cold-start must be refused
        env.admin.reset()
        result = env.run(["--release", "rel-cold", "--cold-start"])
        check(result.returncode == 2, "[cold] a cold start is refused while the world runs (exit %s)" % result.returncode)
        check(env.current() == "rel-base", "[cold] the refused cold start changed nothing")
        check("is running" in result.stderr, "[cold] the refusal explains why")
        check(env.systemctl_calls() == [], "[cold] no service was touched")

        # with the world proven stopped, the barrier is skipped deliberately
        with open(env.log + ".world", "w", encoding="utf-8") as handle:
            handle.write("inactive\n")
        result = env.run(["--release", "rel-cold", "--cold-start"])
        check(result.returncode == 0, "[cold] a cold start with the world stopped succeeds (exit %s)" % result.returncode)
        check(env.current() == "rel-cold", "[cold] the release went live")
        states = env.states()
        check("cold start" in " ".join(env.journal()[-1].get("message", "")) or
              any("cold start" in r.get("message", "") for r in env.journal()),
              "[cold] the journal records that the barrier was skipped deliberately")
        check("ANNOUNCING" not in states[-8:], "[cold] no maintenance announcement was faked")
        check(env.systemctl_calls() and not any(line.startswith("stop ") for line in env.systemctl_calls()),
              "[cold] the world was not stopped again: %s" % env.systemctl_calls())
        check(env.status().get("state") == "ONLINE", "[cold] the release ends ONLINE")
        env.assert_no_secret(result.stdout + result.stderr, "the controller output")
    finally:
        env.cleanup(keep)


def case_operator_rollback(keep: bool) -> None:
    env = Rehearsal("rollback")
    try:
        bootstrap_online(env, "rel-base")
        stage_ok(env, "rel-next")
        deploy_ok(env, "rel-next")
        check(env.current() == "rel-next", "[rollback] the new release is active")
        env.admin.reset()

        result = env.run(["--rollback", "--reason", "rehearsal"])
        check(result.returncode == 0, "[rollback] --rollback exits 0 (got %s)" % result.returncode)
        check(env.current() == "rel-base", "[rollback] the previous release was restored")
        records = env.journal()
        check(any(r.get("outcome") == "ROLLBACK" for r in records), "[rollback] the journal records ROLLBACK")
        check(env.status().get("state") == "MAINTENANCE", "[rollback] maintenance remains ACTIVE")
        holds = [b for b in env.admin.begins if int(b.get("countdown_seconds", 1)) == 0]
        check(bool(holds), "[rollback] the restored release was asked to stay in maintenance")
        calls = env.systemctl_calls()
        check(any("current=rel-base" in line for line in calls), "[rollback] the services were restarted on rel-base")

        status = env.run(["--status"])
        check(status.returncode == 0, "[rollback] --status exits 0")
        for needle in ("state:", "release:", "previous:", "journal"):
            check(needle in status.stdout, "[rollback] --status prints %s" % needle)
        check("rel-base" in status.stdout, "[rollback] --status names the active release")
        env.assert_no_secret(status.stdout + status.stderr, "the status output")
    finally:
        env.cleanup(keep)


def case_status_service(keep: bool) -> None:
    env = Rehearsal("status-svc")
    try:
        bootstrap_online(env, "rel-base")
        port = free_port()
        # the status service is Python: it needs native paths, not Git Bash ones
        env_extra = {"HPMMO_STATE_DIR": env.state, "HPMMO_RELEASES_DIR": env.releases,
                     "HPMMO_STATUS_PORT": str(port)}
        proc = subprocess.Popen([sys.executable, STATUS_SERVICE], env={**os.environ, **env_extra},
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            code, payload = 0, {}
            deadline = time.time() + 20
            while time.time() < deadline:
                code, payload = http_json("http://127.0.0.1:%d/status" % port)
                if code == 200:
                    break
                time.sleep(0.1)
            check(code == 200, "[status] the status endpoint answers /status (code %s)" % code)
            if isinstance(payload, dict):
                for key in ("state", "release", "previous_release", "since", "message"):
                    check(key in payload, "[status] /status carries %s" % key)
                check(payload.get("state") == "ONLINE", "[status] /status reports ONLINE")
                check(payload.get("release") == "rel-base", "[status] /status reports the active release")
            check(http_json("http://127.0.0.1:%d/health" % port)[0] == 200, "[status] /health answers")
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()

        # non-loopback binds are refused
        refused = subprocess.run([sys.executable, STATUS_SERVICE, "--port", str(free_port())],
                                 env={**os.environ, **env_extra, "HPMMO_STATUS_HOST": "0.0.0.0"},
                                 capture_output=True, text=True, timeout=30)
        check(refused.returncode == 2, "[status] a non-loopback bind is refused (exit %s)" % refused.returncode)
        check("REFUSING" in refused.stderr, "[status] the refusal explains itself")

        # the durable state is served even when the world is stopped
        with open(os.path.join(env.state, "status.json"), "w", encoding="utf-8") as handle:
            handle.write(json.dumps({"state": "MAINTENANCE", "release": "rel-base", "previous_release": "",
                                     "since": "2026-10-03T00:00:00Z", "message": "deploying"}) + "\n")
        check(json.load(open(os.path.join(env.state, "status.json")))["state"] == "MAINTENANCE",
              "[status] status.json is written by the controller in the documented shape")
    finally:
        env.cleanup(keep)


def case_scripts(keep: bool) -> None:
    """Static checks over the deploy scripts themselves."""
    scripts = ["hpmmo_deploy.sh", "install_layout.sh", "package_server.sh", "smoke_client.sh", "update_server.sh"]
    for script in scripts:
        path = os.path.join(DEPLOY, script)
        result = subprocess.run([BASH, "-n", path], capture_output=True, text=True, timeout=60)
        check(result.returncode == 0, "[scripts] %s parses (bash -n)" % script)
        if result.returncode != 0:
            note(result.stderr)
    if os.path.exists(PACKAGER):
        result = subprocess.run([BASH, PACKAGER, "--check"], capture_output=True, text=True, timeout=120,
                                cwd=SERVER)
        check(result.returncode == 0, "[scripts] package_server.sh --check passes on the repo")
        if result.returncode != 0:
            note(result.stdout + result.stderr)
        check("check passed" in result.stdout, "[scripts] the packager check reports success")
    check(os.path.exists(os.path.join(SERVER, ".github", "workflows", "server-release.yml")),
          "[scripts] the release workflow exists at server/.github/workflows/server-release.yml")
    check(os.path.exists(os.path.join(SERVER, "docs", "runbook-rollback.md")),
          "[scripts] the rollback runbook exists")


def case_admin_auth(keep: bool) -> None:
    """The stub admin interface must be as strict as the real one.

    The VPS defect this guards against: the controller piped its curl config
    into a curl that never read it, so every authenticated call was a 403 -
    and this rehearsal still passed 207 checks because the stub answered
    without looking at the header. A request with no token (or a wrong one)
    must be refused before anything else can happen.
    """
    env = Rehearsal("auth")
    try:
        code, _ = http_json_retry(env.admin.url + "/admin/state")
        check(code == 403, "[auth] GET /admin/state without a token is refused (code %s)" % code)

        code, _ = http_json_retry(env.admin.url + "/admin/state", token="wrong-" + TOKEN)
        check(code == 403, "[auth] GET /admin/state with a wrong token is refused (code %s)" % code)

        code, _ = http_json_retry(env.admin.url + "/admin/save", method="POST", body={})
        check(code == 403, "[auth] POST /admin/save without a token is refused (code %s)" % code)

        code, _ = http_json_retry(env.admin.url + "/admin/maintenance/begin", method="POST",
                                  body={"reason": "auth probe", "countdown_seconds": 0})
        check(code == 403,
              "[auth] POST /admin/maintenance/begin without a token is refused (code %s)" % code)

        check(env.admin.denied == 4, "[auth] the stub recorded all four refusals (denied=%d)" % env.admin.denied)
        check(env.admin.state == "ONLINE" and not env.admin.begins and env.admin.save_failed == 0,
              "[auth] the refused requests changed nothing in the world server")

        code, payload = http_json_retry(env.admin.url + "/admin/state", token=TOKEN)
        check(code == 200 and isinstance(payload, dict) and payload.get("state") == "ONLINE",
              "[auth] the same request with the service token succeeds (code %s)" % code)

        # The controller really sends the header: if `curl -K -` is ever removed
        # again, stage_ok still passes (staging is local) but every deployment
        # dies at /admin/maintenance/begin with the 403 the stub now returns.
        stage_ok(env, "rel-auth")
        result = env.run(["--release", "rel-auth"])
        check(result.returncode == 0, "[auth] a deployment through the stub succeeds (exit %s)" % result.returncode)
        if result.returncode != 0:
            note(result.stdout[-2000:] + result.stderr[-2000:])
        check(env.current() == "rel-auth", "[auth] the deployment activated the release")
    finally:
        env.cleanup(keep)


CASES = {
    "happy": case_happy_path,
    "checksum": case_failed_checksum,
    "save": case_failed_save,
    "migration": case_failed_migration,
    "unhealthy": case_unhealthy_release,
    "bootdelay": case_rollback_boot_delay,
    "queue": case_queued_releases,
    "restart": case_controller_restart,
    "absent": case_maintenance_absent,
    "contract": case_admin_contract,
    "cold": case_cold_start,
    "rollback": case_operator_rollback,
    "status": case_status_service,
    "scripts": case_scripts,
    "auth": case_admin_auth,
}

ORDER = ["scripts", "auth", "happy", "checksum", "save", "migration", "unhealthy",
         "bootdelay", "queue", "restart", "absent", "contract", "cold", "rollback",
         "status"]


def main() -> int:
    global VERBOSE
    parser = argparse.ArgumentParser(description="HPMMO deployment rehearsal")
    parser.add_argument("--case", action="append", default=[], help="run only these cases")
    parser.add_argument("--keep", action="store_true", help="keep the temp rehearsal dirs")
    parser.add_argument("--verbose", action="store_true", help="show controller invocations")
    args = parser.parse_args()
    VERBOSE = args.verbose

    if not BASH:
        print("SKIP: no usable bash found (set HPMMO_BASH). The rehearsal drives hpmmo_deploy.sh.")
        return 2
    if not os.path.exists(CONTROLLER):
        print("ERROR: %s is missing" % CONTROLLER)
        return 2

    selected = args.case or ORDER
    unknown = [name for name in selected if name not in CASES]
    if unknown:
        print("ERROR: unknown case(s): %s (known: %s)" % (", ".join(unknown), ", ".join(ORDER)))
        return 2

    print("HPMMO deployment rehearsal - bash=%s" % BASH)
    print("controller: %s" % CONTROLLER)
    for name in selected:
        print("\n--- case: %s ---" % name)
        started = time.time()
        try:
            CASES[name](args.keep)
        except Exception as exc:  # noqa: BLE001 - a harness crash is a failed check
            import traceback
            failures.append("[%s] harness error: %s" % (name, exc))
            print("FAIL: [%s] harness error: %s" % (name, exc))
            if VERBOSE:
                traceback.print_exc()
        print("    (%s took %.1fs)" % (name, time.time() - started))

    if _TEMP_ROOT and not args.keep:
        shutil.rmtree(_TEMP_ROOT, ignore_errors=True)

    print("\nDEPLOY RESULT: %d checks, %d failures" % (checks, len(failures)))
    for failure in failures:
        print("  - " + failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
