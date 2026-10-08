#!/bin/bash
# =============================================================================
# HPMMO server updater - compatibility wrapper
# =============================================================================
#
# the original updater stopped the services, extracted a tarball over the live
# tree and compiled on the box. the maintenance surface replaces that with the staged,
# journalled controller in deploy/hpmmo_deploy.sh:
#
#   verify checksums -> lock -> announce maintenance -> drain -> final save
#   -> stop world -> migrate with the new binary -> atomic switch -> restart
#   -> verify (health/ready/version/online/synthetic login) -> ONLINE
#   ... or ROLLBACK with maintenance left ACTIVE
#
# This wrapper keeps the old invocation working:
#
#   bash deploy/update_server.sh [artifact.tar.gz]
#
# is equivalent to
#
#   bash deploy/hpmmo_deploy.sh --deploy artifact.tar.gz
#
# Nothing is written into the live tree at any point; see
# server/docs/runbook-rollback.md for the operational details and the rollback
# procedure.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ARCHIVE="${1:-$HOME/hpmmo_server.tar.gz}"

printf '[update_server] deprecated wrapper: run deploy/hpmmo_deploy.sh --deploy instead\n' >&2

if [ ! -f "$ARCHIVE" ]; then
    printf '[update_server] ERROR: package not found at %s\n' "$ARCHIVE" >&2
    exit 1
fi

exec bash "$HERE/hpmmo_deploy.sh" --deploy "$ARCHIVE"
