# HPMMO Server

Server-side repository for HPMMO

## Layout

| Path | Purpose |
| --- | --- |
| `world/` | Authoritative Godot world project (exported, hash-pinned snapshot of the client project until the authority inverts ownership - see `world/WORLD_EXPORT.json`) |
| `services/` | Python account/persistence service (`db_service.py`) - replaced by the C++ service in the server integration |
| `db/migrations/` | SQL schema migrations (PostgreSQL target) |
| `contracts/` | Protocol + gameplay schema contracts owned by the server; pinned in `workspace.lock.json` |
| `deploy/` | Provisioning, deployment, and packaging scripts; environment template |
| `tests/` | `smoke_service.py` - boots the service against temp SQLite and pins the current API behavior |

## Services

| Service | Status | Notes |
| --- | --- | --- |
| `services/cpp/` | **Primary (Server integration/5)** | C++17 service: argon2id, sessions (carrying the ticket-bound character), ownership checks, one-time game tickets, idempotent rewards/trades, service-token session introspection and character access for the authority world server, numbered PostgreSQL migrations, readiness that verifies the schema level. Vendored deps are hash-pinned in `services/cpp/vendor/PROVENANCE.md`; API contract in `contracts/api.md`. |
| `services/db_service.py` | Legacy fallback | The original stdlib-Python service (unauthenticated; trade disabled). Kept for reference while the client adopts the new API; do not expose publicly. |

### Building the C++ service (Windows, from a fresh checkout)

```powershell
cmake -S services/cpp -B services/cpp/build -G Ninja -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_BUILD_TYPE=Release -DPG_ROOT=<postgres-binaries-root>
ninja -C services/cpp/build
```

`<postgres-binaries-root>` is a PostgreSQL 17 binaries tree (EDB "binaries only" zip). The build
links libpq, and `deploy/` ships the runtime DLL chain next to the exe. One-time preparation of
a MinGW-compatible import library (MSVC `libpq.lib` carries linker directives MinGW rejects):

```bash
llvm-readobj --coff-exports <pg>/bin/libpq.dll | grep '^  Name:' | sed 's/^  Name: //' | sort -u > libpq.def  # after a LIBRARY/EXPORTS header
llvm-dlltool -m i386:x86-64 -D libpq.dll -d libpq.def -l <pg>/lib/libpq.a
```

### Database (development)

Point `DATABASE_URL` at any PostgreSQL; `hpmmo_service migrate` applies `db/migrations/`. A
self-contained local cluster (no installer) works: extract the EDB binaries, `initdb -D pgdata
-U hpmmo --pwfile=...`, `pg_ctl -D pgdata -o "-p 55432" start`, `createdb hpmmo_dev`.

`tests/integration_api.py` manages its own cluster lifecycle and throwaway database. Outside
the standard workspace layout it needs two environment variables, or it SKIPs (exit 2) with
instructions: `HPMMO_PG_ROOT` (a PostgreSQL 17 binaries tree; default: the workspace sibling
`_tools/pgsql`) and `HPMMO_PG_PASSWORD` (default: `tests/.pg-dev.pw`, which is untracked).

## Quick start

From the workspace root:

```powershell
.\dev.ps1 test          # client harness + C++ service build + persistence integration tests + world boot
.\dev.ps1 build         # build the service, then package a deployable release into server\dist
.\dev.ps1 sync-world    # re-export world/ from the client project
.\dev.ps1 verify-contracts
```

## World server (Authority)

`world/server/world_server.tscn` is the headless authoritative server. It boots the
exported world, owns every gameplay decision, and is the only process that talks to
the account service.

```powershell
godot --headless --path world res://server/world_server.tscn
```

| Variable | Purpose |
| --- | --- |
| `HPMMO_WORLD_PORT` | UDP port (default 7777) |
| `HPMMO_WORLD_SEED` | RNG seed for encounters (logged at boot; same seed = same spawns) |
| `HPMMO_API_URL` / `HPMMO_SERVICE_TOKEN` | account service; **without them the server runs unauthenticated and session-only**, and refuses joins unless the dev opt-in below is set |
| `HPMMO_NET_PROFILE` | latency/loss test profile (`local`, `broadband`, `mobile`, `awful`) |

### Development-only switches (never set these in production)

| Variable | Effect |
| --- | --- |
| `HPMMO_ALLOW_DEV_JOIN=1` | accepts joins with no auth backend; the join token is used as a display name |
| `HPMMO_DEV_SPAWN="x,y,z"` | places dev joins at a fixed point (used by the multiplayer tests) |
| `HPMMO_DEV_FAST_RESPAWN=<ms>` | compresses respawn timers so tests can observe respawns |

## Security posture (Server integration)

- The **C++ service** enforces argon2id passwords, expiring sessions, per-account ownership on
  every character endpoint, validated/atomic/idempotent trades and rewards, and refuses to run
  data endpoints without a database (no SQLite fallback). Bind address defaults to
  `127.0.0.1`; expose it only behind the firewall with `HPMMO_SERVICE_TOKEN` set.
- The **service token** is infrastructure-only (`X-Service-Token`): it unlocks session
  introspection and unscoped character load/save for the trusted world server. It must never
  reach a client (launcher/game build) or a log; a holder can read and write every character.
- The **legacy Python service** (`services/db_service.py`) still exists for reference and has
  **none of these protections** - it must not be deployed alongside the new service.
- The **world server** (Authority) is the only holder of the service token; the game client only
  redeems a one-time ticket and never sees a database credential. Clients send intents that the
  server validates; clients cannot address each other
  (`server_relay` is off) and cannot mint server-authority messages.
- Database credentials and the service token come from the environment
  (`deploy/hpmmo.env.example`); no secrets live in this repository or its history.
