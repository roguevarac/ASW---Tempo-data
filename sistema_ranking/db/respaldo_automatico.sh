#!/bin/sh
# Respaldo automático (servicio "respaldo" de docker-compose.yml). Cada RESPALDO_HORAS (24 por defecto) deja en la
# carpeta de respaldos un respaldo completo con el mismo formato que "bash ranking.sh respaldo":
#     ranking_auto_AAAAMMDD_HHMMSS.dump            la base (pg_dump -Fc)
#     ranking_auto_AAAAMMDD_HHMMSS_archivos.tgz    los archivos cargados
# Se restaura igual: bash ranking.sh restaurar ranking_auto_AAAAMMDD_HHMMSS
# En la carpeta local se conservan los últimos RESPALDO_CONSERVAR (14) automáticos; los manuales no se tocan.
# Si hay espejo de OneDrive, copia ahí el .dump (respaldo_documentacion_sistema/respaldos/automaticos); en OneDrive
# nunca se borra nada. Un error nunca detiene el sistema: queda en el log y se reintenta en una hora.
# Variables: PGURL, RESPALDO_ACTIVO (lo pone compose si hay RESPALDOS_DIR), RESPALDO_HORAS, RESPALDO_CONSERVAR,
# ESPEJO (vacío = sin copia a OneDrive).
set -u
DIR=/respaldos
HORAS="${RESPALDO_HORAS:-24}"
CONSERVAR="${RESPALDO_CONSERVAR:-14}"
case "$HORAS" in ''|0|*[!0-9]*) echo "Respaldo automático apagado (RESPALDO_HORAS=$HORAS)."; exec sleep infinity;; esac
[ -n "${RESPALDO_ACTIVO:-}" ] && [ -d "$DIR" ] || { echo "Respaldo automático apagado: no hay carpeta de respaldos."; exec sleep infinity; }

dueno="$(stat -c %u:%g "$DIR")"   # los respaldos quedan a nombre del dueño de la carpeta, no de root

respaldar() {
    f="ranking_auto_$(date +%Y%m%d_%H%M%S)"
    if ! pg_dump "$PGURL" -Fc -f "$DIR/$f.dump.parcial"; then
        rm -f "$DIR/$f.dump.parcial"; echo "Respaldo automático: falló pg_dump; reintento en una hora."; return 1
    fi
    if ! tar -C /data/storage -czf "$DIR/${f}_archivos.tgz.parcial" .; then
        rm -f "$DIR/$f".*parcial "$DIR/${f}"_archivos.tgz.parcial; echo "Respaldo automático: no se pudieron empaquetar los archivos."; return 1
    fi
    mv "$DIR/${f}_archivos.tgz.parcial" "$DIR/${f}_archivos.tgz"
    mv "$DIR/$f.dump.parcial" "$DIR/$f.dump"          # el .dump va último: marca el respaldo como completo
    chown "$dueno" "$DIR/$f.dump" "$DIR/${f}_archivos.tgz" 2>/dev/null
    chmod 640 "$DIR/$f.dump" "$DIR/${f}_archivos.tgz"
    echo "Respaldo automático: $f"
    # Conserva los últimos $CONSERVAR automáticos (solo en la carpeta local).
    ls -1 "$DIR"/ranking_auto_*.dump 2>/dev/null | sort -r | tail -n +"$((CONSERVAR + 1))" | while read -r viejo; do
        rm -f "$viejo" "${viejo%.dump}_archivos.tgz"
    done
    if [ -n "${ESPEJO:-}" ] && [ -d "$ESPEJO" ]; then
        d="$ESPEJO/respaldo_documentacion_sistema/respaldos/automaticos"
        if mkdir -p "$d" && cp "$DIR/$f.dump" "$d/$f.dump.copiando" && mv "$d/$f.dump.copiando" "$d/$f.dump"; then
            echo "Respaldo automático: copia en OneDrive ($f.dump)"
        else
            rm -f "$d/$f.dump.copiando"; echo "Respaldo automático: no se pudo copiar a OneDrive; quedó en la carpeta local."
        fi
    fi
}

while true; do
    ultimo="$(ls -1 "$DIR"/ranking_auto_*.dump 2>/dev/null | sort | tail -n 1)"
    if [ -z "$ultimo" ] || [ -n "$(find "$ultimo" -mmin +"$((HORAS * 60 - 5))" 2>/dev/null)" ]; then
        respaldar
    fi
    sleep 3600
done
