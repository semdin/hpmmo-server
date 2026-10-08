# HPMMO server deployment and rollback runbook (Maintenance surface)

Audience: whoever is on call when a server release goes wrong on the VPS.
Scope: `deploy/hpmmo_deploy.sh` (the controller), the release layout under
`/opt/hpmmo/releases`, the journal under `/opt/hpmmo/state`, the status
endpoint on `127.0.0.1:8083`, and the CI workflow
`.github/workflows/server-release.yml`.

Everything here runs on the server. Nothing in this document is a substitute
for the rehearsal: `python tests/deploy_rehearsal.py` drives this exact
controller, in a temp directory with stub services, through the happy path and
every failure path below.

---

## 1. Layout

```text
/opt/hpmmo/
  releases/
    <release-id>/          immutable release tree (read-only, frozen at staging)
    current -> <release-id>  the ONLY thing a deployment switches (atomic rename)
  state/
    journal.jsonl          one JSON object per transition (no secrets)
    status.json            {state, release, previous_release, since, message}
    previous_release       last known-good release, written at switch time
    active_release         active release id
    release.env            HPMMO_RELEASE_ID / HPMMO_PREVIOUS_RELEASE for systemd
    releases/<id>.json     staging metadata: frozen tree hash, schema level
    logs/                  migration, smoke and staging build logs
    deploy.lock            flock target (a directory lock where flock is absent)
    maintenance.flag       present while maintenance is ACTIVE
/opt/hpmmo/bin/
  hpmmo_deploy.sh          stable controller path (CI and operators call this)
  hpmmo_status.py          loopback status endpoint (systemd: hpmmo-status)
```

Everything under `releases/` except `current` and the previous release is safe
to delete; the journal and status live outside that tree on purpose.

Secrets stay in `/etc/hpmmo/hpmmo.env` (root-owned, `chmod 600`). The journal,
the logs, the status document and `release.env` never contain one: the
controller redacts, and it sends the service token to `curl` through stdin
rather than argv so it cannot appear in `ps`.

## 2. Deploying

```bash
# 1. stage: verify + build + freeze. No player impact.
sudo /opt/hpmmo/bin/hpmmo_deploy.sh --stage /tmp/hpmmo-server-<id>.tar.gz --id <id>
# 2. deploy (players are drained by the world server and disconnected first)
sudo /opt/hpmmo/bin/hpmmo_deploy.sh --release <id> --reason "why"
# --deploy does both in one step; CI uses exactly this.
```

**Before the first deployment, one thing must exist:** the synthetic login+join
check. `deploy/smoke_client.sh` runs `world/server/smoke_client.tscn` (or
`.gd`) headless from the release; that scene is the world/client workstream's
deliverable. Until it ships, point `HPMMO_SMOKE_CMD` in the environment file at
your own client check. Without either, the controller refuses to deploy (exit
`2`, before anything is touched) rather than advertising an unverified release.

**First time on an existing box (the one-time move off the manual tarball
layout).** The release that is running today has no maintenance API, so the
normal path cannot drain it. Do this once, deliberately, in a window:

```bash
systemctl stop hpmmo                                  # players are gone; announce it
sudo deploy/install_layout.sh --adopt /root/hpmmo/game   # freeze the live tree
#   ...which also installs the units and the status endpoint
sudo /opt/hpmmo/bin/hpmmo_deploy.sh --deploy /tmp/hpmmo-server-<id>.tar.gz \
     --id <id> --cold-start
```

`--cold-start` skips the announce/drain/save barrier and is refused unless
`systemctl is-active hpmmo.service` says the world is stopped, so it can never
be used to bypass the barrier on a live server. Everything after APPLYING
(migration, atomic switch, restart, verification, rollback on failure) is the
normal path.

What the controller does, in order (journal entry for every transition):

| Step | State | What happens |
| --- | --- | --- |
| 1 | `BUILD_AND_STAGE` | checksums + frozen tree hash verified; the staged release is never written to again |
| 2 | – | exclusive lock (a second deployment queues, then runs; it never interleaves) |
| 3 | `ANNOUNCING` | `POST /admin/maintenance/begin {reason, countdown_seconds}` with `X-Service-Token`; the world server publishes the countdown and closes logins |
| 4 | `DRAINING` → `SAVING` → `DISCONNECTING` → `MAINTENANCE` | the world server drives these; the controller polls `GET /admin/state` and journals what it observes |
| 5 | `MAINTENANCE` | `POST /admin/save`; `failed` must be `0` |
| 6 | `APPLYING` | world server stopped, `<release>/services/cpp/build/hpmmo_service migrate` run with the NEW binary, `current` switched by rename(2), db service restarted |
| 7 | `VERIFYING` | `/api/health`, `/api/ready` schema level, `/api/version` vs the release's `services/version.json`, world `/admin/status` = `ONLINE`, synthetic login+join check |
| 8 | `ONLINE` | release id published; the world server reopens logins itself when it restarts into `ONLINE` |

Exit codes: `0` ok, `2` usage/preflight, `3` release refused (checksum/tree/
manifest), `4` maintenance interface unavailable, `5` drain timeout, `6` final
save failed, `7` migration failed, `8` verification failed, `9` lock timeout,
`10` no previous release, `11` rollback could not restore a healthy service.

Status at any time, while the world server is up **or** stopped:

```bash
sudo /opt/hpmmo/bin/hpmmo_deploy.sh --status
curl -s http://127.0.0.1:8083/status     # loopback only; never a public port
```

## 3. When to roll back

Roll back when the new release is the problem and the previous release is not:

* verification failed (the controller already rolled back — the run exits
  `8`/`7`/`11` and maintenance stays ACTIVE, so this is a "decide what next");
* players report a regression that only the new release has;
* the release's migrations are broken in a way the previous binary survives;
* a deploy crashed mid-flight (`--status` prints `in flight: ...`, or the
  journal's last line is `PENDING`/non-terminal) — run
  `hpmmo_deploy.sh --recover` first; it either finishes nothing (the switch
  never happened) or undoes the half-switch by itself.

Do **not** roll back for a database problem you have not diagnosed: see §5.

## 4. Rolling back

```bash
sudo /opt/hpmmo/bin/hpmmo_deploy.sh --status          # current / previous / journal
sudo /opt/hpmmo/bin/hpmmo_deploy.sh --rollback --reason "why (ticket id)"
```

`--rollback` performs exactly the automatic failure path: stop the world
server, point `current` back at the previous release, restart `hpmmo-db` and
`hpmmo` on it, ask it to stay in maintenance (`POST
/admin/maintenance/begin` with `countdown_seconds: 0`), journal `ROLLBACK`, and
print the result. **Maintenance stays ACTIVE**: the restored release is not
advertised as online and does not accept logins until you reopen it
deliberately.

Reopen a rolled-back server (only after you are satisfied it is healthy):

```bash
sudo systemctl restart hpmmo.service      # comes up ONLINE, countdown not needed
# the launcher-facing state follows automatically:
sudo /opt/hpmmo/bin/hpmmo_deploy.sh --status
```

If `--rollback` exits `11`, the previous release also failed to come back:
stop, do not keep switching, and follow §7 (escalation).

## 5. What a rollback does NOT undo

* **Migrations.** The switch moves a symlink; the database is untouched. If the
  new release applied a migration, the old binary is now running against a
  newer schema. Prefer expand/contract migrations (new columns nullable, old
  columns kept) so the previous binary keeps working; if a migration is
  destructive, its recovery is a *database* procedure, not a pointer switch:
  restore the pre-deployment dump
  (`pg_dump` before an irreversible migration is part of your change process),
  then roll the binary back, then re-run the migration when fixed. The
  controller says this in the journal entry too.
* **Characters saved by the new release.** Saves are not versioned per release;
  anything written while the new release was live stays written.
* **Sent items, trades and rewards.** Trade and reward ledger rows are final.
* **The `ONLINE` state you had before.** A rollback leaves maintenance ACTIVE
  by design, so you must reopen explicitly.
* **Players' time.** They were disconnected at the barrier; they reconnect
  whenever you reopen.

## 6. Reading the journal

```bash
tail -n 40 /opt/hpmmo/state/journal.jsonl | python3 -m json.tool --json-lines   # or jq
sudo /opt/hpmmo/bin/hpmmo_deploy.sh --status --journal 20
```

Useful greps:

```bash
# every failure we have ever had, newest last
grep -E '"outcome":"(FAILED|ROLLBACK|REFUSED|ABORTED|RECOVERED)"' /opt/hpmmo/state/journal.jsonl
# what the world server itself reported during the last deployment
grep 'world server state=' /opt/hpmmo/state/journal.jsonl | tail
# when current changed, and from what
grep 'current ->' /opt/hpmmo/state/journal.jsonl
```

Logs: `/opt/hpmmo/state/logs/migrate-<id>.log`,
`smoke-<release>/`, `stage-build-<id>.log`, plus
`journalctl -u hpmmo -u hpmmo-db -u hpmmo-status`.

`perl`-free one-liner to see the failures with their reasons:

```bash
python3 - <<'PY'
import json
for line in open('/opt/hpmmo/state/journal.jsonl'):
    r = json.loads(line)
    if r['outcome'] in ('FAILED', 'ROLLBACK', 'REFUSED', 'RECOVERED'):
        print(r['ts'], r['release'], r['outcome'], r['from'], '->', r['to'], r['message'])
PY
```

## 7. Escalation: the previous release is unhealthy too

1. Keep maintenance active; do not keep flipping `current`. Two failed
   releases usually mean the common dependency moved: PostgreSQL, the schema,
   the environment file, the service token, or the disk.
2. Check the shared layers first:
   `systemctl status hpmmo-db postgresql`,
   `curl -s http://127.0.0.1:8081/api/ready`,
   `df -h /opt`, `journalctl -u hpmmo-db -n 200`.
3. Stage and deploy the **last commit that was verifiably online** (the
   journal records it in `previous_release` / the `ONLINE` entries) with the
   normal `--deploy` path — a deployment, not a manual copy, so the checks and
   the journal stay intact.
4. If the schema is the problem, stop `hpmmo`, restore the last pre-migration
   dump with `pg_restore`/`psql`, then start the known-good release; write down
   the schema version you restored to (`hpmmo_service selfcheck` reports
   applied vs required).
5. If the box itself is the problem, the release layout is portable: copy the
   whole `/opt/hpmmo/releases/current` tree plus `state/` and the environment
   file to the replacement host, run `deploy/install_layout.sh` there and start
   the units. Players' characters live in PostgreSQL, not on the box.
6. Announce in whatever channel the community uses; the status endpoint and the
   launcher show `MAINTENANCE` with the journal's last message, so support can
   see the same thing you see.

## 8. The world server admin contract this depends on

Implemented in `world/addons/hpmmo_sim/admin.gd` (bound to `127.0.0.1:8082`,
`HPMMO_ADMIN_PORT`, refuses to start without `HPMMO_SERVICE_TOKEN`). The
controller fails safe - journal + abort, nothing touched - when it is absent
(exit `4`), when the token is rejected (HTTP 403, exit `4`) or when the world
server's own state machine gives up (`FAILED`, exit `5`).

```http
POST /admin/maintenance/begin      X-Service-Token: <HPMMO_SERVICE_TOKEN>
     {"reason": "server update <id>", "countdown_seconds": 300}
     200 -> {"ok":true,"state":"ANNOUNCING","deadline_ms":...,"players":N}
     409 -> {"error":"already_in_maintenance","state":"<current>"}
            begin() is only accepted from ONLINE. A cycle that is already
            running (or past the save barrier) is exactly what a deployment
            wants, so the controller journals it and continues; any other
            state (in particular FAILED) aborts the deployment.
     403 -> wrong/absent token; nothing is ever answered before the token check
     countdown_seconds: 0 -> an immediate cycle (used after a rollback to hold a
            restarted world server closed; it still drains for
            HPMMO_MAINTENANCE_DRAIN_SECONDS, default 10 s, before it is fully
            closed - set that variable to 0 in the environment file if a
            rollback must clamp shut instantly).

POST /admin/save
     Deferred: the response is parked until the character flush has been
     acknowledged (bounded internally by SAVE_ACK_TIMEOUT_MS), so the
     controller gives it HPMMO_SAVE_TIMEOUT (default 120 s) rather than the
     usual 10 s.
     200 -> {"ok":true,"saved":N,"failed":M,"skipped":S}; M must be 0, any other
            value (or a non-200) fails the deployment and keeps the old release
     Route note: the implementation currently registers this as
     /admin/admin/save. The controller calls the documented /admin/save first,
     falls back to /admin/admin/save when it gets a 404, and journals the
     deviation. Fix the route and the fallback simply goes dormant.

GET  /admin/state      (identical payload on /admin/status)
     200 -> {"ok":true,"state":"ONLINE|ANNOUNCING|DRAINING|SAVING|
                               DISCONNECTING|MAINTENANCE|ABORTED|FAILED",
             "reason":...,"deadline_ms":...,"players":N,"release":"<id>",...}
     The controller polls this while draining and journals every transition it
     observes; FAILED aborts immediately, and a return to ONLINE while waiting
     for MAINTENANCE means the cycle was cancelled (abort, nothing changed).
```

Active release id: the world server reads `HPMMO_RELEASE` from its
environment and reports it on `/admin/status`. The controller writes
`HPMMO_RELEASE`, `HPMMO_RELEASE_ID` and `HPMMO_PREVIOUS_RELEASE` into
`/opt/hpmmo/state/release.env`, which both units load through
`EnvironmentFile=`; the same values live in `/opt/hpmmo/state/status.json`
and `active_release` for the status endpoint.

The synthetic login+join check is a real client: `deploy/smoke_client.sh` runs
`world/server/smoke_client.tscn|.gd` headless from the staged release when it
exists, or an explicit `HPMMO_SMOKE_CMD` from the environment file. A TCP/ENet
probe is not a login and is not accepted as a substitute. If neither is
available the controller refuses to deploy (exit `2` at preflight, before
anything is touched) rather than advertising an unverified release.

## 9. Operational notes

* **First deployment after adopting the layout**: `install_layout.sh --adopt
  <old tree>` records the adopted release as both current and previous, so the
  first `--deploy` has something to roll back to.
* **Pruning**: `releases/` grows by one directory per release. Delete any
  directory that is neither `current`'s target nor the previous release when
  you are satisfied; never delete `state/`.
* **Concurrent deployments**: the lock queues them (`HPMMO_LOCK_WAIT`, default
  900 s, then exit `9`). CI also serialises with a non-cancelling `concurrency`
  group.
* **A controller restart mid-deployment** is safe: the next invocation reads
  the journal, and either undoes a half-finished switch or reports that nothing
  was changed. `--recover` does only that check.
* **The status endpoint must stay loopback**: `hpmmo_status.py` refuses a
  non-loopback bind and no ufw rule is opened for 8083.
* **The client release pipeline is the release pipeline** and is intentionally not part of
  `server-release.yml`.
