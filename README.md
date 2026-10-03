# HPMMO Server

Server-side repository for HPMMO (see `docs/../client/docs/plan.md` in the workspace for the roadmap; the canonical copy of `plan.md` lives in the client repository after the Phase 3 migration).

## Layout

| Path | Purpose |
| --- | --- |
| `world/` | Authoritative Godot world project (exported, hash-pinned snapshot of the client project until Phase 5 inverts ownership - see `world/WORLD_EXPORT.json`) |
| `services/` | Python account/persistence service (`db_service.py`) - replaced by the C++ service in Phase 4 |
| `db/migrations/` | SQL schema migrations (PostgreSQL target) |
| `contracts/` | Protocol + gameplay schema contracts owned by the server; pinned in `workspace.lock.json` |
| `deploy/` | Provisioning, deployment, and packaging scripts; environment template |
| `tests/` | `smoke_service.py` - boots the service against temp SQLite and pins the current API behavior |

## Services

| Service | Status | Notes |
| --- | --- | --- |
| `services/cpp/` | **Primary (Phase 4)** | C++17 service: argon2id, sessions, ownership checks, one-time game tickets, idempotent rewards/trades, numbered PostgreSQL migrations, readiness that verifies the schema level. Vendored deps are hash-pinned in `services/cpp/vendor/PROVENANCE.md`; API contract in `contracts/api.md`. |
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
`tests/integration_api.py` manages its own cluster lifecycle and throwaway database.

## Quick start

From the workspace root:

```powershell
.\dev.ps1 test          # client harness + C++ service build + Phase 4 integration tests + world boot
.\dev.ps1 build         # build the service, then package a deployable release into server\dist
.\dev.ps1 sync-world    # re-export world/ from the client project
.\dev.ps1 verify-contracts
```

## Security posture (Phase 4)

- The **C++ service** enforces argon2id passwords, expiring sessions, per-account ownership on
  every character endpoint, validated/atomic/idempotent trades and rewards, and refuses to run
  data endpoints without a database (no SQLite fallback). Bind address defaults to
  `127.0.0.1`; expose it only behind the firewall with `HPMMO_SERVICE_TOKEN` set.
- The **legacy Python service** (`services/db_service.py`) still exists for reference and has
  **none of these protections** - it must not be deployed alongside the new service.
- Database credentials and the service token come from the environment
  (`deploy/hpmmo.env.example`); no secrets live in this repository or its history.
