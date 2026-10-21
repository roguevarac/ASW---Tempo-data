#!/bin/sh
# Crea la base completa. Uso: PGURL=postgresql://postgres:...@host:5432/ranking ./instalar.sh
# Variables: PGURL (superusuario), AUTHENTICATOR_PASSWORD (contraseña del rol de la API).
set -eu
export PGOPTIONS="-c client_min_messages=warning"
cd "$(dirname "$0")"
: "${PGURL:?Falta PGURL}"; : "${AUTHENTICATOR_PASSWORD:?Falta AUTHENTICATOR_PASSWORD}"
psql "$PGURL" -v ON_ERROR_STOP=1 -q -f 01_roles_extensiones.sql
psql "$PGURL" -v ON_ERROR_STOP=1 -q -c "ALTER ROLE authenticator PASSWORD '$AUTHENTICATOR_PASSWORD'"
psql "$PGURL" -v ON_ERROR_STOP=1 -q -c "SET ROLE app_owner" -f 02_auth_storage.sql -f 03_esquema.sql -f 04_rls_politicas.sql
psql "$PGURL" -v ON_ERROR_STOP=1 -q -f 05_permisos.sql -f 06_datos_iniciales.sql
sh ./mejoras.sh > /dev/null
echo "Base instalada."
