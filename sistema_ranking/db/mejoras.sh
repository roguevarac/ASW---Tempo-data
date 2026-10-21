#!/bin/sh
# Aplica las mejoras propias de la base (db/mejoras/*.sql, en orden). Son idempotentes: se corren en cada arranque,
# así una base ya instalada recibe lo nuevo sin perder datos. Uso: PGURL=postgresql://postgres:...@host/ranking ./mejoras.sh
set -eu
export PGOPTIONS="-c client_min_messages=warning"
cd "$(dirname "$0")"
: "${PGURL:?Falta PGURL}"
for f in mejoras/*.sql; do
    [ -e "$f" ] || continue
    psql "$PGURL" -v ON_ERROR_STOP=1 -q -c "SET ROLE app_owner" -f "$f"
done
echo "Mejoras de la base aplicadas."
