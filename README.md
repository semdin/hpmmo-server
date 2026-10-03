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

## Quick start

From the workspace root:

```powershell
.\dev.ps1 test          # service compile + smoke + world boot smoke
.\dev.ps1 build         # package a deployable release into server\dist
.\dev.ps1 sync-world    # re-export world/ from the client project
.\dev.ps1 verify-contracts
```

## Security posture (current reality - see plan.md defects B3/B4)

- The service has **no authentication on data endpoints yet** and binds `0.0.0.0` - do not expose port 8081 publicly until the Phase 4 rewrite. The trade route is disabled (503).
- Database credentials come from the environment (`deploy/hpmmo.env.example`); no secrets live in this repository or its history.
