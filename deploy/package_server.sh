#!/bin/bash
# =============================================================================
# HPMMO server packager (Linux) - plan.md Phase 6
# =============================================================================
#
# Linux equivalent of deploy/package_server.ps1, with two Phase 6 changes:
#
#   * the C++ service is built here and the binary ships in the artifact, so
#     the staged release is complete before it is frozen (no compiling on the
#     box during a deployment);
#   * a SHA256SUMS manifest is generated and travels inside the artifact, which
#     is what deploy/hpmmo_deploy.sh verifies before it will stage a release.
#
# Contents: world/ services/ contracts/ db/ deploy/ tests/ README.md
# Excluded: .git, Godot editor caches, __pycache__, *.db, *.pyc, *.log, build
#           intermediates (only services/cpp/build/hpmmo_service is kept),
#           asset candidates, and any client visual payload.
#
# Usage:
#   deploy/package_server.sh [--out DIR] [--id ID] [--no-build] [--check]
#
#   --check     validate the source tree and print what would be packaged
#               (read-only; no build, no output written)
# Environment:
#   HPMMO_GODOT optional Godot binary; when set and the world has no import
#               cache, the headless import pass runs before packaging
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="$REPO/dist"
STAMP="$(date +%Y%m%d-%H%M%S)"
ID=""
DO_BUILD=1
CHECK_ONLY=0
GODOT="${HPMMO_GODOT:-}"

say()  { printf '[package] %s\n' "$*"; }
die()  { printf '[package] ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="${2:-}"; shift 2 ;;
        --id) ID="${2:-}"; shift 2 ;;
        --no-build) DO_BUILD=0; shift ;;
        --check) CHECK_ONLY=1; shift ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$ID" ] || ID="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || true)"
[ -n "$ID" ] || ID="$STAMP"
case "$ID" in *[!A-Za-z0-9._-]*) die "release id '$ID' contains characters the controller rejects" ;; esac

check_tree() {
    local missing=""
    for item in world services contracts db deploy tests README.md; do
        [ -e "$REPO/$item" ] || missing="$missing $item"
    done
    [ -n "$missing" ] || return 0
    die "server repo at $REPO is missing:$missing"
}

check_tree
if [ "$CHECK_ONLY" = "1" ]; then
    say "repo:   $REPO"
    say "id:     $ID"
    say "world:  $(find "$REPO/world" -type f 2>/dev/null | wc -l) files"
    say "c++:    $([ -d "$REPO/services/cpp" ] && echo present || echo missing)"
    say "migrations: $(find "$REPO/db/migrations" -name '*.sql' 2>/dev/null | wc -l)"
    say "godot:  ${GODOT:-(not set; the artifact ships without an import cache)}"
    say "check passed (nothing was written)"
    exit 0
fi

if [ "$DO_BUILD" = "1" ]; then
    say "building the C++ service"
    cmake -S "$REPO/services/cpp" -B "$REPO/services/cpp/build" -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null
    ninja -C "$REPO/services/cpp/build" >/dev/null
fi
[ -x "$REPO/services/cpp/build/hpmmo_service" ] || die "services/cpp/build/hpmmo_service was not built"

if [ -n "$GODOT" ] && [ -x "$GODOT" ] && [ ! -d "$REPO/world/.godot/imported" ]; then
    say "running the Godot import pass"
    "$GODOT" --headless --path "$REPO/world" --editor --import --quit >/dev/null 2>&1 \
        || say "WARNING: the Godot import pass failed; staging can still run it on the server"
fi

mkdir -p "$OUT"
STAGE="$OUT/.stage-$STAMP"
rm -rf "$STAGE"
mkdir -p "$STAGE"

say "staging $ID"
for item in world services contracts db deploy tests README.md; do
    cp -a "$REPO/$item" "$STAGE/$item"
done

# Prune by the same rules as package_server.ps1.
find "$STAGE" -depth \( -name '.git' -o -name '__pycache__' -o -name 'candidates' -o -name 'node_modules' \) -exec rm -rf {} + 2>/dev/null || true
find "$STAGE" -type f \( -name '*.db' -o -name '*.pyc' -o -name '*.log' -o -name '*.db-journal' \) -delete
rm -rf "$STAGE/world/.godot/editor"
# Keep only the built service binary out of the build tree.
if [ -d "$STAGE/services/cpp/build" ]; then
    find "$STAGE/services/cpp/build" -mindepth 1 -maxdepth 1 ! -name 'hpmmo_service' -exec rm -rf {} + 2>/dev/null || true
fi

# Exit-check enforcement (same rules as the PowerShell packager).
bad="$(find "$STAGE" -type f -name '*.db' -print -quit)"
[ -z "$bad" ] || die "package contains an account database file: $bad"
[ ! -d "$STAGE/candidates" ] || die "package contains asset candidates"
for forbidden in assets docs launcher_cpp tools; do
    [ ! -e "$STAGE/$forbidden" ] || die "package contains a forbidden root entry: $forbidden"
done
[ -d "$STAGE/world/assets/models" ] || die "world assets are missing - run dev.ps1 sync-world first"
[ -f "$STAGE/services/cpp/build/hpmmo_service" ] || die "the packaged service binary is missing"

say "writing SHA256SUMS"
( cd "$STAGE" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum > SHA256SUMS )

TAR="$OUT/hpmmo-server-$ID.tar.gz"
say "writing $TAR"
tar -czf "$TAR" -C "$STAGE" .
rm -rf "$STAGE"

# Sidecar digest: the CI publishes it beside the artifact so the deployment
# record pins the exact bytes as well as the release identifier.
if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$OUT" && sha256sum "hpmmo-server-$ID.tar.gz" > "hpmmo-server-$ID.tar.gz.sha256" )
fi

say "sizes: $(du -h "$TAR" | cut -f1)"
say "contents (top level):"
tar -tzf "$TAR" | sed 's|^\./||' | awk -F/ 'NF>1 {print $1"/"}' | sort | uniq -c | sed 's/^/  /'
say "wrote $TAR"
say "deploy with: sudo deploy/hpmmo_deploy.sh --deploy $TAR"
