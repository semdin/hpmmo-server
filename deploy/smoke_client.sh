#!/bin/bash
# =============================================================================
# HPMMO synthetic login+join check (VERIFYING)
# =============================================================================
#
# Run by deploy/hpmmo_deploy.sh after the new release is running and before it
# is advertised as ONLINE. A TCP/ENet probe is not a login: this must be a real
# client that logs in through the account service and joins the world.
#
# Resolution order:
#   1. $HPMMO_SMOKE_CMD           - an explicit smoke command (never this file),
#                                   taken from /etc/hpmmo/hpmmo.env
#   2. a headless Godot client    - <release>/world/server/smoke_client.tscn or
#                                   smoke_client.gd, run with $HPMMO_GODOT
#   3. fail closed (exit 3)       - with instructions; the controller treats a
#                                   missing check as a verification failure and
#                                   rolls back rather than advertising a
#                                   release nobody proved.
#
# The scene/script is owned by the world server workstream; this wrapper only
# locates and runs it. Credentials for the check come from the environment
# file (HPMMO_SMOKE_USER / HPMMO_SMOKE_PASSWORD) and are never printed.
#
# Usage: smoke_client.sh <release-dir>   (or $HPMMO_SMOKE_RELEASE is used)
# Exit:  0 pass, non-zero fail (stdout/stderr is captured in the deployment log)
# =============================================================================
set -uo pipefail

RELEASE="${1:-${HPMMO_SMOKE_RELEASE:-}}"
GODOT="${HPMMO_GODOT:-/root/hpmmo/bin/godot_server}"
SCENE="${HPMMO_SMOKE_SCENE:-res://server/smoke_client.tscn}"
SCRIPT="${HPMMO_SMOKE_SCRIPT:-res://server/smoke_client.gd}"
TIMEOUT="${HPMMO_SMOKE_TIMEOUT:-60}"

say() { printf '[smoke] %s\n' "$*"; }

if [ -z "$RELEASE" ] || [ ! -d "$RELEASE" ]; then
    say "FAIL: release directory not given or missing (got '${RELEASE:-}')"
    exit 3
fi

# 1. explicit override
this_file="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
if [ -n "${HPMMO_SMOKE_CMD:-}" ]; then
    override="$(readlink -f "$HPMMO_SMOKE_CMD" 2>/dev/null || printf '%s' "$HPMMO_SMOKE_CMD")"
    if [ "$override" != "$this_file" ]; then
        say "delegating to HPMMO_SMOKE_CMD=$HPMMO_SMOKE_CMD"
        exec "$HPMMO_SMOKE_CMD" "$RELEASE"
    fi
    say "HPMMO_SMOKE_CMD points at this script; using the built-in Godot check"
fi

# 2. headless Godot client shipped in the release world project
if [ ! -x "$GODOT" ]; then
    say "FAIL: no Godot binary at $GODOT (set HPMMO_GODOT) and no HPMMO_SMOKE_CMD"
    exit 3
fi

run_godot() {  # args...
    local -a cmd=("$GODOT" --headless --path "$RELEASE/world" "$@")
    if command -v timeout >/dev/null 2>&1; then
        timeout "$TIMEOUT" "${cmd[@]}"
    else
        "${cmd[@]}"
    fi
}

if [ -f "$RELEASE/world/server/smoke_client.gd" ]; then
    say "running $SCRIPT against $RELEASE"
    run_godot --script "$SCRIPT"
    rc=$?
elif [ -f "$RELEASE/world/server/smoke_client.tscn" ]; then
    say "running $SCENE against $RELEASE"
    run_godot "$SCENE"
    rc=$?
else
    say "FAIL: this release ships no synthetic client check"
    say "      expected world/server/smoke_client.tscn or world/server/smoke_client.gd,"
    say "      or set HPMMO_SMOKE_CMD in /etc/hpmmo/hpmmo.env (see server/docs/runbook-rollback.md)"
    exit 3
fi

if [ "$rc" -eq 0 ]; then
    say "PASS: synthetic login+join check succeeded"
else
    say "FAIL: synthetic login+join check exited $rc"
fi
exit "$rc"
