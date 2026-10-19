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
#   bash ranking.sh certificados    toma los certificados de la empresa desde Windows (proxy que inspecciona HTTPS)
#
# Las claves internas quedan en ~/.config/ranking-digital/ranking.env (fuera del proyecto: una versión nueva del
# proyecto, en otra carpeta, sigue usando la misma base). No compartas ese archivo.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${RK_CONFIG:-$HOME/.config/ranking-digital/ranking.env}"
RESPALDOS="${RK_RESPALDOS:-$HOME/proyectos/ranking-respaldos}"
PROYECTO_SUPABASE="https://ltosqbvzlnncxijzodvd.supabase.co"
ONEDRIVE_BACKOFFICE="OneDrive - Sony/SMP-Administration Argentina - Documents/Latam/Backoffice"

if [ -t 1 ]; then R=$'\e[31m'; V=$'\e[32m'; A=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'; else R='' V='' A='' C='' N=''; fi
titulo() { printf '\n%s== %s%s\n' "$C" "$*" "$N"; }
ok()     { printf '%s%s%s\n' "$V" "$*" "$N"; }
aviso()  { printf '%s%s%s\n' "$A" "$*" "$N"; }
fallar() { printf '\n%s%s%s\n' "$R" "$*" "$N" >&2; unset SUPABASE_SERVICE_KEY; exit 1; }
si()     { local r; read -r -p "$1 (S/N): " r; [[ "$r" =~ ^[[:space:]]*[sS] ]]; }

# La configuración manda: variables con el mismo nombre en la terminal (que docker compose priorizaría) no se usan.
CLAVES_CONFIG=(POSTGRES_PASSWORD AUTHENTICATOR_PASSWORD JWT_SECRET PUERTO ESCUCHAR SESSION_HOURS MAX_UPLOAD_MB
               STATEMENT_TIMEOUT DB_POOL YOUTUBE_CRON YOUTUBE_CRON_TZ IMAGEN_POSTGRES IMAGEN_PYTHON)
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
    case "$DIR" in /mnt/*) aviso "Aviso: el proyecto está en $DIR (disco de Windows). Anda más rápido y seguro dentro de Ubuntu (~/proyectos).";; esac
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
consulta() { dc exec -T db psql -U postgres -d ranking -At -c "$1"; }
usuarios_py() { dc run --rm herramientas python /app/admin/usuarios.py "$@"; }
herramienta() { dc run --rm --no-deps -T herramientas "$@"; }

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
YOUTUBE_CRON=
YOUTUBE_CRON_TZ=UTC
EOF
        umask 022
        ok "Configuración creada con claves al azar en $CONFIG"
    fi

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
        if si "  * ¿Crear ahora un usuario administrador nuevo?"; then
            local email oficina; read -r -p "Email: " email; read -r -p "Oficina (ej. AR; Enter para dejarla vacía): " oficina
            echo "Escribí la contraseña (mínimo 10 caracteres; no se ve mientras escribís)."
            usuarios_py crear "$email" admin ${oficina:+"$oficina"} || aviso "No se pudo crear. Reintentá con: bash ranking.sh usuarios"
        fi
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
    local carpetas=() c perfil=""
    if command -v powershell.exe > /dev/null 2>&1; then
        perfil="$(cd /mnt/c 2>/dev/null || true; powershell.exe -NoProfile -Command '[Environment]::GetFolderPath("UserProfile")' 2>/dev/null | tr -d '\r')"
        [ -n "$perfil" ] && perfil="$(wslpath -u "$perfil" 2>/dev/null)"
    fi
    if [ -z "$perfil" ] || [ ! -d "$perfil/$ONEDRIVE_BACKOFFICE" ]; then
        for c in /mnt/c/Users/*; do [ -d "$c/$ONEDRIVE_BACKOFFICE" ] && { perfil="$c"; break; }; done
    fi
    if [ -n "$perfil" ]; then
        for c in "$perfil/$ONEDRIVE_BACKOFFICE/Charts historicos Youtube" "$perfil/$ONEDRIVE_BACKOFFICE/Charts historicos_spotify"; do
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

    titulo "6/6 Contraseñas y carga automática de YouTube"
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
    echo
    echo "Horario de la carga automática de YouTube Charts. Para verlo: Supabase > SQL Editor > corré"
    echo "    select schedule from cron.job;"
    echo "y pegá lo que aparece (por ejemplo: 0 12 * * 5). Enter = dejarla apagada por ahora."
    local cron; read -r -p "Horario: " cron
    if [ -n "$cron" ]; then
        if [ "$(wc -w <<< "$cron")" -ne 5 ]; then
            aviso "No parece un horario válido (son 5 partes). Queda apagada; podés volver a correr este paso."
        else
            poner YOUTUBE_CRON "'$cron'"; poner YOUTUBE_CRON_TZ UTC   # pg_cron de Supabase usa hora UTC
            dc up -d > /dev/null 2>&1; esperar_sistema
            ok "Carga automática de YouTube programada: $cron (hora UTC, como en Supabase). Corre mientras Ubuntu y Docker estén prendidos."
        fi
    fi
    ok $'\n'"Migración completa. Entrá con tu email y la contraseña nueva: $(direccion)"
    echo "Revisá la tabla principal, territorios e historial. Cuando todo esté bien, podés apagar Supabase"
    echo "y cambiar la contraseña de la base y las claves del proyecto de Supabase."
    abrir_navegador "$(direccion)"
}

cmd_abrir() {
    verificar_docker; instalado
    echo "Arrancando Ranking Digital..."
    dc up -d > /dev/null 2>&1 || { dc up -d; fallar "No arrancó (el motivo está arriba)."; }
    esperar_sistema
    ok "Ranking Digital funcionando: $(direccion)"
    abrir_navegador "$(direccion)"
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

cmd_logs() { verificar_docker; instalado; dc logs --tail "${1:-100}" api db; }

cmd_respaldo() {
    verificar_docker; instalado
    dc up -d db > /dev/null 2>&1
    mkdir -p "$RESPALDOS"
    local f; f="ranking_$(date +%Y%m%d_%H%M%S)"
    titulo "Respaldo $f"
    dc exec -T db pg_dump -U postgres -Fc ranking > "$RESPALDOS/$f.dump" || { rm -f "$RESPALDOS/$f.dump"; fallar "No se pudo respaldar la base."; }
    herramienta tar -C /data/storage -czf - . > "$RESPALDOS/${f}_archivos.tgz" || { rm -f "$RESPALDOS/$f"*; fallar "No se pudieron respaldar los archivos."; }
    ok "Listo: $RESPALDOS/$f.dump y ${f}_archivos.tgz"
    echo "Para guardarlo también en Windows (por ejemplo OneDrive), copiá esos dos archivos a /mnt/c/Users/<tu usuario>/..."
    echo "Para volver a este respaldo:  bash ranking.sh restaurar $f"
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
                       auth.users, storage.objects, storage.buckets" > /dev/null || fallar "No se pudo vaciar la base."
    dc exec -T db pg_restore -U postgres -d ranking --data-only --disable-triggers --single-transaction \
        -n public -n auth -n storage < "$RESPALDOS/$f.dump" || fallar "No se pudo restaurar la base (quedó vacía: volvé a intentar)."
    titulo "Restaurando los archivos"
    herramienta sh -c 'find /data/storage -mindepth 1 -delete && tar -C /data/storage -xzf -' < "$RESPALDOS/${f}_archivos.tgz" \
        || fallar "No se pudieron restaurar los archivos."
    dc up -d > /dev/null 2>&1; esperar_sistema
    ok "Restaurado el respaldo $f. Sistema funcionando en $(direccion)"
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

ayuda() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
    instalar) cmd_instalar ;;
    migrar) cmd_migrar ;;
    abrir|iniciar) cmd_abrir ;;
    detener|apagar) cmd_detener ;;
    usuarios) cmd_usuarios ;;
    estado) cmd_estado ;;
    logs) shift; cmd_logs "$@" ;;
    respaldo) cmd_respaldo ;;
    restaurar) shift; cmd_restaurar "$@" ;;
    certificados) cmd_certificados ;;
    *) ayuda ;;
esac
