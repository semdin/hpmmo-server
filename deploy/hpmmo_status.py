#!/usr/bin/env python3
"""HPMMO deployment status + client release endpoint (plan.md Phases 6 and 7).

Answers the launcher's two questions:

  1. "is the server in maintenance, or just unreachable?"
         GET /status -> {"state": "...", "release": "...", "previous_release": "...",
                         "since": "...", "message": "..."}
         GET /health -> {"status": "ok", "service": "hpmmo-status"}

  2. "which client release does this channel serve, and may I download it?"
         GET /releases/channels/<channel>/manifest.json      (+ .sig, .keyid, SHA256SUMS)
         GET /releases/hpmmo-client-<version>-<platform>.zip (+ .zip.sha256)

It reads the state document written by deploy/hpmmo_deploy.sh
($HPMMO_STATE_DIR/status.json) and never talks to the world server, so it keeps
answering while releases are being switched.

TLS (Phase 7). /releases is the update path, so it is served over TLS with a
certificate the launcher pins by SPKI sha256 (deploy/tls/make_cert.sh prints the
pin). The certificate is deliberately self-signed: pinning is stronger than any
CA chain, and it removes the hostname/CA dependency. A cleartext request for
/releases from a NON-loopback peer is refused - an artifact fetched over plain
HTTP is an artifact an attacker on the path can replace, signature or not.

Binding: 127.0.0.1 only by default. This service must never be exposed
publicly without TLS; a non-loopback bind is refused unless
HPMMO_STATUS_ALLOW_NONLOOPBACK=1 is set explicitly, and the project's rule is
that the flag is set together with HPMMO_STATUS_TLS_CERT/KEY (see
docs/phase7-release-contract.md for the exact change and the firewall rule).

Environment:
    HPMMO_STATE_DIR          deployment state dir      (default /opt/hpmmo/state)
    HPMMO_RELEASES_DIR       server releases dir, for `current`
    HPMMO_STATUS_HOST        bind address              (default 127.0.0.1)
    HPMMO_STATUS_PORT        bind port                (default 8083)
    HPMMO_STATUS_RELEASES_ROOT  read-only client release root
                                                      (default /srv/hpmmo/client-releases)
    HPMMO_STATUS_TLS_CERT    certificate (PEM); enables HTTPS when both are set
    HPMMO_STATUS_TLS_KEY     private key (PEM), mode 600
    HPMMO_STATUS_ALLOW_NONLOOPBACK=1  allow a non-loopback bind

Usage:
    hpmmo_status.py                 serve
    hpmmo_status.py --check         print the current status document and exit
    hpmmo_status.py --print-pin     print the SPKI sha256 of the TLS certificate
    hpmmo_status.py --port 8083     override the port
"""

from __future__ import annotations

import hashlib
import json
import os
import posixpath
import signal
import socket
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_DIR = os.environ.get("HPMMO_STATE_DIR", "/opt/hpmmo/state")
RELEASES_DIR = os.environ.get("HPMMO_RELEASES_DIR", os.environ.get("RELEASES_DIR", "/opt/hpmmo/releases"))
HOST = os.environ.get("HPMMO_STATUS_HOST", "127.0.0.1")
PORT = int(os.environ.get("HPMMO_STATUS_PORT", "8083"))
ALLOW_NONLOOPBACK = os.environ.get("HPMMO_STATUS_ALLOW_NONLOOPBACK", "0") == "1"
RELEASES_ROOT = os.environ.get("HPMMO_STATUS_RELEASES_ROOT", "/srv/hpmmo/client-releases")
TLS_CERT = os.environ.get("HPMMO_STATUS_TLS_CERT", "")
TLS_KEY = os.environ.get("HPMMO_STATUS_TLS_KEY", "")

LOOPBACK_NAMES = {"127.0.0.1", "localhost", "::1", "[::1]"}

# Content types for the release root. Anything else is served as a download.
CONTENT_TYPES = {
    ".json": "application/json",
    ".sig": "text/plain; charset=ascii",
    ".keyid": "application/json",
    ".txt": "text/plain; charset=utf-8",
    ".zip": "application/zip",
    ".sha256": "text/plain; charset=ascii",
    ".pem": "application/x-pem-file",
}

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


def release_file(relpath: str) -> str | None:
    """Maps /releases/<relpath> to a file under RELEASES_ROOT, or None when the
    request must be refused. Refuses traversal, dotfiles, directories and
    anything that resolves outside the root."""
    relpath = posixpath.normpath("/" + relpath.strip("/")).lstrip("/")
    if not relpath or relpath in (".", ".."):
        return None
    parts = relpath.split("/")
    if any(part in ("", ".", "..") or part.startswith(".") for part in parts):
        return None
    root = os.path.realpath(RELEASES_ROOT)
    candidate = os.path.realpath(os.path.join(root, *parts))
    if candidate != root and not candidate.startswith(root + os.sep):
        return None
    if not os.path.isfile(candidate):
        return None
    return candidate


def spki_sha256_of_certificate(cert_path: str) -> str:
    """sha256 of the DER SubjectPublicKeyInfo of the certificate - the value
    the launcher pins, printed by deploy/tls/make_cert.sh.

    Computed with the OpenSSL CLI, which is the same tool that generated the
    certificate: one implementation of the pin, not two that could disagree."""
    import subprocess
    try:
        public_key = subprocess.run(
            ["openssl", "x509", "-in", cert_path, "-noout", "-pubkey"],
            capture_output=True, check=True).stdout
        der = subprocess.run(
            ["openssl", "pkey", "-pubin", "-outform", "DER"],
            input=public_key, capture_output=True, check=True).stdout
    except FileNotFoundError as exc:
        raise ValueError("openssl is not available to compute the pin: %s" % exc) from exc
    except subprocess.CalledProcessError as exc:
        raise ValueError("openssl could not read %s: %s"
                         % (cert_path, exc.stderr.decode("utf-8", "replace").strip())) from exc
    if not der:
        raise ValueError("openssl produced no public key for %s" % cert_path)
    return hashlib.sha256(der).hexdigest()


class Handler(BaseHTTPRequestHandler):
    server_version = "hpmmo-status/1.1"
    # HTTP/1.1 with an explicit Content-Length on every response: the launcher
    # reuses connections when it checks several files in a row.
    protocol_version = "HTTP/1.1"

    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _peer_is_loopback(self) -> bool:
        try:
            peer = self.client_address[0]
        except (IndexError, TypeError):
            return False
        if peer in ("127.0.0.1", "::1", "localhost"):
            return True
        try:
            return socket.gethostbyname(peer).startswith("127.")
        except OSError:
            return False

    def _is_tls(self) -> bool:
        return isinstance(self.request, ssl.SSLSocket)

    def _serve_release(self, relpath: str) -> None:
        if not self._is_tls() and not self._peer_is_loopback():
            self._json(403, {"status": "refused",
                             "message": "the release root is only served over TLS",
                             "hint": "the launcher pins the certificate; plain HTTP would be replaceable"})
            return
        path = release_file(relpath)
        if path is None:
            self._json(404, {"status": "not found", "path": "/releases/" + relpath.lstrip("/")})
            return
        size = os.path.getsize(path)
        extension = os.path.splitext(path)[1].lower()
        content_type = CONTENT_TYPES.get(extension, "application/octet-stream")
        # Artifacts are immutable and content-addressed by their name, so they
        # may be cached hard; manifests must be re-read on every check.
        cache = ("public, max-age=31536000, immutable" if extension in (".zip", ".sha256")
                 else "no-store")
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(path, "rb") as handle:
            while True:
                chunk = handle.read(64 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)

    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        path = self.path.split("?", 1)[0]
        normalized = path.rstrip("/") or "/"
        if normalized in ("/status", "/"):
            self._json(200, read_status())
        elif normalized == "/health":
            self._json(200, {"status": "ok", "service": "hpmmo-status",
                             "tls": self._is_tls()})
        elif normalized == "/tls/spki":
            if not TLS_CERT:
                self._json(404, {"status": "no tls certificate configured"})
            else:
                try:
                    self._json(200, {"spki_sha256": spki_sha256_of_certificate(TLS_CERT),
                                     "cert": os.path.basename(TLS_CERT)})
                except (OSError, ValueError) as exc:
                    self._json(500, {"status": "cannot read the certificate", "error": str(exc)})
        elif path.startswith("/releases/"):
            self._serve_release(path[len("/releases/"):])
        else:
            self._json(404, {"status": "not found",
                             "paths": ["/status", "/health", "/tls/spki", "/releases/<file>"]})

    def do_HEAD(self) -> None:  # noqa: N802 (http.server API)
        # The launcher HEADs an artifact before downloading it: resume support
        # and disk-space checks need the size without the bytes.
        self.do_GET()

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
    if ALLOW_NONLOOPBACK and TLS_CERT and TLS_KEY:
        sys.stderr.write("[hpmmo-status] WARNING: binding %s:%d (non-loopback, TLS, explicitly allowed)\n" % (HOST, PORT))
        return
    if ALLOW_NONLOOPBACK and not (TLS_CERT and TLS_KEY):
        sys.stderr.write(
            "[hpmmo-status] REFUSING to bind %s:%d: HPMMO_STATUS_ALLOW_NONLOOPBACK=1 is set but no\n"
            "               TLS certificate is configured (HPMMO_STATUS_TLS_CERT/HPMMO_STATUS_TLS_KEY).\n"
            "               A public status/release endpoint must serve HTTPS.\n" % (HOST, PORT)
        )
        raise SystemExit(2)
    sys.stderr.write(
        "[hpmmo-status] REFUSING to bind %s:%d: the status endpoint must stay on loopback.\n"
        "               Set HPMMO_STATUS_ALLOW_NONLOOPBACK=1 only if you really mean it.\n" % (HOST, PORT)
    )
    raise SystemExit(2)


def build_tls_context(cert: str, key: str) -> ssl.SSLContext:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(certfile=cert, keyfile=key)
    return context


def main(argv: list[str]) -> int:
    global HOST, PORT, TLS_CERT, TLS_KEY, RELEASES_ROOT
    mode = "serve"
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == "--check":
            mode = "check"
        elif arg == "--print-pin":
            mode = "print-pin"
        elif arg == "--host":
            HOST = args.pop(0) if args else HOST
        elif arg.startswith("--host="):
            HOST = arg.split("=", 1)[1]
        elif arg == "--port":
            PORT = int(args.pop(0)) if args else PORT
        elif arg.startswith("--port="):
            PORT = int(arg.split("=", 1)[1])
        elif arg == "--tls-cert":
            TLS_CERT = args.pop(0) if args else TLS_CERT
        elif arg.startswith("--tls-cert="):
            TLS_CERT = arg.split("=", 1)[1]
        elif arg == "--tls-key":
            TLS_KEY = args.pop(0) if args else TLS_KEY
        elif arg.startswith("--tls-key="):
            TLS_KEY = arg.split("=", 1)[1]
        elif arg == "--releases-root":
            RELEASES_ROOT = args.pop(0) if args else RELEASES_ROOT
        elif arg.startswith("--releases-root="):
            RELEASES_ROOT = arg.split("=", 1)[1]
        elif arg in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            sys.stderr.write("unknown argument: %s\n" % arg)
            return 2

    if mode == "check":
        print(json.dumps(read_status(), indent=2))
        return 0
    if mode == "print-pin":
        if not TLS_CERT:
            sys.stderr.write("no --tls-cert/HPMMO_STATUS_TLS_CERT configured\n")
            return 2
        try:
            print(spki_sha256_of_certificate(TLS_CERT))
        except (OSError, ValueError) as exc:
            sys.stderr.write("cannot compute the pin: %s\n" % exc)
            return 2
        return 0

    check_bind_address()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True

    scheme = "http"
    if TLS_CERT or TLS_KEY:
        if not (TLS_CERT and TLS_KEY):
            sys.stderr.write("[hpmmo-status] --tls-cert and --tls-key must be given together\n")
            return 2
        for path in (TLS_CERT, TLS_KEY):
            if not os.path.isfile(path):
                sys.stderr.write("[hpmmo-status] TLS file %s does not exist\n" % path)
                return 2
        try:
            server.socket = build_tls_context(TLS_CERT, TLS_KEY).wrap_socket(server.socket, server_side=True)
        except (ssl.SSLError, OSError) as exc:
            sys.stderr.write("[hpmmo-status] cannot enable TLS: %s\n" % exc)
            return 2
        scheme = "https"

    def stop(_signum, _frame):
        raise SystemExit(0)

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(sig, stop)
        except (ValueError, OSError):
            pass

    sys.stderr.write("[hpmmo-status] serving %s://%s:%d/status (state dir %s)\n"
                     % (scheme, HOST, PORT, STATE_DIR))
    if os.path.isdir(RELEASES_ROOT):
        sys.stderr.write("[hpmmo-status] release root %s is served at /releases/\n" % RELEASES_ROOT)
        if TLS_CERT:
            try:
                sys.stderr.write("[hpmmo-status] pinned SPKI sha256: %s\n"
                                 % spki_sha256_of_certificate(TLS_CERT))
            except (OSError, ValueError):
                pass
    else:
        sys.stderr.write("[hpmmo-status] release root %s does not exist; /releases/ answers 404\n" % RELEASES_ROOT)
    try:
        server.serve_forever()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
