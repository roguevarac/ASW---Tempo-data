#!/bin/sh
# Corre todas las pruebas del sistema contra un Postgres local (por defecto el del entorno, puerto 54340).
# Cada prueba arranca con la base recién instalada. Uso: tests/correr_todo.sh
# Requiere: psql, python3 con fastapi uvicorn psycopg[binary,pool] pyjwt httpx croniter playwright.
set -eu
cd "$(dirname "$0")/.."
SERVIDOR="${PGHOST_URL:-postgresql://postgres@localhost:54340}"
export PGURL="$SERVIDOR/ranking"
TMP="$(mktemp -d)"
export STORAGE_DIR="$TMP/storage"
PUERTO="${PUERTO:-8787}"
export BASE="http://localhost:$PUERTO"

base_nueva() {
    psql "$SERVIDOR/postgres" -q -c "DROP DATABASE IF EXISTS ranking WITH (FORCE)" -c "CREATE DATABASE ranking"
    AUTHENTICATOR_PASSWORD="prueba_local_123" db/instalar.sh >/dev/null
    psql "$PGURL" -q -At >/dev/null <<'SQL'
SELECT auth.set_password('admin@prueba.local', 'clave-admin-123');
SELECT auth.set_password('estandar@prueba.local', 'clave-estandar-123');
SELECT auth.set_password('auditor@prueba.local', 'clave-auditor-123');
INSERT INTO public.app_users (user_id, app_role, oficina)
SELECT id, CASE WHEN email LIKE 'admin%' THEN 'admin' WHEN email LIKE 'auditor%' THEN 'auditor' ELSE 'usuario_estandar' END, 'AR'
FROM auth.users;
SQL
    rm -rf "$STORAGE_DIR"; mkdir -p "$STORAGE_DIR"
}

base_nueva
(cd api && DATABASE_URL="postgresql://authenticator:prueba_local_123@${SERVIDOR#postgresql://*@}/ranking" \
    JWT_SECRET="secreto-de-prueba-local-de-mas-de-32-caracteres" YOUTUBE_CRON="" \
    exec python3 -m uvicorn app:app --port "$PUERTO" >"$TMP/api.log" 2>&1) &
API=$!
trap 'kill $API 2>/dev/null; rm -rf "$TMP"' EXIT
i=0; until curl -sf "$BASE/health" >/dev/null; do i=$((i+1)); [ $i -lt 50 ] || { cat "$TMP/api.log"; exit 1; }; sleep 0.2; done

FALLAS=0
correr() { echo "== $1"; shift; "$@" || FALLAS=$((FALLAS+1)); }

correr "Esquema igual al de Supabase" python3 tests/comparar_con_supabase.py
correr "API de punta a punta" python3 tests/test_e2e.py
base_nueva
correr "Tarea de YouTube" env DATABASE_URL="postgresql://authenticator:prueba_local_123@${SERVIDOR#postgresql://*@}/ranking" \
    JWT_SECRET="secreto-de-prueba-local-de-mas-de-32-caracteres" python3 tests/test_youtube.py
base_nueva
correr "Front en el navegador" python3 tests/test_navegador.py
correr "Migración (exportar + importar)" env PGHOST_URL="$SERVIDOR" STORAGE_ORIGEN="$STORAGE_DIR" python3 tests/test_migracion.py
if docker info >/dev/null 2>&1; then
    correr "Scripts de Windows (PowerShell + Docker)" env PGHOST_URL="$SERVIDOR" STORAGE_ORIGEN="$STORAGE_DIR" python3 tests/test_windows.py
else
    echo "== Scripts de Windows: se saltean (no hay Docker)"
fi

echo
[ "$FALLAS" -eq 0 ] && echo "TODAS LAS PRUEBAS OK" || { echo "$FALLAS PRUEBAS CON FALLAS"; exit 1; }
