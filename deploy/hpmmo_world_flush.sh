#!/usr/bin/env bash
# ExecStop of hpmmo.service: save every character before systemd stops the
# world (an operator's `systemctl stop|restart hpmmo`, a host reboot). Without
# it those stops lost everything since the last autosave (up to ~50 s) and the
# unsent debounced saves. hpmmo_deploy.sh runs its own barrier first, so during
# a deployment this finds the world in MAINTENANCE with nothing left to save.
#
# Never fails the stop: whatever happens here, systemd goes on to SIGTERM.
# The service token travels through a curl config on stdin (never argv).
set -u

ENV_FILE="${HPMMO_ENV_FILE:-/etc/hpmmo/hpmmo.env}"
if [ -z "${HPMMO_SERVICE_TOKEN:-}" ] && [ -r "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
fi
URL="${HPMMO_ADMIN_URL:-http://127.0.0.1:${HPMMO_ADMIN_PORT:-8082}}"
TOKEN="${HPMMO_SERVICE_TOKEN:-}"
case "$TOKEN" in
    "" ) echo "[hpmmo-flush] no service token; skipping the stop save" >&2; exit 0 ;;
    *[!A-Za-z0-9._~+/=:-]* ) echo "[hpmmo-flush] unexpected characters in the service token; skipping" >&2; exit 0 ;;
esac

code="$(printf 'header = "X-Service-Token: %s"\n' "$TOKEN" | curl -K - -sS --max-time 40 -o /dev/null \
    -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data '{}' "${URL%/}/admin/save" 2>/dev/null || true)"
echo "[hpmmo-flush] stop save answered HTTP ${code:-000}"
exit 0
