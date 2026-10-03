#!/usr/bin/env python3
"""HPMMO deployment status endpoint (plan.md Phase 6).

Answers the launcher's question "is the server in maintenance, or just
unreachable?" while the world server is stopped:

    GET /status -> {"state": "...", "release": "...", "previous_release": "...",
                    "since": "...", "message": "..."}
    GET /health -> {"status": "ok", "service": "hpmmo-status"}

It reads the state document written by deploy/hpmmo_deploy.sh
($HPMMO_STATE_DIR/status.json) and never talks to the world server, so it keeps
answering while releases are being switched.

Binding: 127.0.0.1 only by default. This service must never be exposed
publicly; a non-loopback bind is refused unless HPMMO_STATUS_ALLOW_NONLOOPBACK=1
is set explicitly (that flag exists for unusual deployments, not for
production).

Environment:
    HPMMO_STATE_DIR      deployment state dir          (default /opt/hpmmo/state)
    HPMMO_RELEASES_DIR   releases dir, for `current`   (default /opt/hpmmo/releases)
    HPMMO_STATUS_HOST    bind address                  (default 127.0.0.1)
    HPMMO_STATUS_PORT    bind port                     (default 8083)

Usage:
    hpmmo_status.py                 serve
    hpmmo_status.py --check         print the current status document and exit
    hpmmo_status.py --port 8083     override the port
"""

from __future__ import annotations

import json
import os
import signal
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_DIR = os.environ.get("HPMMO_STATE_DIR", "/opt/hpmmo/state")
RELEASES_DIR = os.environ.get("HPMMO_RELEASES_DIR", os.environ.get("RELEASES_DIR", "/opt/hpmmo/releases"))
HOST = os.environ.get("HPMMO_STATUS_HOST", "127.0.0.1")
PORT = int(os.environ.get("HPMMO_STATUS_PORT", "8083"))
ALLOW_NONLOOPBACK = os.environ.get("HPMMO_STATUS_ALLOW_NONLOOPBACK", "0") == "1"

LOOPBACK_NAMES = {"127.0.0.1", "localhost", "::1", "[::1]"}

EMPTY_STATUS = {
    "state": "UNKNOWN",
    "release": "",
    "previous_release": "",
    "since": "",
    "message": "",
}


def read_status() -> dict:
    """Returns the status document. Falls back to a synthesised one so the
    launcher can still tell 'maintenance' from 'never deployed'."""
    path = os.path.join(STATE_DIR, "status.json")
    status = dict(EMPTY_STATUS)
    try:
        with open(path, encoding="utf-8") as handle:
            loaded = json.load(handle)
        for key in EMPTY_STATUS:
            value = loaded.get(key)
            if isinstance(value, (str, int)) and not isinstance(value, bool):
                status[key] = str(value)
    except (OSError, ValueError):
        pass
    if not status["release"]:
        status["release"] = current_release()
    if status["state"] == "UNKNOWN" and os.path.exists(os.path.join(STATE_DIR, "maintenance.flag")):
        state = read_flag_state()
        if state:
            status["state"] = state
    return status


def current_release() -> str:
    try:
        target = os.path.realpath(os.path.join(RELEASES_DIR, "current"))
    except OSError:
        return ""
    if not target or not os.path.isdir(target):
        return ""
    return os.path.basename(target.rstrip("/"))


def read_flag_state() -> str:
    """state/maintenance.flag is written while maintenance is active; when a
    deployment is interrupted it may be the only durable hint left."""
    path = os.path.join(STATE_DIR, "maintenance.flag")
    if not os.path.exists(path):
        return ""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        state = data.get("state")
        if isinstance(state, str) and state:
            return state
    except (OSError, ValueError):
        pass
    return "MAINTENANCE"


class Handler(BaseHTTPRequestHandler):
    server_version = "hpmmo-status/1.0"

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path in ("/status", "/"):
            self._send(200, read_status())
        elif path == "/health":
            self._send(200, {"status": "ok", "service": "hpmmo-status"})
        else:
            self._send(404, {"status": "not found", "paths": ["/status", "/health"]})

    def log_message(self, fmt: str, *args) -> None:  # keep the journal free of noise
        sys.stderr.write("[hpmmo-status] %s - %s\n" % (self.address_string(), fmt % args))


def check_bind_address() -> None:
    if HOST in LOOPBACK_NAMES:
        return
    try:
        if HOST and socket.gethostbyname(HOST).startswith("127."):
            return
    except OSError:
        pass
    if ALLOW_NONLOOPBACK:
        sys.stderr.write("[hpmmo-status] WARNING: binding %s:%d (non-loopback, explicitly allowed)\n" % (HOST, PORT))
        return
    sys.stderr.write(
        "[hpmmo-status] REFUSING to bind %s:%d: the status endpoint must stay on loopback.\n"
        "               Set HPMMO_STATUS_ALLOW_NONLOOPBACK=1 only if you really mean it.\n" % (HOST, PORT)
    )
    raise SystemExit(2)


def main(argv: list[str]) -> int:
    global HOST, PORT
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == "--check":
            print(json.dumps(read_status(), indent=2))
            return 0
        if arg == "--host":
            HOST = args.pop(0) if args else HOST
        elif arg.startswith("--host="):
            HOST = arg.split("=", 1)[1]
        elif arg == "--port":
            PORT = int(args.pop(0)) if args else PORT
        elif arg.startswith("--port="):
            PORT = int(arg.split("=", 1)[1])
        elif arg in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            sys.stderr.write("unknown argument: %s\n" % arg)
            return 2

    check_bind_address()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True

    def stop(_signum, _frame):
        raise SystemExit(0)

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(sig, stop)
        except (ValueError, OSError):
            pass

    sys.stderr.write("[hpmmo-status] serving http://%s:%d/status (state dir %s)\n" % (HOST, PORT, STATE_DIR))
    try:
        server.serve_forever()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
