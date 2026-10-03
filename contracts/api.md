# HPMMO Service API contract (Phase 4)

Base URL: `http://<host>:8081`. JSON in/out. Two auth mechanisms:

- **Session** - `Authorization: Bearer <token>` from `/api/login` or `/api/ticket/redeem`.
- **Service token** - `X-Service-Token: <HPMMO_SERVICE_TOKEN>` for machine-to-machine endpoints
  (the authoritative world server in Phase 5). Refused when unconfigured.

Errors return `{"success": false, "message": "..."}`. Notable statuses: 400 validation,
401 session invalid/expired/revoked, 403 wrong/missing service token, 404 not found *or not
yours* (ownership failures never disclose existence), 409 constraint (duplicate name, stale
revision), 410 consumed/expired ticket, 503 database unavailable (no fallback backend) or
`"status":"uncertain"` with `op_id` when a commit outcome is unknown (retry with the same op_id).

## Public

| Endpoint | Auth | Body -> Response |
| --- | --- | --- |
| `GET /api/health` | - | liveness: `{status:"ok", service, time}` |
| `GET /api/ready` | - | readiness: verifies DB reachability + required migration level. 200 `{status:"ready", db:"postgresql", schema:N}` or 503 `{status:"unavailable", ...}` |
| `GET /api/version` | - | service `version.json` (game_title, min_client_version, ...) |
| `POST /api/register` | - | `{username, password}` -> `{success, account_id}`; policy: 3-24 chars `[A-Za-z0-9_-]`, password >=8 with letters and digits |
| `POST /api/login` | - | `{username, password}` -> `{success, account_id, username, token, expires_in_seconds}`; argon2id verification; sessions expire (HPMMO_SESSION_TTL_HOURS, default 24h) and are capped per account (HPMMO_MAX_SESSIONS, default 5, oldest revoked; the cap is advisory under exactly-concurrent logins) |
| `POST /api/logout` | session | revokes the presented session |
| `POST /api/ticket/redeem` | - | `{ticket}` -> `{token, account_id, character_id?, expires_in_seconds}`; single-use, TTL HPMMO_TICKET_TTL_SECONDS (default 60) |

## Session endpoints

| Endpoint | Body -> Response |
| --- | --- |
| `POST /api/game-ticket` | `{character_id?}` -> `{ticket, expires_in_seconds}`; the launcher handoff (see below); character ownership checked when supplied |
| `POST /api/characters/create` | `{name, house}` -> `{character:{id,name,house}}`; max 2 per account; starter items seeded as ownership rows |
| `POST /api/characters/list` | `{}` -> `{characters:[snapshot]}` scoped to the session account |
| `POST /api/characters/load` | `{character_id}` -> `{character: snapshot + inventory[]}`; 404 for foreign ids |
| `POST /api/characters/save` | `{character_id, base_revision?, level?, exp?, max_hp?, current_hp?, max_mana?, current_mana?, galleons?, wand_tier?, pos?[3], rot_y?, map_id?, quests?, inventory?}` -> `{revision}`; **absent fields keep their stored values**; `inventory` present = validated full replacement of the ownership rows (capacity-limited to 40 item kinds, stacks <= 9999); `base_revision` mismatch -> 409 with the current revision. **Phase 4 gate:** progression fields accepted here are client-authoritative until Phase 5 moves authority to the world server - do not expose this endpoint to untrusted clients before then |

## Service-token endpoints (world server authority)

| Endpoint | Body -> Response |
| --- | --- |
| `POST /api/reward` | `{op_id, character_id, exp?, galleons?, items?[{id,amount,tier}]}` -> `{result}` or `{replayed:true, result}`; exactly-once per `op_id` (operations ledger) |
| `POST /api/trade` | `{op_id, from_id, to_id, offer:{galleons,items?}, request:{galleons,items?}}` -> `{result}` or replay; validates distinct ids, non-negative galleons, sender ownership of every offered item, destination capacity (40 item kinds), and moves items + currency in ONE transaction (row locks in ascending character-id order); replays are no-ops |

## Launcher handoff (ticket flow)

1. Launcher authenticates: `POST /api/login` -> keeps `token` in memory only.
2. Launcher requests `POST /api/game-ticket` (Bearer session, optional `character_id`).
3. Launcher starts the game with the ticket delivered via the **`HPMMO_TICKET` environment
   variable** of the child process - never on the command line. (Replacing the current
   `--pass` argv handoff is tracked as the remaining Phase 4 launcher item; the service side
   and the redemption endpoint are live and tested.)
4. The game calls `POST /api/ticket/redeem` once, receives its own session, and uses
   `Authorization: Bearer` for character load/save. The ticket is consumed on first use
   (replay -> 410).

## Environments

| Variable | Purpose |
| --- | --- |
| `DATABASE_URL` | PostgreSQL DSN. Empty -> readiness reports unavailable; there is no SQLite/JSON fallback in this service |
| `HPMMO_BIND` / `HPMMO_HTTP_PORT` | listen address (default `127.0.0.1:8081`) |
| `HPMMO_SERVICE_TOKEN` | enables the private endpoints |
| `HPMMO_MIGRATIONS_DIR` | migration directory (default `db/migrations`) |
| `HPMMO_ARGON2_M` / `_T` / `_P` | argon2id cost (defaults 64 MiB, t=3, p=1) |
| `HPMMO_SESSION_TTL_HOURS`, `HPMMO_TICKET_TTL_SECONDS`, `HPMMO_MAX_SESSIONS` | session/ticket policy |
| `HPMMO_ALLOW_RESET` | required for the `dev-reset` command |

CLI: `hpmmo_service serve | migrate | selfcheck | dev-reset | version`.
`dev-reset` refuses unless `HPMMO_ALLOW_RESET=1` **and** the connected database name
contains "dev"; it drops and recreates the schema, re-runs migrations, seeds the `dev`
account, and thereby invalidates all prior sessions.
