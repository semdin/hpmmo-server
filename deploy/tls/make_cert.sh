#!/bin/bash
# =============================================================================
# HPMMO release-listener TLS certificate (plan.md Phase 7)
# =============================================================================
#
# Generates the SELF-SIGNED certificate that the read-only release/status
# listener (deploy/hpmmo_status.py --tls-cert/--tls-key) serves to the launcher.
#
# It is self-signed on purpose: the launcher PINS it (SPKI sha256), so there is
# no CA to trust and no hostname dependency on a public CA. Pinning means the
# certificate is a long-lived deployment fact, not a renewable service - hence
# the ~825 day validity and a SAN that names the exact host the launcher talks
# to. This file being self-signed is documented, not accidental.
#
# What this prints is what the launcher embeds:
#
#   SPKI-SHA256  sha256 of the DER SubjectPublicKeyInfo. The launcher refuses a
#                server whose certificate does not hash to this value, which is
#                stronger than trusting any CA: only this exact key is accepted.
#
# Usage:
#   deploy/tls/make_cert.sh [--host NAME_OR_IP] [--san EXTRA] [--out DIR]
#                           [--days N] [--ec] [--force]
#
#   --host   the name/IP the launcher will use (default: the host this runs on,
#            or 213.250.145.75 when it cannot be determined). An IP host is put
#            into the SAN as IP:, anything else as DNS:.
#   --san    an additional SAN entry (repeatable), written verbatim, so you can
#            add both the public IP and an internal name to one certificate.
#   --out    where to write release-cert.pem / release-key.pem (default: .)
#   --days   validity in days (default: 825)
#   --ec     ECDSA P-256 instead of RSA-2048 (smaller, equally pinnable)
#   --force  overwrite an existing certificate
#
# The private key is 0600 and must never enter a repository: the script refuses
# an output directory inside a git working tree unless --force is given.
# =============================================================================
set -euo pipefail

# Git Bash on Windows rewrites /CN=... into a Windows path before openssl sees
# it (this script is rehearsed from a Windows workstation as well as run on the
# box). Harmless elsewhere.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

HERE="$(cd "$(dirname "$0")" && pwd)"

HOST=""
OUT="$(pwd)"
DAYS=825
FORCE=0
KEYARGS=(-newkey rsa:2048)
SANS=()

say() { printf '[tls] %s\n' "$*"; }
die() { printf '[tls] ERROR: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="${2:-}"; shift 2 ;;
        --san)  SANS+=("${2:-}"); shift 2 ;;
        --out)  OUT="${2:-}"; shift 2 ;;
        --days) DAYS="${2:-}"; shift 2 ;;
        --ec)   KEYARGS=(-newkey ec -pkeyopt ec_paramgen_curve:prime256v1); shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

command -v openssl >/dev/null 2>&1 || die "openssl is not installed"
case "$DAYS" in ''|*[!0-9]*) die "--days must be a number";; esac
[ "$DAYS" -ge 1 ] || die "--days must be positive"

if [ -z "$HOST" ]; then
    HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -n "$HOST" ] || HOST="213.250.145.75"
fi

# An IP host belongs in the SAN as IP:, a name as DNS:. Getting this wrong is
# the difference between a pin that verifies and one that does not.
case "$HOST" in
    *[!0-9.]*) PRIMARY="DNS:$HOST" ;;
    *)         PRIMARY="IP:$HOST" ;;
esac
SAN_LIST="$PRIMARY"
for extra in "${SANS[@]:-}"; do
    [ -n "$extra" ] || continue
    SAN_LIST="$SAN_LIST,$extra"
done

mkdir -p "$OUT"
CERT="$OUT/release-cert.pem"
KEY="$OUT/release-key.pem"

if [ -e "$CERT" ] || [ -e "$KEY" ]; then
    if [ "$FORCE" != "1" ]; then
        die "$CERT or $KEY already exists - pass --force to replace a pinned certificate (launchers must be re-pinned first)"
    fi
fi

# Custody: the TLS private key is a secret exactly like the signing key.
current="$(cd "$OUT" && pwd)"
while :; do
    if [ -e "$current/.git" ] && [ "$FORCE" != "1" ]; then
        die "$OUT is inside a git working tree - a private key must never live in a repository (--force overrides)"
    fi
    parent="$(dirname "$current")"
    [ "$parent" != "$current" ] || break
    current="$parent"
done

umask 077
say "generating a ${DAYS}-day self-signed certificate for $SAN_LIST"
openssl req -x509 -new "${KEYARGS[@]}" -nodes \
    -keyout "$KEY" -out "$CERT" -days "$DAYS" -sha256 \
    -subj "/CN=$HOST/O=HPMMO Release/OU=release-listener" \
    -addext "subjectAltName=$SAN_LIST" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1
chmod 600 "$KEY"
chmod 644 "$CERT"

# The pin: sha256 over the DER SubjectPublicKeyInfo. Stable under certificate
# renewal with the same key, and impossible to fake without the private key.
SPKI="$(openssl x509 -in "$CERT" -noout -pubkey \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | openssl dgst -sha256 -hex | awk '{print $NF}')"
FINGERPRINT="$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-Z' 'a-z')"
NOT_AFTER="$(openssl x509 -in "$CERT" -noout -enddate | cut -d= -f2)"

say "wrote $CERT"
say "wrote $KEY (mode 600 - never commit this, never copy it off the box)"
say "valid until: $NOT_AFTER"
say "certificate sha256 fingerprint (for humans): $FINGERPRINT"
printf '\n'
printf 'PIN THIS IN THE LAUNCHER (SPKI sha256):\n  %s\n\n' "$SPKI"
printf 'Serve it (loopback until you expose the listener):\n'
printf '  HPMMO_STATUS_TLS_CERT=%s HPMMO_STATUS_TLS_KEY=%s \\\n' "$CERT" "$KEY"
printf '  HPMMO_STATUS_RELEASES_ROOT=/srv/hpmmo/client-releases \\\n'
printf '  python3 deploy/hpmmo_status.py --host 0.0.0.0 --port 8443\n'
printf 'See server/docs/phase7-release-contract.md for the exact exposure change.\n'
