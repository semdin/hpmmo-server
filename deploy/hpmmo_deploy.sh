#!/bin/bash
# =============================================================================
# HPMMO staged deployment controller - plan.md Phase 6
# =============================================================================
#
# Replaces the manual tarball copy (deploy/update_server.sh) with a staged,
# journalled, reversible release process:
#
#   verify -> lock -> announce maintenance -> drain -> final save
#          -> stop world -> migrate -> atomic switch -> restart -> verify
#          -> ONLINE   (or ROLLBACK with maintenance left ACTIVE)
#
# Release layout (HPMMO_RELEASES_DIR, default /opt/hpmmo/releases):
#
#   <release-id>/        immutable release tree (read-only after staging)
#   current -> <id>      the ONLY thing a deployment switches, by rename(2)
#
# Everything under HPMMO_RELEASES_DIR except `current` and the previous
# release is safe to delete.
#
# Deployment state lives outside it (HPMMO_STATE_DIR, default /opt/hpmmo/state):
#
#   journal.jsonl        one JSON object per transition (never a secret)
#   status.json          {state, release, previous_release, since, message}
#   deploy.lock          flock target (a directory lock on systems without flock)
#   previous_release     last known-good release, written at switch time
#   active_release       active release id (one line)
#   release.env          HPMMO_RELEASE_ID / HPMMO_PREVIOUS_RELEASE for systemd
#   releases/<id>.json   staging metadata: frozen tree hash, schema level
#   logs/                migration, smoke and staging build logs
#   maintenance.flag     present while maintenance is ACTIVE
#
# World server administration contract this controller speaks (owned by the
# world server workstream; the exact shapes are repeated in
# docs/runbook-rollback.md):
#
#   POST /admin/maintenance/begin  {reason, countdown_seconds}   X-Service-Token
#   GET  /admin/state              -> {"state": "ANNOUNCING|DRAINING|SAVING|
#                                            DISCONNECTING|MAINTENANCE|ONLINE"}
#   POST /admin/save               -> {"failed": N}
#   GET  /admin/status             -> {"state": "ONLINE", ...}
#
# Every knob is environment-overridable so the whole flow can be rehearsed in a
# temp directory (server/tests/deploy_rehearsal.py) and so a differently laid
# out box needs no code change.
#
# Secrets: the environment file is sourced, never printed. Service tokens are
# sent to curl through a config on stdin (not argv) so they never appear in
# `ps`, and every journal line and log goes through redact().
#
# Exit codes: 0 ok | 2 usage/preflight | 3 release verification failed
#             4 maintenance interface unavailable | 5 drain timeout
#             6 final save failed | 7 migration failed | 8 verification failed
#             9 lock timeout | 10 no previous release to roll back to
#             11 rollback could not restore a healthy service
# =============================================================================
set -euo pipefail

PROG="$(basename "$0")"

# --- defaults ---------------------------------------------------------------
: "${HPMMO_ENV_FILE:=/etc/hpmmo/hpmmo.env}"
: "${HPMMO_RELEASES_DIR:=${RELEASES_DIR:-/opt/hpmmo/releases}}"
: "${HPMMO_STATE_DIR:=/opt/hpmmo/state}"
: "${HPMMO_UNIT_DIR:=/etc/systemd/system}"
: "${HPMMO_WORLD_UNIT:=hpmmo.service}"
: "${HPMMO_DB_UNIT:=hpmmo-db.service}"
: "${HPMMO_STATUS_UNIT:=hpmmo-status.service}"
: "${HPMMO_SYSTEMCTL:=systemctl}"
: "${HPMMO_GODOT:=/root/hpmmo/bin/godot_server}"
: "${HPMMO_STATUS_SCRIPT:=/opt/hpmmo/bin/hpmmo_status.py}"
: "${HPMMO_STATUS_HOST:=127.0.0.1}"
: "${HPMMO_STATUS_PORT:=8083}"
: "${HPMMO_ADMIN_PORT:=8082}"
: "${HPMMO_MAINTENANCE_COUNTDOWN:=300}"
: "${HPMMO_DRAIN_TIMEOUT:=600}"
: "${HPMMO_VERIFY_TIMEOUT:=90}"
: "${HPMMO_HTTP_TIMEOUT:=10}"
# The final save is a deferred request: the world server parks it until the
# persistence flush has actually been acknowledged, so it gets its own budget.
: "${HPMMO_SAVE_TIMEOUT:=120}"
: "${HPMMO_HOLD_TIMEOUT:=120}"
# A (re)started world server takes seconds before its admin interface accepts
# connections; a request sent in that window is refused by the OS and proves
# nothing about the state the world will come up in. The maintenance hold
# waits for the interface under this budget before it commits to a state.
: "${HPMMO_ADMIN_READY_TIMEOUT:=60}"
: "${HPMMO_ADMIN_READY_POLL:=1}"
: "${HPMMO_POLL_INTERVAL:=2}"
: "${HPMMO_LOCK_WAIT:=900}"
: "${HPMMO_STAGE_BUILD:=auto}"
: "${HPMMO_STAGE_IMPORT:=auto}"
: "${HPMMO_STATUS_LINES:=10}"

# Variables a caller (operator, CI or the rehearsal harness) may override even
# when the environment file defines them.
KNOBS="HPMMO_ENV_FILE HPMMO_RELEASES_DIR RELEASES_DIR HPMMO_STATE_DIR HPMMO_UNIT_DIR
HPMMO_WORLD_UNIT HPMMO_DB_UNIT HPMMO_STATUS_UNIT HPMMO_SYSTEMCTL HPMMO_GODOT
HPMMO_STATUS_SCRIPT HPMMO_STATUS_HOST HPMMO_STATUS_PORT HPMMO_ADMIN_PORT
HPMMO_ADMIN_URL HPMMO_API_URL HPMMO_MAINTENANCE_COUNTDOWN HPMMO_DRAIN_TIMEOUT
HPMMO_VERIFY_TIMEOUT HPMMO_HTTP_TIMEOUT HPMMO_SAVE_TIMEOUT HPMMO_HOLD_TIMEOUT
HPMMO_ADMIN_READY_TIMEOUT HPMMO_ADMIN_READY_POLL
HPMMO_POLL_INTERVAL HPMMO_LOCK_WAIT HPMMO_STAGE_BUILD HPMMO_STAGE_IMPORT
HPMMO_STATUS_LINES"

save_caller_env() {
    CALLER_KEYS=()
    local v
    for v in $KNOBS; do
        if [[ -v "$v" ]]; then
            CALLER_KEYS+=("$v")
            eval "SAVED_$v=\${$v}"
        fi
    done
}
restore_caller_env() {
    local v
    for v in ${CALLER_KEYS[@]+"${CALLER_KEYS[@]}"}; do
        eval "$v=\${SAVED_$v}"
    done
}

# --- output helpers ---------------------------------------------------------
say()  { printf '[hpmmo-deploy] %s\n' "$*"; }
warn() { printf '[hpmmo-deploy] WARNING: %s\n' "$*" >&2; }
die()  { local code="$1"; shift; printf '[hpmmo-deploy] ERROR: %s\n' "$*" >&2; exit "$code"; }

# Scrub anything that looks like a credential. Applied to every journal line
# and to anything echoed from a service response.
redact() {
    sed -E \
        -e 's/([Ss]ervice[-_ ][Tt]oken[[:space:]]*["'"'"']?[[:space:]]*[:=][[:space:]]*)[^",}[:space:]]+/\1***REDACTED***/g' \
        -e 's/([Pp]assword[[:space:]]*["'"'"']?[[:space:]]*[:=][[:space:]]*)[^",}[:space:]]+/\1***REDACTED***/g' \
        -e 's/([Bb]earer[[:space:]]+)[A-Za-z0-9._~+\/=-]+/\1***REDACTED***/g' \
        -e 's/([Tt]oken[[:space:]]*["'"'"']?[[:space:]]*[:=][[:space:]]*)[A-Za-z0-9._~+\/=-]{16,}/\1***REDACTED***/g'
}
now_iso()   { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
now_epoch() { date +%s; }
truncate_str() { printf '%s' "${1:0:200}"; }

# --- state ------------------------------------------------------------------
JOURNAL=""
STATUS_FILE=""
CURRENT_STATE="UNKNOWN"
ACTIVE_RELEASE=""
PREV_RELEASE=""
LAST_WORLD_STATE=""
REASON=""
SMOKE_REASON=""
READY_SCHEMA=""
ROLLBACK_RESULT="ok"

state_dirs() {
    JOURNAL="${HPMMO_STATE_DIR%/}/journal.jsonl"
    STATUS_FILE="${HPMMO_STATE_DIR%/}/status.json"
}

# Appends one journal record. Does not change the controller's state; see
# transition() / set_state(). `to` is the state the record leads to; `outcome`
# is PENDING|OK|FAILED|ROLLBACK|REFUSED|ABORTED|RECOVERED.
journal() {
    local to="$1" outcome="$2" message="$3" release="${4:-${ACTIVE_RELEASE:-}}"
    mkdir -p "${HPMMO_STATE_DIR%/}"
    printf '{"ts":"%s","release":"%s","from":"%s","to":"%s","outcome":"%s","message":"%s"}\n' \
        "$(now_iso)" "$release" "$CURRENT_STATE" "$to" "$outcome" \
        "$(printf '%s' "$message" | redact | tr -d '\n"\\')" >> "$JOURNAL"
    printf '[hpmmo-deploy] %s %s -> %s [%s] %s\n' "$(now_iso)" "$CURRENT_STATE" "$to" "$outcome" "$message" >&2
}

# Records a state change in the status document the launcher-facing status
# endpoint serves. `since` only moves when the state actually changes.
set_state() {
    local state="$1" message="$2" release="${3:-${ACTIVE_RELEASE:-}}" previous="${4:-${PREV_RELEASE:-}}"
    local since old_state old_since
    since="$(now_iso)"
    if [ -f "$STATUS_FILE" ]; then
        old_state="$(json_str "$STATUS_FILE" state || true)"
        old_since="$(json_str "$STATUS_FILE" since || true)"
        if [ "$old_state" = "$state" ] && [ -n "$old_since" ]; then
            since="$old_since"
        fi
    fi
    CURRENT_STATE="$state"
    mkdir -p "${HPMMO_STATE_DIR%/}"
    printf '{"state":"%s","release":"%s","previous_release":"%s","since":"%s","message":"%s"}\n' \
        "$state" "$release" "$previous" "$since" \
        "$(printf '%s' "$message" | redact | tr -d '\n"\\')" > "$STATUS_FILE.tmp.$$"
    mv -f "$STATUS_FILE.tmp.$$" "$STATUS_FILE"
}

# Journal + status in one step (the normal, successful transition).
transition() {
    local to="$1" message="$2"
    journal "$to" OK "$message"
    set_state "$to" "$message"
}

# --- tiny JSON readers (flat objects only - our own contract) ----------------
json_py() {
    if command -v python3 >/dev/null 2>&1; then printf 'python3'; return 0; fi
    if command -v python >/dev/null 2>&1; then printf 'python'; return 0; fi
    return 1
}

json_str() {  # file key -> value on stdout (empty when absent)
    local f="$1" k="$2" py out
    [ -f "$f" ] || return 0
    if py="$(json_py)"; then
        out="$("$py" -c 'import json,sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
v = d.get(sys.argv[2], "")
if isinstance(v, bool) or v is None:
    print("")
elif isinstance(v, (str, int)):
    print(v)
' "$f" "$k" 2>/dev/null || true)"
        printf '%s' "$out"
        return 0
    fi
    sed -n 's/.*"'"$k"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1
}

json_int() {  # file key -> integer on stdout (empty when absent)
    local f="$1" k="$2" py out
    [ -f "$f" ] || return 0
    if py="$(json_py)"; then
        out="$("$py" -c 'import json,sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
v = d.get(sys.argv[2])
if isinstance(v, bool) or v is None:
    print("")
elif isinstance(v, int):
    print(v)
elif isinstance(v, str) and v.strip().lstrip("-").isdigit():
    print(v.strip())
' "$f" "$k" 2>/dev/null || true)"
        printf '%s' "$out"
        return 0
    fi
    sed -n 's/.*"'"$k"'"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p' "$f" | head -1
}

# --- HTTP --------------------------------------------------------------------
HTTP_CODE=""

# Performs a request with the service token supplied through a curl config on
# stdin (never argv, so it cannot show up in `ps`).
http_request() {  # method url body outfile token [timeout]
    local method="$1" url="$2" body="${3:-}" out="$4" token="${5:-}" timeout="${6:-$HPMMO_HTTP_TIMEOUT}"
    local -a args=(-sS --max-time "$timeout" -o "$out" -w '%{http_code}' -X "$method")
    local cfg=""
    if [ -n "$token" ]; then
        case "$token" in
            *[!A-Za-z0-9._~+/=:-]*) warn "service token contains unexpected characters; refusing to send it"; HTTP_CODE="000"; return 0 ;;
        esac
        cfg="header = \"X-Service-Token: $token\""
    fi
    [ -n "$body" ] && args+=(-H 'Content-Type: application/json' --data "$body")
    HTTP_CODE=""
    if [ -n "$cfg" ]; then
        # -K - is load-bearing: without it curl ignores stdin entirely and the
        # token header is never sent, so every authenticated admin call is a 403
        # and no deployment can proceed. Found on the real box; the rehearsal's
        # stub did not check the header, which is why 207 checks missed it.
        HTTP_CODE="$(printf '%s\n' "$cfg" | curl -K - "${args[@]}" "$url" 2>/dev/null || true)"
    else
        HTTP_CODE="$(curl "${args[@]}" "$url" 2>/dev/null || true)"
    fi
    [ -n "$HTTP_CODE" ] || HTTP_CODE="000"
}

api_request()   { http_request "$1" "$2" "${3:-}" "$4" "${HPMMO_SERVICE_TOKEN:-}" "${5:-}"; }
admin_request() { http_request "$1" "$2" "${3:-}" "$4" "${HPMMO_SERVICE_TOKEN:-}" "${5:-}"; }

# --- lock --------------------------------------------------------------------
LOCK_HELD=0
LOCK_DIR=""

acquire_lock() {
    local wait="${HPMMO_LOCK_WAIT:-900}" start owner
    start="$(now_epoch)"
    mkdir -p "${HPMMO_STATE_DIR%/}"
    if command -v flock >/dev/null 2>&1; then
        exec 9>"${HPMMO_STATE_DIR%/}/deploy.lock"
        if flock -w "$wait" -x 9; then LOCK_HELD=1; return 0; fi
        return 1
    fi
    # Portable fallback (Git Bash ships no flock): atomic mkdir plus
    # stale-owner detection. The lock is released on exit; a killed controller
    # leaves a directory whose recorded pid no longer exists.
    LOCK_DIR="${HPMMO_STATE_DIR%/}/deploy.lock.d"
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        owner=""
        [ -f "$LOCK_DIR/pid" ] && owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            warn "removing stale deployment lock owned by dead pid $owner"
            rm -rf "$LOCK_DIR"
            continue
        fi
        if [ $(( "$(now_epoch)" - start )) -ge "$wait" ]; then
            return 1
        fi
        sleep 1
    done
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    LOCK_HELD=1
    return 0
}

release_lock() {
    [ "$LOCK_HELD" = "1" ] || return 0
    LOCK_HELD=0
    if [ -n "$LOCK_DIR" ]; then rm -rf "$LOCK_DIR"; fi
    return 0
}
trap release_lock EXIT

# --- journal introspection ----------------------------------------------------
JOURNAL_LAST_OUTCOME=""
JOURNAL_LAST_TO=""
JOURNAL_LAST_RELEASE=""
JOURNAL_PENDING_RELEASE=""

read_journal_tail() {
    JOURNAL_LAST_OUTCOME=""; JOURNAL_LAST_TO=""; JOURNAL_LAST_RELEASE=""
    JOURNAL_PENDING_RELEASE=""
    [ -f "$JOURNAL" ] || return 0
    local py line
    if py="$(json_py)"; then
        line="$("$py" -c 'import json, sys
last = pending = None
with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        raw = raw.strip()
        if not raw:
            continue
        try:
            rec = json.loads(raw)
        except Exception:
            continue
        last = rec
        if rec.get("outcome") == "PENDING":
            pending = rec
if last is None:
    print("||")
else:
    print("|".join([str(last.get("outcome", "")), str(last.get("to", "")), str(last.get("release", ""))]))
print(str((pending or {}).get("release", "")))
' "$JOURNAL" 2>/dev/null || true)"
        JOURNAL_LAST_OUTCOME="$(printf '%s\n' "$line" | sed -n '1s/^\([^|]*\)|.*/\1/p')"
        JOURNAL_LAST_TO="$(printf '%s\n' "$line" | sed -n '1s/^[^|]*|\([^|]*\)|.*/\1/p')"
        JOURNAL_LAST_RELEASE="$(printf '%s\n' "$line" | sed -n '1s/^[^|]*|[^|]*|\(.*\)$/\1/p')"
        JOURNAL_PENDING_RELEASE="$(printf '%s\n' "$line" | sed -n '2p')"
        return 0
    fi
    # Fallback: the last line only (safe: every flow ends with a terminal line).
    line="$(tail -n 1 "$JOURNAL" 2>/dev/null || true)"
    JOURNAL_LAST_OUTCOME="$(printf '%s' "$line" | sed -n 's/.*"outcome"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    JOURNAL_LAST_TO="$(printf '%s' "$line" | sed -n 's/.*"to"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    JOURNAL_LAST_RELEASE="$(printf '%s' "$line" | sed -n 's/.*"release"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    if [ "$JOURNAL_LAST_OUTCOME" = "PENDING" ]; then JOURNAL_PENDING_RELEASE="$JOURNAL_LAST_RELEASE"; fi
}

# A deployment is finished when its last journal record is terminal.
journal_is_terminal() {
    case "$JOURNAL_LAST_OUTCOME" in
        FAILED|ROLLBACK|REFUSED|ABORTED|RECOVERED) return 0 ;;
        OK) case "$JOURNAL_LAST_TO" in ONLINE) return 0 ;; esac ;;
    esac
    return 1
}

deployment_interrupted() {
    read_journal_tail
    [ -n "$JOURNAL_LAST_OUTCOME" ] || return 1
    journal_is_terminal && return 1
    return 0
}

# --- release helpers ---------------------------------------------------------
release_dir()  { printf '%s/%s' "${HPMMO_RELEASES_DIR%/}" "$1"; }

# readlink -f resolves the path even when the link does not exist, so test for
# the symlink first: a first deployment has no `current` and must say so.
current_target() {
    local link="${HPMMO_RELEASES_DIR%/}/current"
    if [ -L "$link" ]; then readlink -f "$link" 2>/dev/null || true; fi
    return 0
}

current_id() {
    local target
    target="$(current_target)"
    [ -n "$target" ] || return 0
    basename "$target" 2>/dev/null || true
}
release_meta() { printf '%s/releases/%s.json' "${HPMMO_STATE_DIR%/}" "$1"; }

file_tree_hash() {  # dir -> sha256 over the sorted per-file hashes
    local dir="$1"
    ( cd "$dir" && find . -type f -print0 2>/dev/null | LC_ALL=C sort -z \
        | xargs -0 -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1 )
}

expected_schema_level() {  # release dir -> highest numbered migration
    local dir="$1" level=""
    level="$(find "$dir/db/migrations" -maxdepth 1 -name '*.sql' -printf '%f\n' 2>/dev/null \
        | sed -n 's/^0*\([0-9][0-9]*\)_.*/\1/p' | sort -n | tail -1 || true)"
    [ -n "$level" ] || level="$(ls "$dir/db/migrations" 2>/dev/null \
        | sed -n 's/^0*\([0-9][0-9]*\)_.*/\1/p' | sort -n | tail -1 || true)"
    printf '%s' "$level"
}

# Verifies a staged release against the shipped manifest and the frozen tree
# hash recorded at staging time. Sets REASON and returns 1 on any problem.
verify_release() {
    local id="$1" dir="$2" meta expected actual
    REASON=""
    [ -n "${id:-}" ] || { REASON="no release id given"; return 1; }
    [ -d "$dir" ] || { REASON="release directory $dir does not exist"; return 1; }
    [ -f "$dir/SHA256SUMS" ] || { REASON="release has no SHA256SUMS"; return 1; }
    [ -s "$dir/SHA256SUMS" ] || { REASON="release SHA256SUMS is empty"; return 1; }
    [ -f "$dir/world/project.godot" ] || { REASON="release is missing world/project.godot"; return 1; }
    [ -x "$dir/services/cpp/build/hpmmo_service" ] || { REASON="release has no built services/cpp/build/hpmmo_service"; return 1; }
    [ -n "$(expected_schema_level "$dir")" ] || { REASON="release is missing db/migrations/*.sql"; return 1; }
    if find "$dir" -name '*.db' -print -quit 2>/dev/null | grep -q .; then
        REASON="release contains an account database file (*.db)"
        return 1
    fi
    meta="$(release_meta "$id")"
    if [ -f "$meta" ]; then
        expected="$(json_str "$meta" tree_hash || true)"
        if [ -n "$expected" ]; then
            actual="$(file_tree_hash "$dir")"
            if [ "$actual" != "$expected" ]; then
                REASON="release tree hash mismatch - the frozen release was modified after staging"
                return 1
            fi
        fi
        if [ "$(json_int "$meta" post_stage_mutated || true)" != "1" ]; then
            if ! ( cd "$dir" && sha256sum -c --strict --quiet SHA256SUMS >/dev/null 2>&1 ); then
                REASON="SHA256SUMS does not match the release contents"
                return 1
            fi
        fi
    else
        if ! ( cd "$dir" && sha256sum -c --strict --quiet SHA256SUMS >/dev/null 2>&1 ); then
            REASON="SHA256SUMS does not match the release contents"
            return 1
        fi
    fi
    return 0
}

# --- service control ---------------------------------------------------------
svc() { "$HPMMO_SYSTEMCTL" "$@"; }

restart_db_service() { svc restart "$HPMMO_DB_UNIT" >/dev/null 2>&1; }

wait_service_ready() {  # timeout -> 0/1 : /api/health AND /api/ready schema
    local timeout="$1" deadline out schema
    out="${HPMMO_STATE_DIR%/}/logs/.ready.json"
    deadline=$(( "$(now_epoch)" + timeout ))
    while :; do
        api_request GET "${HPMMO_API_URL%/}/api/health" "" "$out"
        if [ "$HTTP_CODE" = "200" ]; then
            api_request GET "${HPMMO_API_URL%/}/api/ready" "" "$out"
            if [ "$HTTP_CODE" = "200" ]; then
                schema="$(json_int "$out" schema || true)"
                if [ -n "$schema" ]; then
                    READY_SCHEMA="$schema"
                    rm -f "$out"
                    return 0
                fi
            fi
        fi
        [ "$(now_epoch)" -ge "$deadline" ] && break
        sleep "$HPMMO_POLL_INTERVAL"
    done
    rm -f "$out"
    return 1
}

WAIT_REASON=""

# Polls GET /admin/state until `target`. Sets WAIT_REASON when it gives up
# early because the world server itself refused to continue (FAILED) or because
# the maintenance cycle was cancelled and the world is ONLINE again.
wait_world_state() {  # state timeout -> 0/1 ; journals observed transitions
    local target="$1" timeout="$2" deadline out st reason
    out="${HPMMO_STATE_DIR%/}/logs/.world-state.json"
    WAIT_REASON=""
    deadline=$(( "$(now_epoch)" + timeout ))
    while :; do
        admin_request GET "${HPMMO_ADMIN_URL%/}/admin/state" "" "$out"
        if [ "$HTTP_CODE" = "200" ]; then
            st="$(json_str "$out" state || true)"
            [ -n "$st" ] || st="$(json_str "$out" status || true)"
            reason="$(truncate_str "$(json_str "$out" reason || true)")"
            if [ -n "$st" ]; then
                LAST_WORLD_STATE="$st"
                if [ "$st" != "$CURRENT_STATE" ]; then
                    journal "$st" OK "world server state=$st${reason:+ ($reason)}"
                    set_state "$st" "world server state=$st${reason:+ ($reason)}"
                fi
                if [ "$st" = "$target" ]; then
                    rm -f "$out"
                    return 0
                fi
                if [ "$st" = "FAILED" ]; then
                    WAIT_REASON="the world server reported FAILED: ${reason:-no reason given}"
                    rm -f "$out"
                    return 1
                fi
                if [ "$st" = "ONLINE" ] && [ "$target" = "MAINTENANCE" ]; then
                    # begin() was accepted but the cycle is gone: somebody
                    # aborted it, or the countdown was cancelled.
                    WAIT_REASON="the maintenance cycle is no longer running (world is ONLINE again)"
                    rm -f "$out"
                    return 1
                fi
            fi
        fi
        [ "$(now_epoch)" -ge "$deadline" ] && break
        sleep "$HPMMO_POLL_INTERVAL"
    done
    rm -f "$out"
    return 1
}

# Waits until the world server's admin interface answers at all: any HTTP
# response counts, 000 (connection refused / nothing listening) does not.
# This waits for the PORT, not for a state - a request to a world server that
# is still booting is refused by the OS and says nothing about what the world
# will do once it is up. The caller passes an absolute deadline (epoch
# seconds) so the whole hold shares one budget.
wait_admin_interface() {  # deadline -> 0/1
    local deadline="$1" out code
    out="${HPMMO_STATE_DIR%/}/logs/.admin-ready.json"
    while :; do
        admin_request GET "${HPMMO_ADMIN_URL%/}/admin/state" "" "$out"
        code="$HTTP_CODE"
        if [ "$code" != "000" ]; then
            rm -f "$out"
            return 0
        fi
        [ "$(now_epoch)" -ge "$deadline" ] && break
        sleep "$HPMMO_ADMIN_READY_POLL"
    done
    rm -f "$out"
    return 1
}

# Asks a (possibly freshly restarted) world server to close and stay closed,
# then waits until it is actually in MAINTENANCE: a restarted world comes up
# ONLINE (accepting logins) and only stops when the hold is delivered, so
# "maintenance ACTIVE" must mean the observed state, not just the request.
#
# INVARIANT this enforces, in both directions:
#   the status document and :8083/status must match what the world server is
#   actually enforcing - never MAINTENANCE while logins are accepted, never
#   ONLINE while the world is down or drained.
# The VPS defect this fixes: after a rollback the hold was a single POST sent
# while Godot was still booting; the POST hit a closed port, was never
# delivered, and the controller wrote MAINTENANCE anyway while the restored
# world came up ONLINE and accepting logins. So: the interface must answer
# first, begin() is retried inside the same budget, and if the hold still
# cannot be delivered or confirmed this FAILS loudly (journal FAILED) - the
# caller must never write MAINTENANCE on the strength of it.
hold_maintenance() {  # reason -> 0/1
    local reason="$1" out code body state deadline
    out="${HPMMO_STATE_DIR%/}/logs/.hold-maintenance.json"
    body="$(printf '{"reason":"%s","countdown_seconds":0}' "$(printf '%s' "$reason" | tr -d '"\\')")"
    deadline=$(( "$(now_epoch)" + HPMMO_ADMIN_READY_TIMEOUT ))

    say "holding maintenance (waiting up to ${HPMMO_ADMIN_READY_TIMEOUT}s for the admin interface)"
    if ! wait_admin_interface "$deadline"; then
        journal FAILED FAILED "maintenance hold NOT delivered: the admin interface never answered within ${HPMMO_ADMIN_READY_TIMEOUT}s"
        warn "the admin interface (${HPMMO_ADMIN_URL%/}/admin) never answered - maintenance was NOT delivered"
        return 1
    fi
    while :; do
        admin_request POST "${HPMMO_ADMIN_URL%/}/admin/maintenance/begin" "$body" "$out"
        code="$HTTP_CODE"
        [ "$code" != "000" ] && break
        if [ "$(now_epoch)" -ge "$deadline" ]; then
            rm -f "$out"
            journal FAILED FAILED "maintenance hold NOT delivered: begin() could not be sent within ${HPMMO_ADMIN_READY_TIMEOUT}s"
            return 1
        fi
        sleep "$HPMMO_ADMIN_READY_POLL"
    done
    state="$(json_str "$out" state || true)"
    rm -f "$out"
    case "$code" in
        200|202) : ;;
        409)
            # The world server refuses begin() from any state but ONLINE. That
            # is fine when a maintenance cycle is already running (or has passed
            # the save barrier) - it is then already refusing joins.
            case "$state" in
                MAINTENANCE|DRAINING|SAVING|DISCONNECTING|ANNOUNCING)
                    journal ROLLBACK OK "world server is already in maintenance (state $state)";;
                *)
                    journal FAILED FAILED "maintenance hold NOT delivered: the world server refused begin() from state ${state:-unknown} (HTTP 409)"
                    warn "world server refused maintenance (HTTP 409, state ${state:-unknown})"
                    return 1 ;;
            esac
            ;;
        *)
            journal FAILED FAILED "maintenance hold NOT delivered: begin() answered HTTP $code (state ${state:-unknown})"
            return 1 ;;
    esac
    if ! wait_world_state MAINTENANCE "$HPMMO_HOLD_TIMEOUT"; then
        journal FAILED FAILED "maintenance hold NOT confirmed: the world server reported ${LAST_WORLD_STATE:-unknown} instead of MAINTENANCE (${WAIT_REASON:-timeout})"
        warn "the restored release did not reach MAINTENANCE: ${WAIT_REASON:-timeout}"
        return 1
    fi
    return 0
}

# After an abort that touched nothing, report what the world server actually
# says rather than the deployment state we were about to enter.
restore_observed_state() {  # fallback_state message
    local fallback="$1" message="$2" out st=""
    out="${HPMMO_STATE_DIR%/}/logs/.abort-state.json"
    admin_request GET "${HPMMO_ADMIN_URL%/}/admin/status" "" "$out"
    [ "$HTTP_CODE" = "200" ] && st="$(json_str "$out" state || true)"
    rm -f "$out"
    if [ -n "$st" ]; then
        set_state "$st" "$message"
    elif [ -n "$fallback" ]; then
        set_state "$fallback" "$message"
    fi
    return 0
}

publish_release_state() {
    mkdir -p "${HPMMO_STATE_DIR%/}"
    printf '%s\n' "$ACTIVE_RELEASE" > "${HPMMO_STATE_DIR%/}/active_release"
    # HPMMO_RELEASE is what the world server publishes on /admin/status;
    # HPMMO_RELEASE_ID is the explicit name. Both are exported.
    cat > "${HPMMO_STATE_DIR%/}/release.env" <<EOF
# Generated by hpmmo_deploy.sh - read by the systemd units and the world server.
HPMMO_RELEASE=$ACTIVE_RELEASE
HPMMO_RELEASE_ID=$ACTIVE_RELEASE
HPMMO_PREVIOUS_RELEASE=$PREV_RELEASE
HPMMO_RELEASE_SWITCHED_AT=$(now_iso)
EOF
}

# --- rollback ----------------------------------------------------------------
# Performs plan.md Phase 6 step (8): stop, restore the previous release,
# restart the services, journal ROLLBACK and leave maintenance ACTIVE.
# Sets ROLLBACK_RESULT = ok | no_previous | failed and always returns 0 so the
# caller decides its own exit code.
rollback_to_previous() {  # reason [previous-dir]
    local reason="$1" prev="${2:-}" health_failed=0 tmp
    ROLLBACK_RESULT="ok"
    [ -n "$prev" ] || prev="$(cat "${HPMMO_STATE_DIR%/}/previous_release" 2>/dev/null || true)"
    journal ROLLBACK ROLLBACK "rollback: $reason"
    if [ -z "$prev" ] || [ ! -d "$prev" ]; then
        ROLLBACK_RESULT="no_previous"
        journal FAILED FAILED "no previous release available to restore"
        set_state MAINTENANCE "rollback failed: no previous release available ($reason)"
        warn "no previous known-good release; maintenance stays ACTIVE and nothing is advertised online"
        return 0
    fi
    say "rolling back to $(basename "$prev")"
    svc stop "$HPMMO_WORLD_UNIT" >/dev/null 2>&1 || warn "could not stop $HPMMO_WORLD_UNIT (continuing)"

    tmp="${HPMMO_RELEASES_DIR%/}/.current.$$"
    ln -sfn "$prev" "$tmp"
    if ! mv -T "$tmp" "${HPMMO_RELEASES_DIR%/}/current"; then
        rm -f "$tmp"
        ROLLBACK_RESULT="failed"
        journal FAILED FAILED "could not restore the previous release symlink"
        set_state MAINTENANCE "rollback failed to switch current back to $(basename "$prev") ($reason)"
        return 0
    fi
    ACTIVE_RELEASE="$(basename "$prev")"
    publish_release_state
    journal ROLLBACK OK "current -> $(basename "$prev")"

    if ! restart_db_service; then
        warn "could not restart $HPMMO_DB_UNIT"
        health_failed=1
    else
        wait_service_ready "$HPMMO_VERIFY_TIMEOUT" || { warn "$HPMMO_DB_UNIT did not report ready at ${HPMMO_API_URL%/}/api/ready"; health_failed=1; }
    fi
    if ! svc restart "$HPMMO_WORLD_UNIT" >/dev/null 2>&1; then
        warn "could not restart $HPMMO_WORLD_UNIT"
        health_failed=1
    fi
    # The restarted (previous, known-good) world is asked to stay closed so a
    # failed release can never be advertised as online.
    if hold_maintenance "rollback: $reason"; then
        journal ROLLBACK ROLLBACK "maintenance held on the restored release"
        set_state MAINTENANCE "rolled back to $(basename "$prev"): $reason"
    else
        # The hold was never delivered or confirmed, so the world may be
        # accepting logins: writing MAINTENANCE here would be a lie the
        # launcher repeats to players (the VPS defect). Report only what the
        # world actually enforces; UNKNOWN when it cannot even be reached.
        ROLLBACK_RESULT="failed"
        warn "the restored world server did not accept maintenance; it may accept logins again"
        restore_observed_state "UNKNOWN" "rolled back to $(basename "$prev") but maintenance could NOT be confirmed; check the world server ($reason)"
    fi
    if [ "$health_failed" = "1" ]; then ROLLBACK_RESULT="failed"; fi
    if [ "$ROLLBACK_RESULT" = "ok" ]; then
        say "rollback complete; maintenance is ACTIVE (state and journal in ${HPMMO_STATE_DIR%/})"
    else
        warn "rollback did NOT restore a healthy maintenance hold - verify the world server before letting players in"
        say "rollback finished with errors; nothing is advertised online (state and journal in ${HPMMO_STATE_DIR%/})"
    fi
    return 0
}

# --- recovery ----------------------------------------------------------------
recover_if_needed() {
    deployment_interrupted || return 0
    local pending="$JOURNAL_PENDING_RELEASE" cur out state=""
    cur="$(current_id)"
    warn "interrupted deployment detected (last journal entry: $JOURNAL_LAST_OUTCOME -> $JOURNAL_LAST_TO)"
    if [ -n "$pending" ] && [ "$cur" = "$pending" ]; then
        # The switch already happened: undo it before doing anything else.
        journal RECOVERED OK "controller restart during ${JOURNAL_LAST_TO}; restoring the previous release"
        rollback_to_previous "deployment interrupted during ${JOURNAL_LAST_TO}" ""
        journal RECOVERED RECOVERED "recovered from the interrupted deployment of $pending"
        return 0
    fi
    # Nothing was switched: the live tree was never touched.
    out="${HPMMO_STATE_DIR%/}/logs/.recover-state.json"
    admin_request GET "${HPMMO_ADMIN_URL%/}/admin/status" "" "$out"
    [ "$HTTP_CODE" = "200" ] && state="$(json_str "$out" state || true)"
    rm -f "$out"
    if [ -n "$state" ]; then
        journal RECOVERED RECOVERED "interrupted deployment of ${pending:-$JOURNAL_LAST_RELEASE} aborted before the switch; world reports $state"
        set_state "$state" "recovered: interrupted deployment of ${pending:-$JOURNAL_LAST_RELEASE} ended before the switch (world reports $state)"
    else
        journal RECOVERED RECOVERED "interrupted deployment of ${pending:-$JOURNAL_LAST_RELEASE} aborted before the switch; the active release is unchanged"
    fi
    return 0
}

# --- staging -----------------------------------------------------------------
STAGED_ID=""

stage_from_source() {  # artifact id generate_manifest
    local src="$1" id="$2" gen_manifest="${3:-0}"
    local tmp="${HPMMO_STATE_DIR%/}/staging.$$" level mutated=0 tree_hash
    REASON=""
    [ -n "$id" ] || die 2 "--id is required (or derive it from the artifact name)"
    case "$id" in *[!A-Za-z0-9._-]*) die 2 "release id '$id' may only contain letters, digits, dot, dash and underscore" ;; esac
    [ -d "$(release_dir "$id")" ] && die 3 "release '$id' is already staged (releases are immutable)"
    [ -e "$src" ] || die 2 "artifact $src does not exist"

    rm -rf "$tmp"
    mkdir -p "$tmp"
    if [ -d "$src" ]; then
        say "copying $src into the staging tree"
        cp -a "$src/." "$tmp/" || { rm -rf "$tmp"; die 3 "cannot copy $src"; }
    else
        say "extracting $src"
        if ! tar -xzf "$src" -C "$tmp" 2>/dev/null; then
            rm -rf "$tmp"
            die 3 "cannot extract $src (expected a .tar.gz built by deploy/package_server.sh)"
        fi
    fi

    if [ "$gen_manifest" = "1" ]; then
        warn "--generate-manifest: computing SHA256SUMS locally (adopting an existing tree)"
        ( cd "$tmp" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z \
            | xargs -0 -r sha256sum > SHA256SUMS )
    fi
    [ -f "$tmp/SHA256SUMS" ] || { rm -rf "$tmp"; die 3 "artifact has no SHA256SUMS (refusing to stage an unverified release)"; }
    [ -s "$tmp/SHA256SUMS" ] || { rm -rf "$tmp"; die 3 "artifact SHA256SUMS is empty"; }
    say "verifying SHA256SUMS"
    if ! ( cd "$tmp" && sha256sum -c --strict --quiet SHA256SUMS >/dev/null 2>&1 ); then
        rm -rf "$tmp"
        die 3 "SHA256SUMS does not match the artifact - refusing to stage"
    fi
    [ -f "$tmp/world/project.godot" ] || { rm -rf "$tmp"; die 3 "artifact is missing world/project.godot"; }
    level="$(expected_schema_level "$tmp")"
    [ -n "$level" ] || { rm -rf "$tmp"; die 3 "artifact is missing db/migrations/*.sql"; }
    if find "$tmp" -name '*.db' -print -quit | grep -q .; then
        rm -rf "$tmp"
        die 3 "artifact contains an account database file (*.db)"
    fi

    if [ ! -x "$tmp/services/cpp/build/hpmmo_service" ]; then
        case "$HPMMO_STAGE_BUILD" in
            0) rm -rf "$tmp"; die 3 "artifact has no built service binary and HPMMO_STAGE_BUILD=0" ;;
            *) say "building the C++ service in the staging tree"
               if ! ( cd "$tmp" && cmake -S services/cpp -B services/cpp/build -G Ninja \
                        -DCMAKE_BUILD_TYPE=Release >"${HPMMO_STATE_DIR%/}/logs/stage-build-$id.log" 2>&1 \
                        && ninja -C services/cpp/build >>"${HPMMO_STATE_DIR%/}/logs/stage-build-$id.log" 2>&1 ); then
                   rm -rf "$tmp"
                   die 3 "staging build failed (see ${HPMMO_STATE_DIR%/}/logs/stage-build-$id.log)"
               fi
               mutated=1 ;;
        esac
    fi
    if [ ! -d "$tmp/world/.godot/imported" ]; then
        case "$HPMMO_STAGE_IMPORT" in
            0) warn "artifact has no Godot import cache and HPMMO_STAGE_IMPORT=0" ;;
            *) if [ -x "$HPMMO_GODOT" ]; then
                   say "running the Godot import pass in the staging tree"
                   ( "$HPMMO_GODOT" --headless --path "$tmp/world" --editor --import --quit \
                       >"${HPMMO_STATE_DIR%/}/logs/stage-import-$id.log" 2>&1 ) \
                       || warn "Godot import pass failed (see logs/stage-import-$id.log)"
                   mutated=1
               else
                   warn "no Godot binary at $HPMMO_GODOT; the release ships without an import cache"
               fi ;;
        esac
    fi

    # Freeze: nothing may write into the release once it is visible.
    chmod -R a-w "$tmp" 2>/dev/null || warn "could not remove write permission from the staged tree"
    tree_hash="$(file_tree_hash "$tmp")"
    mkdir -p "${HPMMO_STATE_DIR%/}/releases"
    printf '{"id":"%s","staged_at":"%s","tree_hash":"%s","post_stage_mutated":%s,"manifest_source":"%s","schema_level":%s}\n' \
        "$id" "$(now_iso)" "$tree_hash" "$( [ "$mutated" = "1" ] && printf 1 || printf 0 )" \
        "$( [ "$gen_manifest" = "1" ] && printf local || printf artifact )" "${level:-0}" \
        > "$(release_meta "$id")"
    mv "$tmp" "$(release_dir "$id")"
    STAGED_ID="$id"
    say "staged release '$id' at $(release_dir "$id") (schema level ${level:-?}, tree ${tree_hash})"
    return 0
}

cmd_stage() {  # artifact id generate_manifest
    local source="${1:-}" id="${2:-}" gen="${3:-0}" derived
    [ -n "$source" ] || die 2 "--stage needs an artifact (.tar.gz or a directory)"
    [ -e "$source" ] || die 2 "artifact $source does not exist"
    if [ -z "$id" ]; then
        derived="$(basename "$source")"
        derived="${derived%.tar.gz}"; derived="${derived%.tgz}"; derived="${derived%.tar}"
        derived="${derived#hpmmo-server-}"
        id="$derived"
    fi
    stage_from_source "$source" "$id" "$gen"
}

# --- preflight ---------------------------------------------------------------
smoke_command() {
    local dir="$1"
    if [ -n "${HPMMO_SMOKE_CMD:-}" ]; then printf '%s' "$HPMMO_SMOKE_CMD"; else printf '%s' "$dir/deploy/smoke_client.sh"; fi
}

preflight() {  # id dir
    local id="$1" dir="$2" unit probe smoke
    for tool in curl sha256sum sed date ln mv tar find; do
        command -v "$tool" >/dev/null 2>&1 || die 2 "required tool '$tool' is not installed"
    done
    # mv -T (GNU coreutils) is what makes the activation switch atomic.
    probe="${HPMMO_STATE_DIR%/}/.mv-probe.$$"
    rm -rf "$probe"; mkdir -p "$probe/a"
    mv -T "$probe/a" "$probe/result" 2>/dev/null || true
    if [ ! -d "$probe/result" ]; then
        rm -rf "$probe"
        die 2 "this mv does not support -T; an atomic active-release switch is not possible here"
    fi
    rm -rf "$probe"

    [ "$(current_id)" != "$id" ] || die 2 "release '$id' is already the active release"

    for unit in "$HPMMO_UNIT_DIR/$HPMMO_DB_UNIT" "$HPMMO_UNIT_DIR/$HPMMO_WORLD_UNIT" "$HPMMO_UNIT_DIR/$HPMMO_STATUS_UNIT"; do
        [ -f "$unit" ] || die 2 "$unit is missing - run deploy/install_layout.sh first"
    done
    if ! grep -Fq "${HPMMO_RELEASES_DIR%/}/current" "$HPMMO_UNIT_DIR/$HPMMO_DB_UNIT" \
       || ! grep -Fq "${HPMMO_RELEASES_DIR%/}/current" "$HPMMO_UNIT_DIR/$HPMMO_WORLD_UNIT"; then
        die 2 "$HPMMO_WORLD_UNIT/$HPMMO_DB_UNIT do not point into ${HPMMO_RELEASES_DIR%/}/current - run deploy/install_layout.sh to upgrade the units"
    fi

    smoke="$(smoke_command "$dir")"
    if [ ! -x "$smoke" ] && ! command -v "$smoke" >/dev/null 2>&1; then
        die 2 "no synthetic login check available ($smoke); set HPMMO_SMOKE_CMD in $HPMMO_ENV_FILE (see docs/runbook-rollback.md)"
    fi

    case "${HPMMO_ADMIN_URL}" in
        http://127.0.0.1:*|http://localhost:*|http://\[::1\]:*) ;;
        *) warn "HPMMO_ADMIN_URL=$HPMMO_ADMIN_URL is not a loopback address; the world admin interface must never be public" ;;
    esac
    return 0
}

run_smoke_check() {  # release dir -> 0/1 (sets SMOKE_REASON)
    local dir="$1" cmd log
    cmd="$(smoke_command "$dir")"
    log="${HPMMO_STATE_DIR%/}/logs/smoke-$(basename "$dir").log"
    say "running the synthetic login+join check: $cmd"
    if HPMMO_SMOKE_RELEASE="$dir" "$cmd" >"$log" 2>&1; then
        SMOKE_REASON="$(tr -d '\n' < "$log" | tail -c 200)"
        return 0
    fi
    SMOKE_REASON="$(tr -d '\n' < "$log" | tail -c 400)"
    return 1
}

# --- the deployment ----------------------------------------------------------
cmd_deploy() {  # id [reason] [cold]
    local id="$1" reason="${2:-planned release}" cold="${3:-0}"
    local dir; dir="$(release_dir "$id")"
    local begin_body code out detail prev_dir prev_id expected served_version release_version

    # 1. verify the staged release before anything else happens
    if ! verify_release "$id" "$dir"; then
        journal REFUSED REFUSED "release $id refused: $REASON"
        die 3 "release $id refused: $REASON"
    fi

    # 2. serialize deployments
    if ! acquire_lock; then
        journal REFUSED REFUSED "another deployment holds the lock"
        die 9 "another deployment holds the lock (waited ${HPMMO_LOCK_WAIT}s)"
    fi
    recover_if_needed
    if ! verify_release "$id" "$dir"; then
        journal REFUSED REFUSED "release $id refused after locking: $REASON"
        die 3 "release $id refused: $REASON"
    fi
    preflight "$id" "$dir"

    prev_dir="$(current_target)"
    prev_id="$(basename "$prev_dir" 2>/dev/null || true)"
    ACTIVE_RELEASE="$id"
    PREV_RELEASE="$prev_id"
    [ -n "$prev_id" ] || warn "no active release yet (first deployment): a rollback will not be possible"
    mkdir -p "${HPMMO_STATE_DIR%/}/logs"
    local pre_state="$CURRENT_STATE"

    if [ "$cold" = "1" ]; then
        # --cold-start: the one-time transition onto this layout (and any
        # recovery while the world server is already down). It is refused unless
        # the world service is provably not running, because skipping the
        # drain/save barrier is only safe when there are no players.
        if "$HPMMO_SYSTEMCTL" is-active --quiet "$HPMMO_WORLD_UNIT" >/dev/null 2>&1; then
            journal REFUSED REFUSED "cold start refused: $HPMMO_WORLD_UNIT is active"
            die 2 "--cold-start refused: $HPMMO_WORLD_UNIT is running. Use a normal deployment (announce/drain/save), or stop the world server first."
        fi
        journal BUILD_AND_STAGE PENDING "cold start of $id (world server confirmed stopped, reason: $reason, previous: ${prev_id:-none})"
        transition BUILD_AND_STAGE "release $id verified (cold start)"
        transition APPLYING "cold start: the world server is already stopped"
    else
    # 3. announce maintenance (the world server owns drain/save/disconnect)
    journal BUILD_AND_STAGE PENDING "deployment of $id starting (reason: $reason, previous: ${prev_id:-none})"
    transition BUILD_AND_STAGE "release $id verified (schema level $(expected_schema_level "$dir"))"

    out="${HPMMO_STATE_DIR%/}/logs/.begin.json"
    begin_body="$(printf '{"reason":"server update %s","countdown_seconds":%s}' \
        "$(printf '%s' "$id" | tr -d '"\\')" "${HPMMO_MAINTENANCE_COUNTDOWN:-300}")"
    admin_request POST "${HPMMO_ADMIN_URL%/}/admin/maintenance/begin" "$begin_body" "$out"
    code="$HTTP_CODE"
    local begin_state
    begin_state="$(json_str "$out" state || true)"
    detail="$(truncate_str "$(cat "$out" 2>/dev/null || true)")"
    rm -f "$out"
    case "$code" in
        200|202)
            transition ANNOUNCING "maintenance announced (${HPMMO_MAINTENANCE_COUNTDOWN}s countdown)" ;;
        409)
            # The world server refuses begin() from any state but ONLINE.
            # A cycle that is already running is exactly what we want.
            case "$begin_state" in
                ANNOUNCING|DRAINING|SAVING|DISCONNECTING|MAINTENANCE)
                    transition ANNOUNCING "a maintenance cycle is already running (state $begin_state); continuing" ;;
                *)
                    journal FAILED FAILED "world server refused maintenance from state ${begin_state:-unknown} - no files were touched"
                    restore_observed_state "$pre_state" "deployment aborted: the world server refused maintenance"
                    die 5 "world server refused /admin/maintenance/begin from state ${begin_state:-unknown}: $detail
Nothing was changed. A world server in FAILED keeps its players and refuses joins; decide what to do from the journal." ;;
            esac ;;
        403)
            journal FAILED FAILED "the admin interface rejected the service token (HTTP 403) - no files were touched"
            restore_observed_state "$pre_state" "deployment aborted: the admin interface rejected the service token"
            die 4 "the world server admin interface rejected X-Service-Token (HTTP 403).
Check that HPMMO_SERVICE_TOKEN in $HPMMO_ENV_FILE matches the value the world service was started with; nothing was changed." ;;
        *)
            journal FAILED FAILED "maintenance interface unavailable (HTTP $code) - no files were touched"
            restore_observed_state "$pre_state" "deployment aborted: maintenance interface unavailable; no files changed"
            die 4 "world server did not accept /admin/maintenance/begin (HTTP $code): $detail
The world server admin interface (${HPMMO_ADMIN_URL%/}/admin) must be reachable; nothing was changed." ;;
    esac

    # 4. drain: the world server drives ANNOUNCING -> ... -> MAINTENANCE
    if ! wait_world_state MAINTENANCE "$HPMMO_DRAIN_TIMEOUT"; then
        journal FAILED FAILED "world server did not reach MAINTENANCE within ${HPMMO_DRAIN_TIMEOUT}s (${WAIT_REASON:-last state: ${LAST_WORLD_STATE:-unknown}}) - no files were touched"
        restore_observed_state "${LAST_WORLD_STATE:-$pre_state}" "deployment aborted: the world server did not reach maintenance; no files changed"
        die 5 "the world server did not reach MAINTENANCE (${WAIT_REASON:-last state: ${LAST_WORLD_STATE:-unknown}}); nothing was changed."
    fi

    # 5. final save barrier (a deferred request: it answers once the flush has
    #    been acknowledged, so it gets its own timeout budget)
    out="${HPMMO_STATE_DIR%/}/logs/.save.json"
    admin_request POST "${HPMMO_ADMIN_URL%/}/admin/save" '{}' "$out" "$HPMMO_SAVE_TIMEOUT"
    code="$HTTP_CODE"
    if [ "$code" = "404" ]; then
        # The world server as built registers this route as /admin/admin/save.
        # Accept it, but record the deviation instead of hiding it.
        warn "POST /admin/save answered 404; retrying /admin/admin/save (contract says /admin/save)"
        admin_request POST "${HPMMO_ADMIN_URL%/}/admin/admin/save" '{}' "$out" "$HPMMO_SAVE_TIMEOUT"
        code="$HTTP_CODE"
        if [ "$code" = "200" ]; then
            journal MAINTENANCE OK "save accepted on /admin/admin/save (the documented route is /admin/save)"
        fi
    fi
    local failed=""
    [ "$code" = "200" ] && failed="$(json_int "$out" failed || true)"
    if [ "$code" != "200" ] || [ "$failed" != "0" ]; then
        detail="$(truncate_str "$(cat "$out" 2>/dev/null || true)")"
        rm -f "$out"
        journal FAILED FAILED "final save failed (HTTP $code, failed=${failed:-unknown}) - staying in maintenance, no swap"
        set_state MAINTENANCE "final save failed (HTTP $code, failed=${failed:-unknown}); release not swapped"
        die 6 "final save failed: HTTP $code failed=${failed:-unknown} $detail
The old release stays active and the world stays in maintenance."
    fi
    rm -f "$out"
    journal MAINTENANCE OK "final save accepted (failed=0)"

    # 6. apply: stop the old world process, migrate with the NEW binary, switch
    transition APPLYING "stopping the world server"
    if ! svc stop "$HPMMO_WORLD_UNIT" >/dev/null 2>&1; then
        journal FAILED FAILED "could not stop $HPMMO_WORLD_UNIT - no swap performed"
        set_state MAINTENANCE "deployment aborted: could not stop the world server"
        die 6 "could not stop $HPMMO_WORLD_UNIT; nothing was changed"
    fi
    journal APPLYING OK "world server stopped"
    fi   # end of the normal (non-cold-start) announce/drain/save/stop path

    local migrate_log="${HPMMO_STATE_DIR%/}/logs/migrate-$id.log"
    say "applying migrations with the new binary"
    if ! ( cd "$dir" && HPMMO_MIGRATIONS_DIR="$dir/db/migrations" \
            "./services/cpp/build/hpmmo_service" migrate >"$migrate_log" 2>&1 ); then
        journal APPLYING FAILED "migration failed (see $migrate_log)"
        warn "migration failed; restoring the previous release (a binary rollback does NOT undo a migration)"
        rollback_to_previous "migration failed; the database rollback is a manual step (see docs/runbook-rollback.md)" "$prev_dir"
        exit 7
    fi
    expected="$(expected_schema_level "$dir")"
    journal APPLYING OK "migrations applied; schema level $expected"

    local tmp="${HPMMO_RELEASES_DIR%/}/.current.$$"
    ln -sfn "$dir" "$tmp"
    if ! mv -T "$tmp" "${HPMMO_RELEASES_DIR%/}/current"; then
        rm -f "$tmp"
        journal APPLYING FAILED "could not switch the active release symlink"
        rollback_to_previous "activation switch failed" "$prev_dir"
        case "$ROLLBACK_RESULT" in failed) exit 11 ;; no_previous) exit 10 ;; *) exit 8 ;; esac
    fi
    # A switcher that silently copies (msys/cygwin without symlink support)
    # would leave the live release on disk forever: refuse it.
    if [ ! -L "${HPMMO_RELEASES_DIR%/}/current" ]; then
        rm -rf "${HPMMO_RELEASES_DIR%/}/current" 2>/dev/null || true
        journal APPLYING FAILED "current is not a symlink - this filesystem cannot switch releases atomically"
        rollback_to_previous "active release pointer is not a symlink" "$prev_dir"
        case "$ROLLBACK_RESULT" in failed) exit 11 ;; no_previous) exit 10 ;; *) exit 8 ;; esac
    fi
    printf '%s\n' "$prev_dir" > "${HPMMO_STATE_DIR%/}/previous_release"
    publish_release_state
    # The flag is a JSON document so hpmmo_status.py can read the state and the
    # reason while the world server is stopped; it is removed on a verified
    # ONLINE and left in place by every failure path.
    printf '{"state":"MAINTENANCE","since":"%s","reason":"deploying %s"}\n' \
        "$(now_iso)" "$(printf '%s' "$id" | tr -d '"\\')" \
        > "${HPMMO_STATE_DIR%/}/maintenance.flag"
    journal APPLYING OK "current -> $id (previous ${prev_id:-none})"
    say "active release switched to $id"

    if ! restart_db_service; then
        journal VERIFYING FAILED "$HPMMO_DB_UNIT failed to restart"
        rollback_to_previous "$HPMMO_DB_UNIT failed to restart" "$prev_dir"
        case "$ROLLBACK_RESULT" in failed) exit 11 ;; no_previous) exit 10 ;; *) exit 8 ;; esac
    fi
    journal APPLYING OK "$HPMMO_DB_UNIT restarted"

    # 7. verify the new release before anything can join
    transition VERIFYING "verifying release $id"
    if ! wait_service_ready "$HPMMO_VERIFY_TIMEOUT"; then
        journal VERIFYING FAILED "/api/health or /api/ready did not become ready within ${HPMMO_VERIFY_TIMEOUT}s"
        rollback_to_previous "readiness check failed" "$prev_dir"
        case "$ROLLBACK_RESULT" in failed) exit 11 ;; no_previous) exit 10 ;; *) exit 8 ;; esac
    fi
    if [ "$READY_SCHEMA" != "$expected" ]; then
        journal VERIFYING FAILED "/api/ready reports schema $READY_SCHEMA, expected $expected"
        rollback_to_previous "schema level mismatch ($READY_SCHEMA != $expected)" "$prev_dir"
        case "$ROLLBACK_RESULT" in failed) exit 11 ;; no_previous) exit 10 ;; *) exit 8 ;; esac
    fi
    journal VERIFYING OK "/api/health ok; /api/ready ok (schema $READY_SCHEMA)"

    local vout="${HPMMO_STATE_DIR%/}/logs/.version.json"
    api_request GET "${HPMMO_API_URL%/}/api/version" "" "$vout"
    if [ "$HTTP_CODE" != "200" ]; then
        rm -f "$vout"
        journal VERIFYING FAILED "/api/version returned HTTP $HTTP_CODE"
        rollback_to_previous "/api/version failed" "$prev_dir"
        case "$ROLLBACK_RESULT" in failed) exit 11 ;; no_previous) exit 10 ;; *) exit 8 ;; esac
    fi
    served_version="$(json_str "$vout" version || true)"
    release_version=""
    [ -f "$dir/services/version.json" ] && release_version="$(json_str "$dir/services/version.json" version || true)"
    rm -f "$vout"
    if [ -n "$release_version" ] && [ "$served_version" != "$release_version" ]; then
        journal VERIFYING FAILED "/api/version reports '$served_version', the release ships '$release_version'"
        rollback_to_previous "service version mismatch ($served_version != $release_version)" "$prev_dir"
        case "$ROLLBACK_RESULT" in failed) exit 11 ;; no_previous) exit 10 ;; *) exit 8 ;; esac
    fi
    journal VERIFYING OK "/api/version ok ($served_version)"

    if ! svc restart "$HPMMO_WORLD_UNIT" >/dev/null 2>&1; then
        journal VERIFYING FAILED "$HPMMO_WORLD_UNIT failed to restart"
        rollback_to_previous "$HPMMO_WORLD_UNIT failed to restart" "$prev_dir"
        case "$ROLLBACK_RESULT" in failed) exit 11 ;; no_previous) exit 10 ;; *) exit 8 ;; esac
    fi
    if ! wait_world_state ONLINE "$HPMMO_VERIFY_TIMEOUT"; then
        journal VERIFYING FAILED "world server did not report ONLINE within ${HPMMO_VERIFY_TIMEOUT}s"
        rollback_to_previous "world server did not report ONLINE" "$prev_dir"
        case "$ROLLBACK_RESULT" in failed) exit 11 ;; no_previous) exit 10 ;; *) exit 8 ;; esac
    fi
    journal VERIFYING OK "world server reports ONLINE"

    if ! run_smoke_check "$dir"; then
        journal VERIFYING FAILED "synthetic login+join check failed: $SMOKE_REASON"
        rollback_to_previous "synthetic login+join check failed" "$prev_dir"
        case "$ROLLBACK_RESULT" in failed) exit 11 ;; no_previous) exit 10 ;; *) exit 8 ;; esac
    fi
    journal VERIFYING OK "synthetic login+join check passed"

    rm -f "${HPMMO_STATE_DIR%/}/maintenance.flag"
    transition ONLINE "release $id verified and online"

    local sout="${HPMMO_STATE_DIR%/}/logs/.status-endpoint.json"
    http_request GET "http://${HPMMO_STATUS_HOST}:${HPMMO_STATUS_PORT}/status" "" "$sout" ""
    if [ "$HTTP_CODE" = "200" ]; then
        journal ONLINE OK "status endpoint reports $(json_str "$sout" state || true)"
    else
        warn "status endpoint http://${HPMMO_STATUS_HOST}:${HPMMO_STATUS_PORT}/status is not answering (HTTP $HTTP_CODE)"
        journal ONLINE OK "WARNING: the status endpoint is not answering (HTTP $HTTP_CODE)"
    fi
    rm -f "$sout"

    say "release $id is live (previous ${prev_id:-none} kept at ${prev_dir:-/})"
    say "releases other than current and previous may be deleted from ${HPMMO_RELEASES_DIR%/}"
    return 0
}

# --- operator commands -------------------------------------------------------
cmd_rollback() {  # reason
    local reason="${1:-operator request}" prev="" prev_file="${HPMMO_STATE_DIR%/}/previous_release"
    if ! acquire_lock; then
        journal REFUSED REFUSED "rollback refused: another deployment holds the lock"
        die 9 "another deployment holds the lock (waited ${HPMMO_LOCK_WAIT}s)"
    fi
    recover_if_needed
    [ -f "$prev_file" ] && prev="$(cat "$prev_file" 2>/dev/null || true)"
    ACTIVE_RELEASE="$(current_id)"
    if [ -z "$prev" ] || [ ! -d "$prev" ]; then
        journal REFUSED REFUSED "rollback refused: no previous release recorded"
        die 10 "no previous release recorded in $prev_file; nothing to roll back to"
    fi
    rollback_to_previous "$reason" "$prev"
    case "$ROLLBACK_RESULT" in
        failed) die 11 "rollback could not restore a healthy service - escalate (see docs/runbook-rollback.md)" ;;
        no_previous) die 10 "rollback found no previous release" ;;
    esac
    say "rollback done - maintenance remains ACTIVE so no release is advertised as online"
    exit 0
}

cmd_status() {
    local state="UNKNOWN" release="" previous="" since="" message=""
    if [ -f "$STATUS_FILE" ]; then
        state="$(json_str "$STATUS_FILE" state || true)"
        release="$(json_str "$STATUS_FILE" release || true)"
        previous="$(json_str "$STATUS_FILE" previous_release || true)"
        since="$(json_str "$STATUS_FILE" since || true)"
        message="$(json_str "$STATUS_FILE" message || true)"
    fi
    [ -n "$release" ] || release="$(current_id)"
    if [ -z "$previous" ] && [ -f "${HPMMO_STATE_DIR%/}/previous_release" ]; then
        previous="$(basename "$(cat "${HPMMO_STATE_DIR%/}/previous_release")")"
    fi
    printf 'state:        %s\n' "${state:-UNKNOWN}"
    printf 'release:      %s\n' "${release:-(none)}"
    printf 'previous:     %s\n' "${previous:-(none)}"
    printf 'since:        %s\n' "${since:-(unknown)}"
    printf 'message:      %s\n' "${message:-(none)}"
    printf 'releases dir: %s\n' "${HPMMO_RELEASES_DIR%/}"
    printf 'state dir:    %s\n' "${HPMMO_STATE_DIR%/}"
    if deployment_interrupted; then
        printf 'in flight:    %s (interrupted; run --recover)\n' "${JOURNAL_PENDING_RELEASE:-$JOURNAL_LAST_RELEASE}"
    fi
    if [ -f "$JOURNAL" ]; then
        printf 'journal (last %s):\n' "$HPMMO_STATUS_LINES"
        tail -n "$HPMMO_STATUS_LINES" "$JOURNAL" | sed 's/^/  /'
    else
        printf 'journal:      (none yet)\n'
    fi
}

usage() {
    cat <<EOF
$PROG - HPMMO staged deployment controller (plan.md Phase 6)

Usage:
  $PROG --stage <artifact.tar.gz|directory> [--id ID] [--generate-manifest]
        Verify, build (if needed) and freeze an immutable release. No player
        impact: the running world is untouched.
  $PROG --release <id> [--reason TEXT]
        Deploy a staged release: announce, drain, final save, migrate, switch,
        restart, verify - rolling back automatically on failure.
  $PROG --release <id> --cold-start
        The same, but skip the announce/drain/save barrier. Refused unless the
        world service is verifiably stopped: it exists for the one-time move
        onto this layout and for recovery while the world is already down.
  $PROG --deploy <artifact> [--id ID] [--reason TEXT]
        --stage followed by --release.
  $PROG --recover
        Finish or undo a deployment interrupted by a controller restart.
  $PROG --rollback [--reason TEXT]
        Operator rollback: restore the previous release, restart it and keep
        maintenance ACTIVE.
  $PROG --status [--journal N]
        Print the current state, the active/previous release and the journal tail.

Environment (production defaults):
  HPMMO_RELEASES_DIR=${HPMMO_RELEASES_DIR%/}   HPMMO_STATE_DIR=${HPMMO_STATE_DIR%/}
  HPMMO_ENV_FILE=$HPMMO_ENV_FILE
  HPMMO_ADMIN_URL=${HPMMO_ADMIN_URL:-http://127.0.0.1:${HPMMO_ADMIN_PORT}}   HPMMO_API_URL=${HPMMO_API_URL:-http://127.0.0.1:8081}
  HPMMO_SYSTEMCTL=$HPMMO_SYSTEMCTL   HPMMO_UNIT_DIR=$HPMMO_UNIT_DIR
  HPMMO_SMOKE_CMD=<release>/deploy/smoke_client.sh
  HPMMO_MAINTENANCE_COUNTDOWN=$HPMMO_MAINTENANCE_COUNTDOWN   HPMMO_DRAIN_TIMEOUT=$HPMMO_DRAIN_TIMEOUT
  HPMMO_HOLD_TIMEOUT=$HPMMO_HOLD_TIMEOUT   HPMMO_ADMIN_READY_TIMEOUT=$HPMMO_ADMIN_READY_TIMEOUT
See server/docs/runbook-rollback.md.
EOF
}

# --- main --------------------------------------------------------------------
main() {
    local command="" artifact="" id="" reason="" gen_manifest=0 cold=0 arg

    while [ $# -gt 0 ]; do
        case "$1" in
            --stage) command=stage; artifact="${2:-}"; shift 2 ;;
            --release) command=release; id="${2:-}"; shift 2 ;;
            --deploy) command=deploy; artifact="${2:-}"; shift 2 ;;
            --recover) command=recover; shift ;;
            --rollback) command=rollback; shift ;;
            --status) command=status; shift ;;
            --id) id="${2:-}"; shift 2 ;;
            --reason) reason="${2:-}"; shift 2 ;;
            --journal) HPMMO_STATUS_LINES="${2:-10}"; shift 2 ;;
            --cold-start) cold=1; shift ;;
            --generate-manifest) gen_manifest=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die 2 "unknown argument: $1" ;;
        esac
    done
    [ -n "$command" ] || { usage >&2; exit 2; }

    save_caller_env
    if [ -f "$HPMMO_ENV_FILE" ]; then
        set -a
        # shellcheck disable=SC1090
        . "$HPMMO_ENV_FILE"
        set +a
    fi
    restore_caller_env

    : "${HPMMO_ADMIN_URL:=http://127.0.0.1:${HPMMO_ADMIN_PORT:-8082}}"
    : "${HPMMO_API_URL:=http://127.0.0.1:8081}"
    state_dirs
    mkdir -p "${HPMMO_STATE_DIR%/}/logs" "${HPMMO_STATE_DIR%/}/releases"
    ACTIVE_RELEASE="$(current_id)"
    if [ -f "$STATUS_FILE" ]; then
        arg="$(json_str "$STATUS_FILE" state || true)"
        [ -n "$arg" ] && CURRENT_STATE="$arg"
    fi

    case "$command" in
        status)   cmd_status ;;
        stage)    cmd_stage "$artifact" "$id" "$gen_manifest" ;;
        release)  [ -n "$id" ] || die 2 "--release needs a release id"; cmd_deploy "$id" "$reason" "$cold" ;;
        deploy)   [ -n "$artifact" ] || die 2 "--deploy needs an artifact"
                  cmd_stage "$artifact" "$id" "$gen_manifest"
                  cmd_deploy "$STAGED_ID" "$reason" "$cold" ;;
        recover)  if ! acquire_lock; then die 9 "another deployment holds the lock"; fi
                  recover_if_needed
                  say "recovery check complete" ;;
        rollback) cmd_rollback "$reason" ;;
    esac
}

main "$@"
