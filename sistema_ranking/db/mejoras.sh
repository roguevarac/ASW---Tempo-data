#!/bin/sh
# Aplica las mejoras propias de la base (db/mejoras/*.sql, en orden). Son idempotentes: se corren en cada arranque,
# así una base ya instalada recibe lo nuevo sin perder datos. Uso: PGURL=postgresql://postgres:...@host/ranking ./mejoras.sh
set -eu
export PGOPTIONS="-c client_min_messages=warning"
cd "$(dirname "$0")"
: "${PGURL:?Falta PGURL}"
# Firma de las mejoras: si la base ya tiene exactamente estas (y no le falta ningún objeto: misma cantidad de tablas,
# índices y funciones que al aplicarlas), no se vuelven a aplicar. Así el arranque es más rápido.
firma="$(cat mejoras/*.sql | md5sum | cut -d' ' -f1)"
OBJETOS="(SELECT count(*) FROM pg_proc WHERE pronamespace::regnamespace::text IN ('public', 'auth', 'panel'))
         + (SELECT count(*) FROM pg_class WHERE relnamespace::regnamespace::text IN ('public', 'auth', 'panel'))"
if [ "${FORZAR_MEJORAS:-}" != 1 ] && [ "$(psql "$PGURL" -At -c "SELECT detalle ->> 'firma' = '$firma'
        AND (detalle ->> 'objetos')::bigint = $OBJETOS FROM panel.servicios WHERE servicio = 'instalador'" 2> /dev/null)" = t ]; then
    echo "Mejoras de la base al día."
    exit 0
fi
for f in mejoras/*.sql; do
    [ -e "$f" ] || continue
    psql "$PGURL" -v ON_ERROR_STOP=1 -q -c "SET ROLE app_owner" -f "$f"
done
# Aviso para el Panel de control: cuándo se actualizó la base por última vez.
psql "$PGURL" -q -c "SELECT panel.latido('instalador', jsonb_build_object('mejoras', $(ls mejoras/*.sql | wc -l),
    'firma', '$firma', 'objetos', $OBJETOS))" \
    > /dev/null 2>&1 || true
echo "Mejoras de la base aplicadas."
