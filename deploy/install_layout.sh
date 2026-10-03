#!/bin/bash
# =============================================================================
# HPMMO release-layout installer (plan.md Phase 6)
# =============================================================================
#
# One-time (and idempotent) provisioning of the staged release layout:
#
#   * creates HPMMO_RELEASES_DIR and HPMMO_STATE_DIR
#   * installs hpmmo_status.py to a stable path (it must keep answering while
#     releases come and go, so it does NOT live inside a release)
#   * installs the three systemd units with the local paths substituted; the
#     world/db units run through <releases>/current, so a release swap never
#     edits a unit
#   * optionally adopts the currently deployed tree as the first release
#     (--adopt), giving the first controller deployment a rollback target
#
# Usage:
#   sudo deploy/install_layout.sh [--adopt /root/hpmmo/game]
#                                 [--run-user root] [--godot /root/hpmmo/bin/godot_server]
#                                 [--no-units] [--no-start]
#
# Adopting stops nothing and touches no service: stop hpmmo/hpmmo-db yourself
# before adopting a live tree, then start them again (the runbook walks through
# it). The adopted release is recorded as both current and previous, because it
# is the known-good baseline the first real deployment must be able to return to.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROG="$(basename "$0")"

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
: "${HPMMO_STATUS_PORT:=8083}"
: "${HPMMO_RUN_USER:=root}"

ADOPT=""
INSTALL_UNITS=1
START_STATUS=1
PYTHON="$(command -v python3 || true)"

say()  { printf '[hpmmo-layout] %s\n' "$*"; }
warn() { printf '[hpmmo-layout] WARNING: %s\n' "$*" >&2; }
die()  { printf '[hpmmo-layout] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --adopt) ADOPT="${2:-}"; shift 2 ;;
        --run-user) HPMMO_RUN_USER="${2:-}"; shift 2 ;;
        --godot) HPMMO_GODOT="${2:-}"; shift 2 ;;
        --releases-dir) HPMMO_RELEASES_DIR="${2:-}"; shift 2 ;;
        --state-dir) HPMMO_STATE_DIR="${2:-}"; shift 2 ;;
        --no-units) INSTALL_UNITS=0; shift ;;
        --no-start) START_STATUS=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

[ -n "$PYTHON" ] || die "python3 is required for the status endpoint"
[ -d "$HERE/systemd" ] || die "$HERE/systemd is missing (run install_layout.sh from deploy/)"

render_unit() {  # template out
    local template="$1" out="$2"
    sed -e "s|@RELEASES_DIR@|${HPMMO_RELEASES_DIR%/}|g" \
        -e "s|@STATE_DIR@|${HPMMO_STATE_DIR%/}|g" \
        -e "s|@ENV_FILE@|${HPMMO_ENV_FILE}|g" \
        -e "s|@RUN_USER@|${HPMMO_RUN_USER}|g" \
        -e "s|@GODOT@|${HPMMO_GODOT}|g" \
        -e "s|@PYTHON@|${PYTHON}|g" \
        -e "s|@STATUS_SCRIPT@|${HPMMO_STATUS_SCRIPT}|g" \
        -e "s|@STATUS_PORT@|${HPMMO_STATUS_PORT}|g" \
        "$template" > "$out"
}

say "releases dir: ${HPMMO_RELEASES_DIR%/}"
say "state dir:    ${HPMMO_STATE_DIR%/}"
mkdir -p "${HPMMO_RELEASES_DIR%/}" "${HPMMO_STATE_DIR%/}/logs" "${HPMMO_STATE_DIR%/}/releases"
STATUS_DIR="$(dirname "$HPMMO_STATUS_SCRIPT")"
mkdir -p "$STATUS_DIR"
install -m 0755 "$HERE/hpmmo_status.py" "$HPMMO_STATUS_SCRIPT"
say "installed the status endpoint at $HPMMO_STATUS_SCRIPT"
# A stable controller path: the deploy job must not run the controller out of a
# release directory whose `current` symlink it is about to move.
install -m 0755 "$HERE/hpmmo_deploy.sh" "$STATUS_DIR/hpmmo_deploy.sh"
say "installed the controller at $STATUS_DIR/hpmmo_deploy.sh"

if [ "$INSTALL_UNITS" = "1" ]; then
    [ -d "$HPMMO_UNIT_DIR" ] || die "$HPMMO_UNIT_DIR does not exist"
    render_unit "$HERE/systemd/$HPMMO_DB_UNIT"     "$HPMMO_UNIT_DIR/$HPMMO_DB_UNIT"
    render_unit "$HERE/systemd/$HPMMO_WORLD_UNIT"  "$HPMMO_UNIT_DIR/$HPMMO_WORLD_UNIT"
    render_unit "$HERE/systemd/$HPMMO_STATUS_UNIT" "$HPMMO_UNIT_DIR/$HPMMO_STATUS_UNIT"
    say "installed units in $HPMMO_UNIT_DIR"
    if command -v "$HPMMO_SYSTEMCTL" >/dev/null 2>&1; then
        "$HPMMO_SYSTEMCTL" daemon-reload
        if [ "$START_STATUS" = "1" ]; then
            "$HPMMO_SYSTEMCTL" enable --now "$HPMMO_STATUS_UNIT" || warn "could not start $HPMMO_STATUS_UNIT"
        fi
    else
        warn "$HPMMO_SYSTEMCTL not found; skipping daemon-reload"
    fi
fi

if [ -n "$ADOPT" ]; then
    [ -d "$ADOPT" ] || die "--adopt $ADOPT is not a directory"
    id="$(basename "${ADOPT%/}")"
    say "adopting $ADOPT as release '$id' (services should already be stopped)"
    HPMMO_RELEASES_DIR="$HPMMO_RELEASES_DIR" HPMMO_STATE_DIR="$HPMMO_STATE_DIR" \
    HPMMO_ENV_FILE="$HPMMO_ENV_FILE" HPMMO_GODOT="$HPMMO_GODOT" \
        bash "$HERE/hpmmo_deploy.sh" --stage "$ADOPT" --id "$id" --generate-manifest

    tmp="${HPMMO_RELEASES_DIR%/}/.current.$$"
    ln -sfn "${HPMMO_RELEASES_DIR%/}/$id" "$tmp"
    mv -T "$tmp" "${HPMMO_RELEASES_DIR%/}/current"
    if [ ! -L "${HPMMO_RELEASES_DIR%/}/current" ]; then
        die "current is not a symlink - this filesystem cannot switch releases atomically"
    fi
    printf '%s\n' "${HPMMO_RELEASES_DIR%/}/$id" > "${HPMMO_STATE_DIR%/}/previous_release"
    printf '%s\n' "$id" > "${HPMMO_STATE_DIR%/}/active_release"
    cat > "${HPMMO_STATE_DIR%/}/release.env" <<EOF
# Generated by install_layout.sh (adopted release).
HPMMO_RELEASE=$id
HPMMO_RELEASE_ID=$id
HPMMO_PREVIOUS_RELEASE=$id
EOF
    say "active release is now '$id' (also recorded as the previous known-good release)"
    say "the adopted tree at $ADOPT was copied, not moved: verify the services, then delete it"
fi

cat <<EOF

Next steps:
  1. review $HPMMO_ENV_FILE (secrets stay there; chmod 600)
  2. $HPMMO_SYSTEMCTL start $HPMMO_DB_UNIT $HPMMO_WORLD_UNIT
  3. sudo bash $HERE/hpmmo_deploy.sh --status
  4. deploy with:  sudo bash $HERE/hpmmo_deploy.sh --deploy <artifact.tar.gz>

Status endpoint: http://127.0.0.1:${HPMMO_STATUS_PORT}/status (loopback only).
Rollback runbook: server/docs/runbook-rollback.md
EOF
