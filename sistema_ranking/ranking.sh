#!/usr/bin/env bash
# Ranking Digital con Docker Engine en Linux / WSL2 (sin Docker Desktop). Se usa desde la terminal de Ubuntu:
#
#   bash ranking.sh instalar        arma y arranca el sistema (la primera vez: crea la base y las claves)
#   bash ranking.sh migrar          trae de Supabase los datos, los usuarios y el historial
#   bash ranking.sh abrir           arranca el sistema si estaba apagado y lo abre en el navegador de Windows
#   bash ranking.sh detener         lo apaga (los datos quedan guardados)
#   bash ranking.sh usuarios        crear usuarios, cambiar contraseñas, roles, bloquear
#   bash ranking.sh estado          qué está corriendo y dónde
#   bash ranking.sh logs            últimos mensajes del sistema
#   bash ranking.sh respaldo        copia de la base y los archivos en ~/proyectos/ranking-respaldos
#   bash ranking.sh restaurar F     vuelve a un respaldo (F = el nombre que mostró "respaldo")
#   bash ranking.sh vaciar-historial  borra solo los archivos del historial (antes hace un respaldo)
#   bash ranking.sh empezar-de-cero   borra todos los datos menos los usuarios (antes hace un respaldo)
#   bash ranking.sh cargar-historicos  carga una vez los charts de "Spotify Charts" y "Youtube Charts" de OneDrive
#   bash ranking.sh espejo          copia a OneDrive (espejo de auditoría) los archivos cargados que falten
#   bash ranking.sh certificados    toma los certificados de la empresa desde Windows (proxy que inspecciona HTTPS)
#   bash ranking.sh acceso-directo  crea la aplicación "Ranking Digital" en Windows (escritorio, menú Inicio, inicio)
#   bash ranking.sh verificar       revisa que todo esté sano (sin cambiar nada)
#   bash ranking.sh actualizar      respaldo + versión nueva desde GitHub + reinicio, sin perder datos
#   (agregando --automatico, instalar no hace preguntas: lo usan los agentes como Antigravity)
#
# Las claves internas quedan en ~/.config/ranking-digital/ranking.env (fuera del proyecto: una versión nueva del
# proyecto, en otra carpeta, sigue usando la misma base). No compartas ese archivo.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${RK_CONFIG:-$HOME/.config/ranking-digital/ranking.env}"
RESPALDOS="${RK_RESPALDOS:-$HOME/proyectos/ranking-respaldos}"
PROYECTO_SUPABASE="https://ltosqbvzlnncxijzodvd.supabase.co"
ONEDRIVE_BACKOFFICE="OneDrive - Sony/SMP-Administration Argentina - Documents/Latam/Backoffice"
# Espejo de auditoría (respaldos, charts y reportes cargados, documentación). Solo escritura: ver api/espejo.py.
ONEDRIVE_ESPEJO="OneDrive - Sony/SMP-Administration Argentina - Documents/Latam/RANKING DIGITAL REGIONAL"

if [ -t 1 ]; then R=$'\e[31m'; V=$'\e[32m'; A=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'; else R='' V='' A='' C='' N=''; fi
titulo() { printf '\n%s== %s%s\n' "$C" "$*" "$N"; }
ok()     { printf '%s%s%s\n' "$V" "$*" "$N"; }
aviso()  { printf '%s%s%s\n' "$A" "$*" "$N"; }
fallar() { printf '\n%s%s%s\n' "$R" "$*" "$N" >&2; unset SUPABASE_SERVICE_KEY; exit 1; }
# si "pregunta" [S|N]: en modo --automatico (lo usan los agentes, sin nadie que conteste) toma la respuesta por
# defecto; sin respuesta por defecto, en automático es "no" (nunca se borra ni se reemplaza nada sin una persona).
AUTOMATICO=0
si() {
    local r
    if [ "$AUTOMATICO" = 1 ]; then r="${2:-N}"; echo "$1 (S/N): $r  (automático)"
    else read -r -p "$1 (S/N): " r; fi
    [[ "$r" =~ ^[[:space:]]*[sS] ]]
}

# La configuración manda: variables con el mismo nombre en la terminal (que docker compose priorizaría) no se usan.
# El proxy también sale de la configuración: si cada terminal pasara el suyo (la de Ubuntu con proxy, el lanzador
# oculto de Windows sin él), cada "up" vería otra configuración y reiniciaría la API.
CLAVES_PROXY=(HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy)
CLAVES_CONFIG=(POSTGRES_PASSWORD AUTHENTICATOR_PASSWORD JWT_SECRET PUERTO ESCUCHAR SESSION_HOURS MAX_UPLOAD_MB
               STATEMENT_TIMEOUT DB_POOL IMAGEN_POSTGRES IMAGEN_PYTHON ESPEJO_DIR "${CLAVES_PROXY[@]}")
dc() {
    local sin=() k; for k in "${CLAVES_CONFIG[@]}"; do sin+=(-u "$k"); done
    env "${sin[@]}" docker compose --project-directory "$DIR" -f "$DIR/docker-compose.yml" --env-file "$CONFIG" "$@"
}

# ---------------------------------------------------------------- configuración
valor() { local v; v="$(grep -m1 "^$1=" "$CONFIG" 2>/dev/null | cut -d= -f2-)"; v="${v#\'}"; printf '%s' "${v%\'}"; }
poner() {
    local tmp; tmp="$(mktemp "$CONFIG.XXXX")"
    awk -v k="$1" -v v="$2" 'BEGIN { hecho = 0 } index($0, k "=") == 1 { print k "=" v; hecho = 1; next } { print }
                             END { if (!hecho) print k "=" v }' "$CONFIG" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$CONFIG"
}
# El proxy que tenga definido la terminal (ej. en ~/.bashrc) queda guardado en la configuración; una terminal sin
# proxy (el lanzador de Windows) usa el guardado.
PROXY_CAMBIADO=0
guardar_proxy() {
    local k v cambio=0
    for k in "${CLAVES_PROXY[@]}"; do
        v="${!k:-}"
        [ -n "$v" ] && [ "$v" != "$(valor "$k")" ] && { poner "$k" "'$v'"; cambio=1; }
    done
    [ "$cambio" = 0 ] || { PROXY_CAMBIADO=1; ok "Proxy de la terminal guardado en la configuración."; }
}
clave_nueva() { openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
puerto_ocupado() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0
    # En WSL2 el navegador abre localhost de Windows: si un programa de Windows usa ese puerto, también está ocupado.
    if command -v powershell.exe > /dev/null 2>&1; then
        powershell.exe -NoProfile -Command "if (Get-NetTCPConnection -State Listen -LocalPort $1 -ErrorAction SilentlyContinue) { 'SI' }" 2>/dev/null | grep -q SI && return 0
    fi
    return 1
}
puerto_libre() { local p="$1"; while puerto_ocupado "$p"; do p=$((p + 1)); done; echo "$p"; }
direccion() { echo "http://localhost:$(valor PUERTO)"; }
instalado() { [ -f "$CONFIG" ] || fallar "El sistema no está instalado todavía. Corré: bash ranking.sh instalar"; }

# ---------------------------------------------------------------- Docker
# Archivos copiados desde Windows/OneDrive pueden quedar con fin de línea de Windows (\r\n): sh y bash no los leen.
arreglar_fin_de_linea() {
    local f arreglados=0
    while IFS= read -r -d '' f; do
        if grep -q $'\r' "$f"; then sed -i 's/\r$//' "$f"; arreglados=$((arreglados + 1)); fi
    done < <(find "$DIR" \( -name '*.sh' -o -name '*.sql' -o -name '*.py' -o -name '*.yml' -o -name 'Dockerfile' -o -name '*.env.example' \) \
             -not -path '*/windows/*' -print0)
    [ "$arreglados" -gt 0 ] && aviso "Arreglé el fin de línea de $arreglados archivos copiados desde Windows."
    return 0
}
verificar_docker() {
    command -v docker > /dev/null 2>&1 || fallar "No encuentro docker. Instalá Docker Engine en Ubuntu (ver README)."
    if ! docker info > /dev/null 2>&1; then
        aviso "Docker no está corriendo; lo arranco (puede pedir tu contraseña de Ubuntu)..."
        sudo service docker start > /dev/null || true
        local i; for i in $(seq 1 30); do docker info > /dev/null 2>&1 && break; sleep 1; done
        docker info > /dev/null 2>&1 || fallar "Docker no arrancó. Probá: sudo service docker start  (y mirá: sudo service docker status)"
    fi
    docker compose version > /dev/null 2>&1 || fallar "Falta el plugin de Docker Compose: sudo apt install docker-compose-plugin"
    command -v curl > /dev/null 2>&1 || fallar "Falta curl: sudo apt install -y curl"
    case "$DIR" in /mnt/*) aviso "Aviso: el proyecto está en $DIR (disco de Windows u OneDrive). Copialo dentro de Ubuntu:
  cp -r \"$DIR/..\" ~/proyectos/ranking   y corré los comandos desde ~/proyectos/ranking/sistema_ranking";; esac
    arreglar_fin_de_linea
}
explicar_error_red() {   # $1 = archivo con la salida del comando que falló
    if grep -qiE 'x509|certificate|CERTIFICATE_VERIFY|SSL' "$1"; then
        aviso "Parece el proxy de la empresa inspeccionando HTTPS (error de certificado)."
        aviso "Corré:  bash ranking.sh certificados   y después volvé a correr este paso."
    elif grep -qiE 'toomanyrequests|rate limit|429' "$1"; then
        aviso "Docker Hub limitó las descargas por un rato (límite para usuarios anónimos). Esperá una hora, o"
        aviso "iniciá sesión con una cuenta gratuita:  docker login   (o usá un espejo interno: IMAGEN_PYTHON / IMAGEN_POSTGRES en $CONFIG)."
    elif grep -qiE 'proxy|timeout|i/o timeout|no such host|connection refused|network is unreachable|TLS handshake' "$1"; then
        aviso "No hay salida a internet desde Docker. Si en la empresa se usa proxy:"
        aviso "  1) definí el proxy en la terminal (por ejemplo en ~/.bashrc):  export HTTPS_PROXY=http://proxy:puerto HTTP_PROXY=http://proxy:puerto"
        aviso "  2) para que Docker baje imágenes por el proxy, ver la sección 'Red de la empresa' del README."
    fi
}
correr_con_registro() {   # muestra la salida y, si falla, explica los errores de red conocidos
    local log; log="$(mktemp)"
    "$@" 2>&1 | tee "$log"
    local codigo="${PIPESTATUS[0]}"
    [ "$codigo" -ne 0 ] && explicar_error_red "$log"
    rm -f "$log"
    return "$codigo"
}
esperar_sistema() {
    local i url; url="http://127.0.0.1:$(valor PUERTO)/health"
    for i in $(seq 1 90); do
        curl -fsS --noproxy '*' "$url" > /dev/null 2>&1 && return 0
        sleep 1
    done
    dc logs --tail 30 api
    [ "${1:-}" = "--sin-salir" ] && return 1
    fallar "El sistema no responde en $(direccion). Arriba están los últimos mensajes."
}
abrir_navegador() {
    if command -v explorer.exe > /dev/null 2>&1; then explorer.exe "$1" > /dev/null 2>&1 || true
    elif command -v xdg-open > /dev/null 2>&1; then xdg-open "$1" > /dev/null 2>&1 || true; fi
}
# Baja la imagen oficial desde Docker Hub o, si está bloqueado o limitado, desde los espejos públicos de las mismas
# imágenes oficiales (Google y Amazon). La que funcione queda en la configuración.
elegir_imagen() {   # $1 = variable (IMAGEN_POSTGRES / IMAGEN_PYTHON), $2 = imagen oficial (postgres:17)
    local actual log origen; actual="$(valor "$1")"
    if [ -n "$actual" ] && docker image inspect "$actual" > /dev/null 2>&1; then ok "  $actual (ya bajada)"; return 0; fi
    log="$(mktemp)"
    for origen in "${actual:-docker.io/library/$2}" "mirror.gcr.io/library/$2" "public.ecr.aws/docker/library/$2"; do
        echo "  bajando $origen ..."
        if docker pull -q "$origen" > "$log" 2>&1; then poner "$1" "$origen"; ok "  $origen"; rm -f "$log"; return 0; fi
        aviso "    no se pudo: $(tail -1 "$log" | cut -c1-160)"
    done
    explicar_error_red "$log"; rm -f "$log"
    return 1
}
# Carpeta del perfil de Windows (vista desde Ubuntu) y la de Backoffice en OneDrive; vacío si no se encuentra.
perfil_windows() {
    local p=""
    if command -v powershell.exe > /dev/null 2>&1; then
        p="$(cd /mnt/c 2>/dev/null || true; powershell.exe -NoProfile -Command '[Environment]::GetFolderPath("UserProfile")' 2>/dev/null | tr -d '\r')"
        [ -n "$p" ] && p="$(wslpath -u "$p" 2>/dev/null)"
    fi
    if [ -z "$p" ] || [ ! -d "$p/$ONEDRIVE_BACKOFFICE" ]; then
        local c; for c in /mnt/c/Users/*; do [ -d "$c/$ONEDRIVE_BACKOFFICE" ] && { p="$c"; break; }; done
    fi
    printf '%s' "$p"
}
carpeta_backoffice() {
    if [ -n "${RK_BACKOFFICE:-}" ]; then printf '%s' "$RK_BACKOFFICE"; return; fi
    local p; p="$(perfil_windows)"
    [ -n "$p" ] && [ -d "$p/$ONEDRIVE_BACKOFFICE" ] && printf '%s' "$p/$ONEDRIVE_BACKOFFICE"
}
# Carpeta del espejo en OneDrive (ruta de Ubuntu), o vacío si no hay OneDrive. RK_ESPEJO la fija (pruebas).
carpeta_espejo() {
    if [ -n "${RK_ESPEJO:-}" ]; then printf '%s' "$RK_ESPEJO"; return; fi
    local p; p="$(perfil_windows)"
    [ -n "$p" ] && [ -d "$p/$(dirname "$ONEDRIVE_ESPEJO")" ] && printf '%s' "$p/$ONEDRIVE_ESPEJO"
}
# Guarda la carpeta del espejo en la configuración (la usan la API y los respaldos). Si ya está y existe, no busca.
ESPEJO_CAMBIADO=0
configurar_espejo() {
    local actual nueva; actual="$(valor ESPEJO_DIR)"
    if [ -z "${RK_ESPEJO:-}" ] && [ -n "$actual" ] && [ -d "$actual" ]; then return 0; fi
    nueva="$(carpeta_espejo)"
    [ -n "$nueva" ] || return 0
    mkdir -p "$nueva" 2> /dev/null || return 0
    if [ "$nueva" != "$actual" ]; then poner ESPEJO_DIR "'$nueva'"; ESPEJO_CAMBIADO=1; fi
}
# Documentación técnica, manual de uso y esquema de datos, en el espejo (se reemplaza en cada respaldo).
publicar_documentacion() {
    local e d; e="$(valor ESPEJO_DIR)"
    [ -n "$e" ] || return 0
    d="$e/respaldo_documentacion_sistema/docs"
    mkdir -p "$d/esquema" && cp "$DIR/README.md" "$DIR/front/manual.html" "$d/" && cp "$DIR/../ANTIGRAVITY.md" "$d/" 2> /dev/null
    cp "$DIR/db/03_esquema.sql" "$DIR/db/04_rls_politicas.sql" "$DIR"/db/mejoras/*.sql "$d/esquema/" \
        && herramienta_root python /app/api/espejo.py --leeme > /dev/null 2>&1
}

consulta() { dc exec -T db psql -U postgres -d ranking -At -c "$1"; }
usuarios_py() { dc run --rm herramientas python /app/admin/usuarios.py "$@"; }
herramienta() { dc run --rm --no-deps -T herramientas "$@"; }
# Como root: solo para escribir en el espejo de OneDrive (en WSL, /mnt/c solo deja escribir al dueño o a root).
herramienta_root() { dc run --rm --no-deps -T --user root herramientas "$@"; }

# ---------------------------------------------------------------- comandos
cmd_instalar() {
    verificar_docker
    titulo "1/4 Configuración"
    if [ -f "$CONFIG" ]; then
        ok "Ya existe la configuración ($CONFIG); se mantiene."
    else
        mkdir -p "$(dirname "$CONFIG")" && chmod 700 "$(dirname "$CONFIG")"
        umask 077
        cat > "$CONFIG" <<EOF
# Ranking Digital: claves internas generadas al azar. No compartir este archivo.
POSTGRES_PASSWORD=$(clave_nueva)
AUTHENTICATOR_PASSWORD=$(clave_nueva)
JWT_SECRET=$(clave_nueva)
PUERTO=$(puerto_libre 8000)
SESSION_HOURS=8
EOF
        umask 022
        ok "Configuración creada con claves al azar en $CONFIG"
    fi
    guardar_proxy
    configurar_espejo

    titulo "2/4 Bajando PostgreSQL y armando el sistema (la primera vez tarda unos minutos)"
    elegir_imagen IMAGEN_POSTGRES postgres:17 || fallar "No se pudo bajar PostgreSQL (el motivo está arriba)."
    elegir_imagen IMAGEN_PYTHON python:3.12-slim || fallar "No se pudo bajar Python (el motivo está arriba)."
    correr_con_registro dc build api || fallar "No se pudo armar el sistema (el motivo está arriba)."

    titulo "3/4 Arrancando"
    dc up -d || fallar "No arrancó (el motivo está arriba). Para ver más:  bash ranking.sh logs"
    esperar_sistema
    ok "Sistema funcionando en $(direccion)"

    titulo "4/4 Usuarios"
    local n; n="$(consulta "select count(*) from auth.users")" || fallar "No se pudo consultar la base."
    if [ "$n" -gt 0 ]; then
        ok "Hay $n usuarios cargados."
    else
        echo "Todavía no hay usuarios."
        echo "  * Si venís de Supabase, NO crees usuarios ahora: corré  bash ranking.sh migrar  (trae tus usuarios y datos)."
        if si "  * ¿Crear ahora un usuario administrador nuevo?" N; then
            local email oficina; read -r -p "Email: " email; read -r -p "Oficina (ej. AR; Enter para dejarla vacía): " oficina
            echo "Escribí la contraseña (mínimo 10 caracteres; no se ve mientras escribís)."
            usuarios_py crear "$email" admin ${oficina:+"$oficina"} || aviso "No se pudo crear. Reintentá con: bash ranking.sh usuarios"
        fi
    fi
    if command -v powershell.exe > /dev/null 2>&1 && [ -n "${WSL_DISTRO_NAME:-}" ]; then
        si "¿Crear el ícono 'Ranking Digital' en el escritorio de Windows?" S && cmd_acceso_directo
    fi
    ok $'\n'"Listo. Entrá desde el navegador de Windows: $(direccion)"
    echo "Para los próximos días:  bash ranking.sh abrir   (y  bash ranking.sh detener  para apagarlo)."
    abrir_navegador "$(direccion)"
}

cmd_migrar() {
    verificar_docker; instalado
    titulo "1/6 Sistema"
    dc up -d > /dev/null 2>&1 || fallar "No arrancó el sistema. Probá: bash ranking.sh instalar"
    esperar_sistema; ok "Sistema funcionando."

    titulo "2/6 Datos de Supabase"
    local url; read -r -p "URL del proyecto [Enter = $PROYECTO_SUPABASE]: " url
    export SUPABASE_URL="${url:-$PROYECTO_SUPABASE}"; SUPABASE_URL="${SUPABASE_URL%/}"
    echo "Ahora la service_role key: Supabase > Project Settings > API Keys > service_role > Reveal > copiar."
    echo "(Es secreta: se usa solo para esta descarga y no se guarda en ningún lado.)"
    read -r -s -p "service_role key: " SUPABASE_SERVICE_KEY; echo
    [ -n "$SUPABASE_SERVICE_KEY" ] || fallar "No se ingresó la clave."
    export SUPABASE_SERVICE_KEY

    titulo "3/6 Bajando tablas y usuarios de Supabase"
    local bajar=1
    if herramienta test -f /exportacion/manifiesto.json 2> /dev/null; then
        si "Ya hay una descarga anterior. ¿Bajar todo de nuevo? (recomendado si se cargaron datos después)" || bajar=0
    fi
    if [ "$bajar" = 1 ]; then
        herramienta sh -c 'rm -rf /exportacion/* /exportacion/.[!.]* 2>/dev/null; true'
        correr_con_registro dc run --rm --no-deps -e SUPABASE_URL -e SUPABASE_SERVICE_KEY herramientas \
            python /app/migracion/exportar_supabase.py /exportacion --sin-archivos \
            || fallar "No se pudo bajar de Supabase (el motivo está arriba). Si dice 401/403, la clave no es la service_role."
    fi

    titulo "4/6 Carpetas con los CSV del historial"
    echo "Los archivos del historial se toman de estas carpetas (por nombre y tamaño exactos):"
    local carpetas=() c bo; bo="$(carpeta_backoffice)"
    if [ -n "$bo" ]; then
        for c in "$bo/Charts historicos Youtube" "$bo/Charts historicos_spotify"; do
            if [ -d "$c" ]; then carpetas+=("$c"); ok "  $c"; else aviso "  No encontré: $c"; fi
        done
        echo "En OneDrive (Windows): clic derecho sobre cada carpeta > 'Mantener siempre en este dispositivo'."
    fi
    while true; do
        read -r -p "¿Agregar otra carpeta con CSV? (pegá la ruta de Windows o de Ubuntu; Enter para seguir): " c
        [ -z "$c" ] && break
        c="${c%\"}"; c="${c#\"}"
        [[ "$c" =~ ^[A-Za-z]:\\ ]] && c="$(wslpath -u "$c" 2>/dev/null)"
        if [ -d "$c" ]; then carpetas+=("$c"); ok "  $c"; else aviso "  No existe: $c"; fi
    done
    local montajes=() desde=() i=0
    for c in "${carpetas[@]}"; do montajes+=(-v "$c:/carpetas/$i:ro"); desde+=(--archivos-desde "/carpetas/$i"); i=$((i + 1)); done

    titulo "5/6 Importando en el sistema nuevo"
    local reemplazar=() hay
    hay="$(consulta "select (select count(*) from auth.users) + (select count(*) from public.tracks_master)")"
    if [ "$hay" -gt 0 ]; then
        si "El sistema nuevo ya tiene datos o usuarios. ¿Borrarlos y cargar lo de Supabase?" || fallar "Cancelado. No se tocó nada."
        reemplazar=(--reemplazar)
    fi
    importar() {
        dc run --rm "${montajes[@]}" herramientas sh -c 'rm -f /exportacion/archivos_faltantes.txt; exec python /app/migracion/importar.py "$@"' \
            importar /exportacion "${desde[@]}" "${reemplazar[@]}" "$@"
    }
    if ! importar; then
        herramienta test -s /exportacion/archivos_faltantes.txt 2> /dev/null || fallar "La importación no se hizo (el motivo está arriba). La base quedó como estaba."
        echo
        aviso "$(herramienta sh -c 'grep -c . /exportacion/archivos_faltantes.txt') archivos del historial no están en esas carpetas."
        echo "  1 = Bajar solo esos del bucket de Supabase (recomendado)"
        echo "  2 = Importar sin ellos (la carga queda en el historial, pero sin archivo para descargar)"
        echo "  3 = Cancelar"
        local op; read -r -p "Opción: " op
        case "$op" in
            1) correr_con_registro dc run --rm --no-deps -e SUPABASE_URL -e SUPABASE_SERVICE_KEY herramientas \
                   python /app/migracion/exportar_supabase.py /exportacion --bajar-faltantes \
                   || fallar "No se pudieron bajar esos archivos (motivo arriba). No se importó nada."
               importar || fallar "La importación no se hizo (el motivo está arriba). La base quedó como estaba." ;;
            2) importar --permitir-faltantes || fallar "La importación no se hizo (el motivo está arriba)." ;;
            *) fallar "Cancelado. No se importó nada." ;;
        esac
    fi
    unset SUPABASE_SERVICE_KEY
    ok "Datos importados y verificados."

    titulo "6/6 Contraseñas"
    echo "Supabase no entrega las contraseñas: cada usuario necesita una nueva (mínimo 10 caracteres)."
    local email
    while read -r email <&3; do
        [ -z "$email" ] && continue
        if si "¿Poner contraseña a $email ahora?"; then
            until usuarios_py clave "$email"; do si "No se pudo. ¿Reintentar?" || break; done
        else
            aviso "  Pendiente: hacelo después con  bash ranking.sh usuarios"
        fi
    done 3< <(consulta "select email from auth.users where encrypted_password is null order by email")
    ok $'\n'"Migración completa. Entrá con tu email y la contraseña nueva: $(direccion)"
    echo "Revisá la tabla principal, territorios e historial. Cuando todo esté bien, podés apagar Supabase"
    echo "y cambiar la contraseña de la base y las claves del proyecto de Supabase."
    abrir_navegador "$(direccion)"
}

cmd_abrir() {
    local mantener=0 navegador=1 a
    for a in "$@"; do case "$a" in --mantener) mantener=1 ;; --sin-navegador) navegador=0 ;; esac; done
    verificar_docker; instalado
    echo "Arrancando Ranking Digital..."
    # --no-recreate: si ya está funcionando, no lo reinicia (las versiones nuevas las aplica actualizar). Solo si
    # recién se guardó un proxy o una carpeta de espejo nueva, la API se reinicia una vez para tomarlos.
    local recrear=(--no-recreate); [ "$PROXY_CAMBIADO" = 1 ] || [ "$ESPEJO_CAMBIADO" = 1 ] && recrear=()
    dc up -d "${recrear[@]+"${recrear[@]}"}" > /dev/null 2>&1 \
        || { dc up -d "${recrear[@]+"${recrear[@]}"}"; fallar "No arrancó (el motivo está arriba)."; }
    esperar_sistema
    ok "Ranking Digital funcionando: $(direccion)"
    [ "$navegador" = 1 ] && abrir_navegador "$(direccion)"
    if [ "$mantener" = 1 ]; then
        # Lo usa el lanzador de Windows (oculto): mientras este proceso viva, Ubuntu (y con él Docker y el sistema)
        # sigue prendido. Windows apaga Ubuntu cuando no queda ningún proceso suyo.
        echo
        echo "Dejá esta ventana abierta (podés minimizarla): mientras esté abierta, el sistema sigue"
        echo "funcionando. Para volver a abrir la página: $(direccion)"
        echo "Para apagar todo, cerrá esta ventana."
        while true; do sleep 3600; done
    fi
}

cmd_detener() {
    verificar_docker; instalado
    dc stop && ok "Sistema detenido. Los datos quedan guardados; para volver a usarlo:  bash ranking.sh abrir"
}

cmd_usuarios() {
    verificar_docker; instalado
    dc up -d db > /dev/null 2>&1
    local op email rol oficina
    while true; do
        titulo "Usuarios"
        usuarios_py listar
        echo
        echo "  1 = Crear usuario        2 = Cambiar contraseña    3 = Cambiar rol u oficina"
        echo "  4 = Bloquear usuario     5 = Desbloquear usuario   0 = Salir"
        read -r -p "Opción: " op
        [ -z "$op" ] || [ "$op" = 0 ] && break
        read -r -p "Email: " email; [ -z "$email" ] && continue
        case "$op" in
            1) read -r -p "Rol (admin / usuario_estandar / auditor): " rol
               read -r -p "Oficina (ej. AR; Enter para dejarla vacía): " oficina
               usuarios_py crear "$email" "$rol" ${oficina:+"$oficina"} ;;
            2) usuarios_py clave "$email" ;;
            3) read -r -p "Rol (admin / usuario_estandar / auditor): " rol
               read -r -p "Oficina (Enter = no cambiarla): " oficina
               usuarios_py rol "$email" "$rol" ${oficina:+"$oficina"} ;;
            4) usuarios_py bloquear "$email" ;;
            5) usuarios_py desbloquear "$email" ;;
            *) aviso "Opción inválida." ;;
        esac
    done
}

cmd_estado() {
    verificar_docker; instalado
    dc ps
    if curl -fsS --noproxy '*' "http://127.0.0.1:$(valor PUERTO)/health" > /dev/null 2>&1; then
        ok "Funcionando en $(direccion)"
    else
        aviso "El sistema no responde. Para arrancarlo:  bash ranking.sh abrir"
    fi
    echo "Configuración: $CONFIG    Respaldos: $RESPALDOS"
}

cmd_logs() { verificar_docker; instalado; dc logs --tail "${1:-100}" api db espejo; }

cmd_respaldo() {
    verificar_docker; instalado
    dc up -d db > /dev/null 2>&1
    mkdir -p "$RESPALDOS"
    local f; f="ranking_$(date +%Y%m%d_%H%M%S)"
    titulo "Respaldo $f"
    dc exec -T db pg_dump -U postgres -Fc ranking > "$RESPALDOS/$f.dump" || { rm -f "$RESPALDOS/$f.dump"; fallar "No se pudo respaldar la base."; }
    herramienta tar -C /data/storage -czf - . > "$RESPALDOS/${f}_archivos.tgz" || { rm -f "$RESPALDOS/$f"*; fallar "No se pudieron respaldar los archivos."; }
    ok "Listo: $RESPALDOS/$f.dump y ${f}_archivos.tgz"
    # Copia en el espejo de OneDrive (fuera de Ubuntu: si algún día se reinstala, el respaldo sigue ahí).
    local e destino; e="$(valor ESPEJO_DIR)"
    if [ -n "$e" ]; then
        destino="$e/respaldo_documentacion_sistema/respaldos"
        if mkdir -p "$destino" && cp "$RESPALDOS/$f.dump" "$RESPALDOS/${f}_archivos.tgz" "$destino/"; then
            ok "Copia en OneDrive: $destino"
        else
            aviso "No pude copiarlo a OneDrive ($destino); quedó en $RESPALDOS."
        fi
        publicar_documentacion || aviso "No pude actualizar la documentación en OneDrive."
    else
        echo "(No encontré la carpeta de OneDrive: el respaldo quedó solo en $RESPALDOS.)"
    fi
    echo "Para volver a este respaldo:  bash ranking.sh restaurar $f"
}

# Copia al espejo de OneDrive los archivos cargados que todavía no están (no borra ni pisa nada) y la documentación.
cmd_espejo() {
    verificar_docker; instalado
    local e; e="$(valor ESPEJO_DIR)"
    [ -n "$e" ] || fallar "No encontré la carpeta de OneDrive ($ONEDRIVE_ESPEJO)."
    dc up -d db > /dev/null 2>&1
    titulo "Espejo de auditoría en OneDrive"
    echo "Carpeta: $e"
    herramienta_root python /app/api/espejo.py || aviso "Algunos archivos no se pudieron copiar (el detalle está arriba)."
    publicar_documentacion && ok "Documentación actualizada en respaldo_documentacion_sistema/docs."
}

# Carga única de los charts históricos que están en las carpetas del espejo de OneDrive ("Spotify Charts" y
# "Youtube Charts"). Misma lectura que Carga CSV (migracion/importar_charts.py). Se puede cortar y volver a correr:
# no carga dos veces el mismo archivo. Antes hace un respaldo.
cmd_cargar_historicos() {
    verificar_docker; instalado
    local e; e="$(valor ESPEJO_DIR)"
    [ -n "$e" ] || fallar "No encontré la carpeta de OneDrive ($ONEDRIVE_ESPEJO)."
    local nombres=("$@"); [ ${#nombres[@]} -gt 0 ] || nombres=("Spotify Charts" "Youtube Charts")
    local n c total=0 dentro=()
    titulo "Carga de charts históricos desde OneDrive"
    for c in "${nombres[@]}"; do
        [ -d "$e/$c" ] || { aviso "  No existe la carpeta: $e/$c (se saltea)"; continue; }
        n="$(find "$e/$c" -type f -iname '*.csv' | wc -l)"
        echo "  $c: $n archivos .csv"
        total=$((total + n)); dentro+=("/espejo/$c")
    done
    [ "$total" -gt 0 ] || fallar "No hay archivos para cargar."
    echo "Se cargan con la misma lectura que Carga CSV. Un archivo ya importado no se vuelve a cargar."
    si "¿Cargar los $total archivos? (antes se hace un respaldo)" S || fallar "Cancelado. No se cargó nada."
    cmd_respaldo
    titulo "Cargando (puede tardar varios minutos)"
    mkdir -p "$RESPALDOS"
    local registro; registro="$RESPALDOS/carga-historicos-$(date +%Y%m%d_%H%M%S).log"
    dc up -d db > /dev/null 2>&1
    herramienta python /app/migracion/importar_charts.py "${dentro[@]}" 2>&1 | tee "$registro"
    [ "${PIPESTATUS[0]}" = 0 ] || fallar "La carga se interrumpió (el motivo está arriba). Lo cargado queda; para seguir, volvé a correr el comando."
    ok "Carga terminada. Detalle completo: $registro"
    echo "En la aplicación: Historial de cargas muestra cada semana cargada por país."
}

cmd_restaurar() {
    verificar_docker; instalado
    local f="${1:-}"; f="${f%.dump}"; f="$(basename "$f")"
    [ -n "$f" ] && [ -f "$RESPALDOS/$f.dump" ] && [ -f "$RESPALDOS/${f}_archivos.tgz" ] || {
        echo "Respaldos disponibles en $RESPALDOS:"
        local d; for d in "$RESPALDOS"/*.dump; do [ -e "$d" ] && basename "$d" .dump; done
        fallar "Uso: bash ranking.sh restaurar <nombre del respaldo>"; }
    si "Esto reemplaza TODOS los datos y archivos actuales por los del respaldo $f. ¿Seguir?" || fallar "Cancelado."
    dc stop api > /dev/null 2>&1; dc up -d db > /dev/null 2>&1
    titulo "Restaurando la base"
    consulta "SET session_replication_role = replica;
              TRUNCATE public.app_users, public.tracks_master, public.territory_tracks, public.territory_control,
                       public.territory_bo_report, public.territory_tempo_report, public.csv_uploads, public.audit_logs,
                       public.bo_export_counter, public.staging_tempo_historico, public.resultado_tempo_historico,
                       public.envio_obras, public.envios,
                       auth.users, storage.objects, storage.buckets" > /dev/null || fallar "No se pudo vaciar la base."
    dc exec -T db pg_restore -U postgres -d ranking --data-only --disable-triggers --single-transaction \
        -n public -n auth -n storage < "$RESPALDOS/$f.dump" || fallar "No se pudo restaurar la base (quedó vacía: volvé a intentar)."
    titulo "Restaurando los archivos"
    herramienta sh -c 'find /data/storage -mindepth 1 -delete && tar -C /data/storage -xzf -' < "$RESPALDOS/${f}_archivos.tgz" \
        || fallar "No se pudieron restaurar los archivos."
    dc up -d > /dev/null 2>&1; esperar_sistema
    ok "Restaurado el respaldo $f. Sistema funcionando en $(direccion)"
}

# Deja vacío el historial de archivos (el "bucket" csv-uploads y la pestaña Historial de cargas) para empezar a cargar de
# cero. No toca obras, territorios ni usuarios. Antes hace un respaldo, y nunca corre en modo --automatico.
cmd_vaciar_historial() {
    verificar_docker; instalado
    local n; n="$(dc up -d db > /dev/null 2>&1; consulta "select count(*) from storage.objects where bucket_id = 'csv-uploads'")" \
        || fallar "No se pudo consultar la base."
    titulo "Vaciar el historial de archivos"
    echo "Borra los $n archivos guardados y la lista de archivos del Historial de cargas."
    echo "No cambia la tabla principal, la tabla por territorio, las fechas de última carga ni los usuarios."
    [ "$AUTOMATICO" = 1 ] && fallar "Este comando lo confirma una persona: corrélo sin --automatico."
    si "¿Vaciar el historial? (antes se hace un respaldo para poder volver atrás)" || fallar "Cancelado. No se borró nada."
    cmd_respaldo
    titulo "Vaciando"
    consulta "BEGIN; DELETE FROM storage.objects WHERE bucket_id = 'csv-uploads'; DELETE FROM public.csv_uploads; COMMIT;" > /dev/null \
        || fallar "No se pudo vaciar la base (no se borró nada)."
    herramienta sh -c 'rm -rf /data/storage/csv-uploads && mkdir -p /data/storage/csv-uploads' \
        || fallar "Se vació la lista, pero no se pudieron borrar los archivos (bash ranking.sh logs)."
    ok "Historial vacío. Los próximos CSV que cargues empiezan el historial de cero."
    echo "Para volver atrás: bash ranking.sh restaurar <el respaldo de arriba>"
}

# Empezar de cero: vacía la tabla principal, la tabla por territorio (charts, Reporte Tempo, Reporte BO, estados de
# trabajo), el historial de cambios, el seguimiento de envíos y el historial de archivos. Quedan los usuarios y el
# número de carga del Reporte BO (para no repetir números que BO ya recibió). Respaldo previo; nunca en --automatico.
cmd_empezar_de_cero() {
    verificar_docker; instalado
    dc up -d db > /dev/null 2>&1
    local resumen; resumen="$(consulta "select (select count(*) from public.tracks_master) || ' obras en la tabla principal, '
                                      || (select count(*) from public.territory_tracks) || ' registros por territorio, '
                                      || (select count(*) from storage.objects where bucket_id = 'csv-uploads') || ' archivos en el historial'")" \
        || fallar "No se pudo consultar la base."
    titulo "Empezar de cero"
    echo "Hoy hay: $resumen."
    echo "Se borra todo eso: la tabla principal, la tabla por territorio (charts, Reporte Tempo, Reporte BO y estados"
    echo "de trabajo), el historial de cambios, el seguimiento de reportes y descargas, y el historial de archivos."
    echo "Quedan los usuarios y sus contraseñas, y el número de la próxima carga del Reporte BO."
    [ "$AUTOMATICO" = 1 ] && fallar "Este comando lo confirma una persona: corrélo sin --automatico."
    si "¿Borrar todos los datos y empezar de cero? (antes se hace un respaldo para poder volver atrás)" || fallar "Cancelado. No se borró nada."
    cmd_respaldo
    titulo "Vaciando"
    consulta "BEGIN;
              TRUNCATE public.envio_obras, public.envios, public.territory_tracks, public.territory_control,
                       public.territory_bo_report, public.territory_tempo_report, public.tracks_master, public.audit_logs,
                       public.csv_uploads, public.staging_tempo_historico, public.resultado_tempo_historico;
              DELETE FROM storage.objects WHERE bucket_id = 'csv-uploads';
              COMMIT;" > /dev/null || fallar "No se pudo vaciar la base (no se borró nada)."
    herramienta sh -c 'rm -rf /data/storage/csv-uploads && mkdir -p /data/storage/csv-uploads' \
        || fallar "Se vaciaron las tablas, pero no se pudieron borrar los archivos (bash ranking.sh logs)."
    ok "Listo: el sistema quedó vacío, con los mismos usuarios. Podés empezar a cargar los charts."
    echo "Para volver atrás: bash ranking.sh restaurar <el respaldo de arriba>"
}

cmd_certificados() {
    command -v powershell.exe > /dev/null 2>&1 || fallar "No puedo leer los certificados de Windows desde acá (falta powershell.exe en WSL).
Pedile a IT el certificado raíz de la empresa (.crt) y copialo a $DIR/certificados/"
    titulo "Exportando los certificados raíz de Windows"
    local tmp; tmp="$(mktemp -d)"
    (cd /mnt/c 2>/dev/null || true; powershell.exe -NoProfile -Command '
        $vistos = @{}
        foreach ($almacen in "Cert:\LocalMachine\Root", "Cert:\CurrentUser\Root") {
            foreach ($c in Get-ChildItem $almacen -ErrorAction SilentlyContinue) {
                if ($vistos[$c.Thumbprint]) { continue }; $vistos[$c.Thumbprint] = 1
                "-----BEGIN CERTIFICATE-----"; [Convert]::ToBase64String($c.RawData, "InsertLineBreaks"); "-----END CERTIFICATE-----"
            }
        }' 2>/dev/null) | tr -d '\r' > "$tmp/todos.pem"
    rm -f "$DIR"/certificados/windows-*.crt
    awk -v d="$DIR/certificados" '/BEGIN CERT/ { n++; f = sprintf("%s/windows-%03d.crt", d, n) } f { print > f } /END CERT/ { close(f); f = "" }' "$tmp/todos.pem"
    rm -rf "$tmp"
    local n; n="$(ls "$DIR"/certificados/windows-*.crt 2>/dev/null | wc -l)"
    [ "$n" -gt 0 ] || fallar "No se pudo leer ningún certificado de Windows."
    ok "$n certificados guardados en $DIR/certificados (se agregan a la imagen al armarla)."
    titulo "Agregándolos a Ubuntu (para que Docker pueda bajar imágenes; pide tu contraseña de Ubuntu)"
    sudo mkdir -p /usr/local/share/ca-certificates/ranking-empresa \
        && sudo cp "$DIR"/certificados/windows-*.crt /usr/local/share/ca-certificates/ranking-empresa/ \
        && sudo update-ca-certificates > /dev/null \
        && sudo service docker restart > /dev/null \
        || fallar "No se pudieron agregar a Ubuntu."
    ok "Listo. Ahora volvé a correr el paso que falló (por ejemplo: bash ranking.sh instalar)."
}

cmd_acceso_directo() {
    command -v powershell.exe > /dev/null 2>&1 && [ -n "${WSL_DISTRO_NAME:-}" ] \
        || fallar "Los accesos de Windows son para WSL (Ubuntu dentro de Windows). Acá no encuentro Windows."
    instalado
    case "$DIR" in /mnt/*) fallar "Primero copiá el proyecto dentro de Ubuntu (~/proyectos) y corré este comando desde ahí.";; esac
    titulo "Creando la aplicación 'Ranking Digital' en Windows"
    local win_local carpeta_win carpeta lanzar_win ico_win
    win_local="$(cd /mnt/c 2>/dev/null || true; powershell.exe -NoProfile -Command '$env:LOCALAPPDATA' 2>/dev/null | tr -d '\r')"
    [ -n "$win_local" ] || fallar "No pude leer la carpeta de Windows del usuario."
    carpeta_win="$win_local\RankingDigital"
    carpeta="$(wslpath -u "$carpeta_win")"
    mkdir -p "$carpeta" || fallar "No pude crear $carpeta_win"
    cp "$DIR/windows/ranking.ico" "$carpeta/ranking.ico"
    # Lanzador (PowerShell 5.1: con BOM y fin de línea de Windows) y pantalla de "iniciando", con los datos de esta PC.
    shopt -u patsub_replacement 2> /dev/null || true
    local t d="${WSL_DISTRO_NAME//\'/\'\'}" pr="${DIR//\'/\'\'}"
    t="$(cat "$DIR/escritorio/lanzar.ps1")"; t="${t//__DISTRO__/$d}"; t="${t//__PROYECTO__/$pr}"; t="${t//__PUERTO__/$(valor PUERTO)}"
    { printf '\xef\xbb\xbf'; printf '%s\n' "$t" | sed 's/$/\r/'; } > "$carpeta/lanzar.ps1"
    t="$(cat "$DIR/escritorio/iniciando.html")"; printf '%s\n' "${t//__PUERTO__/$(valor PUERTO)}" > "$carpeta/iniciando.html"
    rm -f "$carpeta/Ranking Digital.cmd"   # lanzador anterior (con ventana negra)
    lanzar_win="$carpeta_win\lanzar.ps1"; ico_win="$carpeta_win\ranking.ico"
    local por_defecto inicio=0; por_defecto="$(valor INICIO_AUTOMATICO)"
    si "¿Que el servidor arranque solo (oculto) cada vez que entrás a Windows?" "${por_defecto:-S}" && inicio=1
    q() { local x="${1//\'/\'\'}"; printf "'%s'" "$x"; }
    local ps
    ps="
        \$s = New-Object -ComObject WScript.Shell
        function Acceso(\$carpeta, \$nombre, \$extra, \$descripcion) {
            New-Item -ItemType Directory -Force \$carpeta | Out-Null
            \$a = \$s.CreateShortcut((Join-Path \$carpeta (\$nombre + '.lnk')))
            \$a.TargetPath = 'powershell.exe'
            \$a.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"' + $(q "$lanzar_win") + '\"' + \$extra
            \$a.IconLocation = $(q "$ico_win") + ',0'
            \$a.WorkingDirectory = $(q "$carpeta_win")
            \$a.WindowStyle = 7
            \$a.Description = \$descripcion
            \$a.Save()
            Write-Output (Join-Path \$carpeta (\$nombre + '.lnk'))
        }
        \$escritorio = [Environment]::GetFolderPath('Desktop')
        \$menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Ranking Digital'
        \$inicio = [Environment]::GetFolderPath('Startup')
        Acceso \$escritorio 'Ranking Digital' '' 'Abrir Ranking Digital'
        Acceso \$menu 'Ranking Digital' '' 'Abrir Ranking Digital'
        Acceso \$menu 'Apagar Ranking Digital' ' -Apagar' 'Apagar Ranking Digital (los datos quedan guardados)'
        Remove-Item (Join-Path \$inicio 'Ranking Digital.lnk') -ErrorAction SilentlyContinue
        if ($inicio -eq 1) { Acceso \$inicio 'Ranking Digital' ' -SoloServidor' 'Encender el servidor de Ranking Digital' }"
    local donde; donde="$(cd /mnt/c 2>/dev/null || true; powershell.exe -NoProfile -Command "$ps" 2>&1 | tr -d '\r')" \
        || fallar "No pude crear los accesos: $donde"
    poner ACCESO_DIRECTO 1; poner INICIO_AUTOMATICO "$([ "$inicio" = 1 ] && echo S || echo N)"
    ok "Listo. Accesos creados:"; printf '  %s\n' "$donde"
    echo "Doble clic en 'Ranking Digital' (escritorio o menú Inicio, o buscándolo en Windows): abre la aplicación en su"
    echo "propia ventana y, si hace falta, enciende el servidor sin ventanas negras."
    echo "Para instalarla también como aplicación de Edge (barra de tareas): en esa ventana, menú ··· > Aplicaciones >"
    echo "Instalar Ranking Digital. 'Apagar Ranking Digital' (menú Inicio) apaga todo."
}

version_programa() {
    if git -C "$DIR" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        git -C "$DIR" log -1 --format='%h %cd  %s' --date=format:'%Y-%m-%d %H:%M'
    else echo "(copia sin git)"; fi
}

# Revisa que todo esté sano, sin cambiar nada. Sale con código 0 si está todo bien (lo usan los agentes).
cmd_verificar() {
    local fallo=0 n
    linea() { if [ "$1" = ok ]; then ok "  OK     $2"; else printf '%s  FALLA  %s%s\n' "$R" "$2" "$N"; fallo=1; fi; }
    titulo "Verificación de Ranking Digital"
    if docker info > /dev/null 2>&1; then linea ok "Docker funcionando"; else linea mal "Docker no está corriendo (sudo service docker start)"; fi
    if [ -f "$CONFIG" ]; then linea ok "Configuración en $CONFIG"; else linea mal "Sin configuración: falta bash ranking.sh instalar"; fi
    if [ "$fallo" = 0 ]; then
        for n in db api espejo; do
            if [ -n "$(dc ps --status running -q "$n" 2> /dev/null)" ]; then linea ok "Contenedor $n corriendo"; else linea mal "Contenedor $n apagado (bash ranking.sh abrir)"; fi
        done
        if curl -fsS --noproxy '*' "http://127.0.0.1:$(valor PUERTO)/health" > /dev/null 2>&1; then
            linea ok "Sistema respondiendo en $(direccion)"
        else linea mal "El sistema no responde en $(direccion) (bash ranking.sh logs)"; fi
        local datos; datos="$(consulta "select (select count(*) from auth.users) || ' usuarios, ' || (select count(*) from public.tracks_master)
                                         || ' obras, ' || (select count(*) from public.territory_tracks) || ' registros por territorio, '
                                         || (select count(*) from storage.objects) || ' archivos en el historial'" 2> /dev/null)"
        if [ -n "$datos" ]; then linea ok "Base: $datos"; else linea mal "No se pudo consultar la base"; fi
        if [ -z "$(valor ESPEJO_DIR)" ]; then aviso "  AVISO  Sin espejo en OneDrive (no se encontró la carpeta $ONEDRIVE_ESPEJO)"
        elif dc exec -T espejo sh -c 'test -n "$ESPEJO" && touch /espejo/.prueba-escritura && rm -f /espejo/.prueba-escritura' > /dev/null 2>&1; then
            linea ok "Espejo de auditoría en OneDrive: $(valor ESPEJO_DIR)"
        else aviso "  AVISO  No se puede escribir en el espejo de OneDrive ($(valor ESPEJO_DIR)); ver README, sección Espejo"; fi
    fi
    echo "  Versión del programa: $(version_programa)"
    [ "$fallo" = 0 ] && ok "Todo en orden." || { printf '%sHay problemas: revisá las líneas FALLA.%s\n' "$R" "$N"; return 1; }
}

# Trae la última versión del programa desde GitHub y la aplica sin perder datos (antes hace un respaldo).
cmd_actualizar() {
    verificar_docker; instalado
    git -C "$DIR" rev-parse --is-inside-work-tree > /dev/null 2>&1 \
        || fallar "Esta carpeta no es una copia de git; no se puede actualizar sola. Ver ANTIGRAVITY.md (paso de git clone)."
    local cambios; cambios="$(git -C "$DIR" status --porcelain --untracked-files=no)"
    [ -z "$cambios" ] || fallar "Hay cambios hechos a mano en esta copia; no actualizo para no pisarlos:
$cambios
(Si no los necesitás: git -C \"$DIR\" checkout -- .   y volvé a correr bash ranking.sh actualizar)"
    titulo "1/4 Respaldo antes de actualizar"
    cmd_respaldo
    titulo "2/4 Bajando la versión nueva"
    local antes; antes="$(git -C "$DIR" rev-parse HEAD)"
    correr_con_registro git -C "$DIR" pull --ff-only || fallar "No se pudo bajar la versión nueva (el motivo está arriba). No se cambió nada."
    if [ "$(git -C "$DIR" rev-parse HEAD)" = "$antes" ]; then
        ok "Ya estaba en la última versión: $(version_programa)"
    else
        echo "Cambios nuevos:"; git -C "$DIR" log --format='  %h %s' "$antes..HEAD"
    fi
    arreglar_fin_de_linea
    titulo "3/4 Armando y arrancando la versión nueva"
    if ! { correr_con_registro dc build api && dc up -d && esperar_sistema --sin-salir; }; then
        aviso "La versión nueva no arrancó. Vuelvo a la anterior ($(git -C "$DIR" log -1 --format=%h "$antes"))..."
        git -C "$DIR" reset -q --hard "$antes"
        dc build api > /dev/null 2>&1; dc up -d > /dev/null 2>&1; esperar_sistema
        fallar "Quedó funcionando la versión anterior. Pasale a Claude el mensaje de arriba (o el de bash ranking.sh logs)."
    fi
    if [ "$(valor ACCESO_DIRECTO)" = 1 ] && command -v powershell.exe > /dev/null 2>&1 && [ -n "${WSL_DISTRO_NAME:-}" ]; then
        local antes_auto="$AUTOMATICO"; AUTOMATICO=1; cmd_acceso_directo > /dev/null 2>&1 \
            && ok "Accesos de Windows actualizados." || aviso "No pude actualizar los accesos de Windows (bash ranking.sh acceso-directo)."
        AUTOMATICO="$antes_auto"
    fi
    if [ -n "$(valor ESPEJO_DIR)" ]; then
        titulo "Espejo de auditoría en OneDrive"
        herramienta_root python /app/api/espejo.py || aviso "Algunos archivos no se pudieron copiar a OneDrive (bash ranking.sh espejo)."
        publicar_documentacion || true
    fi
    titulo "4/4 Verificación"
    cmd_verificar
}

ayuda() { sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# --automatico en cualquier posición: sin preguntas (respuestas por defecto).
ARGS=()
for a in "$@"; do if [ "$a" = "--automatico" ]; then AUTOMATICO=1; else ARGS+=("$a"); fi; done
set -- "${ARGS[@]+"${ARGS[@]}"}"

if [ -f "$CONFIG" ]; then
    guardar_proxy
    configurar_espejo
    # La carga automática de YouTube ya no existe (los charts se cargan a mano): se borra su horario viejo.
    grep -q '^YOUTUBE_CRON' "$CONFIG" && sed -i '/^YOUTUBE_CRON/d' "$CONFIG"
fi

case "${1:-}" in
    instalar) cmd_instalar ;;
    migrar) cmd_migrar ;;
    abrir|iniciar) shift; cmd_abrir "$@" ;;
    detener|apagar) cmd_detener ;;
    usuarios) cmd_usuarios ;;
    estado) cmd_estado ;;
    logs) shift; cmd_logs "$@" ;;
    respaldo) cmd_respaldo ;;
    restaurar) shift; cmd_restaurar "$@" ;;
    certificados) cmd_certificados ;;
    espejo) cmd_espejo ;;
    cargar-historicos) shift; cmd_cargar_historicos "$@" ;;
    vaciar-historial) cmd_vaciar_historial ;;
    empezar-de-cero) cmd_empezar_de_cero ;;
    acceso-directo|icono) cmd_acceso_directo ;;
    verificar) verificar_docker; cmd_verificar ;;
    actualizar) cmd_actualizar ;;
    *) ayuda ;;
esac
