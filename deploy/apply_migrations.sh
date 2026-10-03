#!/usr/bin/env bash
set -e
# Applies db/migrations/*.sql in lexical order (DDL is idempotent).
DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="/etc/hpmmo/hpmmo.env"
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi
: "${HPMMO_DB_PASSWORD:?set HPMMO_DB_PASSWORD via $ENV_FILE}"
for f in "$DIR"/db/migrations/*.sql; do
    echo "applying $(basename "$f")"
    PGPASSWORD="$HPMMO_DB_PASSWORD" psql -h localhost -U hpmmo -d hpmmo_db -f "$f"
done
