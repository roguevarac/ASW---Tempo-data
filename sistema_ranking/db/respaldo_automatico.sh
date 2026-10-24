#!/bin/sh
# Respaldos (servicio "respaldo" de docker-compose.yml).
#  - Automático: cada RESPALDO_HORAS (24 por defecto) deja en la carpeta de respaldos un respaldo completo con el
#    mismo formato que "bash ranking.sh respaldo":
#        ranking_auto_AAAAMMDD_HHMMSS.dump            la base (pg_dump -Fc)
#        ranking_auto_AAAAMMDD_HHMMSS_archivos.tgz    los archivos cargados
#    En la carpeta local se conservan los últimos RESPALDO_CONSERVAR (14) automáticos; los demás no se tocan. Si hay
#    espejo de OneDrive, copia ahí el .dump (respaldo_documentacion_sistema/respaldos/automaticos).
#  - A pedido ("Respaldar ahora" del Panel de control, tabla panel.solicitudes): respaldo completo con nombre de
#    respaldo manual (ranking_AAAAMMDD_HHMMSS, no se borra solo) y copia del .dump y el .tgz en OneDrive
#    (respaldo_documentacion_sistema/respaldos), como "ranking.sh respaldo".
# Se restauran igual: bash ranking.sh restaurar <nombre>. En OneDrive nunca se borra nada. Un error nunca detiene el
# sistema: queda en el registro del Panel de control y se reintenta.
# Variables: PGURL, RESPALDO_ACTIVO (lo pone compose si hay RESPALDOS_DIR), RESPALDO_HORAS (0 = sin automático),
# RESPALDO_CONSERVAR, RESPALDO_DEMORA (segundos después de arrancar, 600), ESPEJO (vacío = sin copia a OneDrive).
set -u
DIR=/respaldos
HORAS="${RESPALDO_HORAS:-24}"
CONSERVAR="${RESPALDO_CONSERVAR:-14}"
DEMORA="${RESPALDO_DEMORA:-600}"   # segundos: el respaldo automático no compite con el arranque ni con el primer ingreso
case "$DEMORA" in ''|*[!0-9]*) DEMORA=600;; esac
case "$HORAS" in ''|*[!0-9]*) HORAS=0;; esac

sqlp() { psql "$PGURL" -X -q -At -v ON_ERROR_STOP=1 "$@" 2>/dev/null; }
# Texto como literal de SQL (las comillas simples se duplican).
lit() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }
evento() { sqlp -c "SELECT panel.registrar('respaldo', $(lit "$1"), $(lit "$2"))" > /dev/null || true; }

if [ -z "${RESPALDO_ACTIVO:-}" ] || [ ! -d "$DIR" ]; then
    echo "Respaldos apagados: no hay carpeta de respaldos."
    while true; do
        sqlp -c "SELECT panel.latido('respaldo', '{\"apagado\": true}');
                 UPDATE panel.solicitudes SET estado = 'error', terminado = now(),
                        mensaje = 'Esta instalación no tiene carpeta de respaldos.' WHERE estado = 'pendiente'" > /dev/null
        sleep 60
    done
fi
[ "$HORAS" = 0 ] && echo "Respaldo automático apagado (RESPALDO_HORAS=0); los pedidos del Panel de control se atienden igual."

dueno="$(stat -c %u:%g "$DIR")"   # los respaldos quedan a nombre del dueño de la carpeta, no de root

tamano() { du -sh "$1" 2>/dev/null | cut -f1; }

# respaldar <nombre> <carpeta de OneDrive (relativa)> <copiar también el .tgz: si/no>
respaldar() {
    f="$1"
    if ! pg_dump "$PGURL" -Fc -f "$DIR/$f.dump.parcial"; then
        rm -f "$DIR/$f.dump.parcial"; evento error "Falló el respaldo de la base ($f)"; return 1
    fi
    if ! tar -C /data/storage -czf "$DIR/${f}_archivos.tgz.parcial" .; then
        rm -f "$DIR/$f.dump.parcial" "$DIR/${f}_archivos.tgz.parcial"
        evento error "No se pudieron empaquetar los archivos ($f)"; return 1
    fi
    mv "$DIR/${f}_archivos.tgz.parcial" "$DIR/${f}_archivos.tgz"
    mv "$DIR/$f.dump.parcial" "$DIR/$f.dump"          # el .dump va último: marca el respaldo como completo
    chown "$dueno" "$DIR/$f.dump" "$DIR/${f}_archivos.tgz" 2>/dev/null
    chmod 640 "$DIR/$f.dump" "$DIR/${f}_archivos.tgz"
    echo "Respaldo: $f"
    evento ok "Respaldo $f: base $(tamano "$DIR/$f.dump"), archivos $(tamano "$DIR/${f}_archivos.tgz")"
    copia="sin copia en OneDrive"
    if [ -n "${ESPEJO:-}" ] && [ -d "$ESPEJO" ]; then
        d="$ESPEJO/respaldo_documentacion_sistema/$2"
        archivos="$f.dump"; [ "$3" = si ] && archivos="$f.dump ${f}_archivos.tgz"
        ok=1
        mkdir -p "$d" || ok=0
        for a in $archivos; do
            [ "$ok" = 1 ] && cp "$DIR/$a" "$d/$a.copiando" && mv "$d/$a.copiando" "$d/$a" || { ok=0; rm -f "$d/$a.copiando"; }
        done
        if [ "$ok" = 1 ]; then
            copia="copia en OneDrive"; evento ok "Copia en OneDrive: $archivos ($2)"
        else
            copia="no se pudo copiar a OneDrive"; evento error "No se pudo copiar $f a OneDrive ($2); quedó en la carpeta local"
        fi
    fi
    RESULTADO="$f ($copia)"
    return 0
}

podar() {   # conserva los últimos $CONSERVAR automáticos (solo en la carpeta local)
    ls -1 "$DIR"/ranking_auto_*.dump 2>/dev/null | sort -r | tail -n +"$((CONSERVAR + 1))" | while read -r viejo; do
        rm -f "$viejo" "${viejo%.dump}_archivos.tgz"
    done
}

latido() {
    ultimo="$(ls -1 "$DIR"/ranking_auto_*.dump 2>/dev/null | sort | tail -n 1)"
    n_auto="$(ls -1 "$DIR"/ranking_auto_*.dump 2>/dev/null | wc -l)"
    n_todos="$(ls -1 "$DIR"/*.dump 2>/dev/null | wc -l)"
    libre="$(df -Pk "$DIR" 2>/dev/null | awk 'NR==2 {print $4 * 1024}')"
    usado="$(du -sk "$DIR" 2>/dev/null | awk '{print $1 * 1024}')"
    sqlp -c "SELECT panel.latido('respaldo', jsonb_build_object(
                 'cada_horas', $HORAS, 'conservar', $CONSERVAR, 'ultimo_automatico', $(lit "$(basename "${ultimo:-}" .dump)"),
                 'automaticos', ${n_auto:-0}, 'respaldos', ${n_todos:-0}, 'carpeta_bytes', ${usado:-0},
                 'disco_libre', ${libre:-0}, 'onedrive', $( [ -n "${ESPEJO:-}" ] && [ -d "${ESPEJO:-/nada}" ] && echo true || echo false)))" \
        > /dev/null || true
}

ultimo_latido=0
# Próximo intento de respaldo automático: unos minutos después de arrancar, y una hora después de uno fallido.
reintento=$(( $(date +%s) + DEMORA ))
while true; do
    ahora="$(date +%s)"
    [ $((ahora - ultimo_latido)) -ge 30 ] && { latido; ultimo_latido="$ahora"; }
    # Pedido del Panel de control ("Respaldar ahora").
    pedido="$(sqlp -c "UPDATE panel.solicitudes SET estado = 'en curso'
                       WHERE id = (SELECT min(id) FROM panel.solicitudes WHERE tipo = 'respaldo' AND estado = 'pendiente')
                       RETURNING id")"
    if [ -n "$pedido" ]; then
        RESULTADO=""
        if respaldar "ranking_$(date +%Y%m%d_%H%M%S)" respaldos si; then
            sqlp -c "UPDATE panel.solicitudes SET estado = 'listo', terminado = now(), mensaje = $(lit "$RESULTADO") WHERE id = $pedido" > /dev/null
        else
            sqlp -c "UPDATE panel.solicitudes SET estado = 'error', terminado = now(),
                     mensaje = 'No se pudo hacer el respaldo: ver el registro de eventos' WHERE id = $pedido" > /dev/null
        fi
        latido
    fi
    # Respaldo automático.
    if [ "$HORAS" != 0 ]; then
        ultimo="$(ls -1 "$DIR"/ranking_auto_*.dump 2>/dev/null | sort | tail -n 1)"
        if { [ -z "$ultimo" ] || [ -n "$(find "$ultimo" -mmin +"$((HORAS * 60 - 5))" 2>/dev/null)" ]; } \
           && [ "$(date +%s)" -ge "$reintento" ]; then
            if respaldar "ranking_auto_$(date +%Y%m%d_%H%M%S)" respaldos/automaticos no; then podar
            else reintento=$(( $(date +%s) + 3600 )); fi
            latido
        fi
    fi
    sleep 10
done
