#!/bin/sh
# Corre todas las pruebas del sistema contra un Postgres local (por defecto el del entorno, puerto 54340).
# Cada prueba arranca con la base recién instalada. Uso: tests/correr_todo.sh
# Requiere: psql, python3 con fastapi uvicorn psycopg[binary,pool] pyjwt httpx playwright pexpect packaging.
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
    JWT_SECRET="secreto-de-prueba-local-de-mas-de-32-caracteres" \
    exec python3 -m uvicorn app:app --port "$PUERTO" >"$TMP/api.log" 2>&1) &
API=$!
trap 'kill $API 2>/dev/null; rm -rf "$TMP"' EXIT
i=0; until curl -sf "$BASE/health" >/dev/null; do i=$((i+1)); [ $i -lt 50 ] || { cat "$TMP/api.log"; exit 1; }; sleep 0.2; done

FALLAS=0
correr() { echo "== $1"; shift; "$@" || FALLAS=$((FALLAS+1)); }

correr "Esquema igual al de Supabase" python3 tests/comparar_con_supabase.py
correr "API de punta a punta" python3 tests/test_e2e.py
base_nueva
correr "Front en el navegador" python3 tests/test_navegador.py
correr "Aplicación instalable (PWA)" python3 tests/test_pwa.py
correr "Espejo de auditoría en OneDrive" python3 tests/test_espejo.py
correr "Migración (exportar + importar)" env PGHOST_URL="$SERVIDOR" STORAGE_ORIGEN="$STORAGE_DIR" python3 tests/test_migracion.py
correr "Comando de certificados de la empresa" python3 tests/test_certificados.py
correr "Ícono del escritorio (WSL)" python3 tests/test_acceso_directo.py
if docker info >/dev/null 2>&1; then
    correr "Linux / WSL2 con Docker Engine (ranking.sh de punta a punta)" env PGHOST_URL="$SERVIDOR" STORAGE_ORIGEN="$STORAGE_DIR" python3 tests/test_docker_linux.py
else
    echo "== Linux / WSL2 con Docker Engine: se saltea (Docker no está corriendo)"
fi
correr "Paquetes de Python para Windows" python3 tests/test_paquetes_windows.py
# Versión portable de Windows: necesita PowerShell (PWSH, en el PATH, en la caché o en la imagen de Docker).
CACHE="${CACHE_PRUEBAS:-/var/tmp/rk_pruebas_cache}"
if [ -n "${PWSH:-}" ] || command -v pwsh >/dev/null 2>&1 || [ -x "$CACHE/pwsh/pwsh" ] || \
   docker image inspect mcr.microsoft.com/powershell:lts-7.4-ubuntu-22.04 >/dev/null 2>&1; then
    [ -z "${PWSH:-}" ] && command -v pwsh >/dev/null 2>&1 && export PWSH="$(command -v pwsh)"
    correr "Versión portable de Windows (de punta a punta)" env PGHOST_URL="$SERVIDOR" STORAGE_ORIGEN="$STORAGE_DIR" python3 tests/test_portable.py
    correr "Componentes reales de Windows (bajar, verificar, descomprimir)" python3 tests/test_componentes_windows.py
else
    echo "== Versión portable de Windows: se saltea (no hay PowerShell)"
fi

# Al final: vacía la base de prueba (las anteriores usan los datos de la prueba del navegador como origen).
correr "Carga masiva de charts históricos (paridad con Carga CSV)" python3 tests/test_importar_charts.py
echo
[ "$FALLAS" -eq 0 ] && echo "TODAS LAS PRUEBAS OK" || { echo "$FALLAS PRUEBAS CON FALLAS"; exit 1; }
