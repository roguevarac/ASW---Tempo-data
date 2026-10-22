"""
Espejo de auditoría en OneDrive (solo escritura, nunca afecta al sistema).

La fuente de verdad es la base de datos y el almacenamiento propio del sistema (Docker). Cada vez que se registra
una carga con datos cargados, el servicio "espejo" (docker-compose.yml) copia el archivo original a la carpeta
compartida de OneDrive, organizado así:

    Spotify Charts/<país>/            charts de Spotify
    Youtube Charts/<país>/            charts de YouTube
    Reportes BackOffice/<país>/       reportes de BO
    Reportes Tempo Control/           reportes de Tempo
    Reportes Tempo Control/Tempo IDs/ cargas de Tempo IDs

Reglas: el sistema solo escribe en el espejo; nunca lee de él ni borra nada. Si la carpeta no está, se borró un
archivo o falla la copia, la carga sigue igual (el error queda en el log). Se activa con la variable ESPEJO (ruta
dentro del contenedor); sin ella no hace nada.

Corre como root en un servicio aparte: en WSL, /mnt/c (OneDrive) solo deja escribir al dueño de la carpeta o a root,
y la API no tiene privilegios. El servicio solo lee la base y los archivos del sistema (montados en solo lectura).

    python espejo.py --servicio   el servicio: copia todo lo que falte y después cada carga nueva, cada pocos segundos

    PGURL=... STORAGE_DIR=... ESPEJO=/espejo python espejo.py           (copia lo que falte)
    ESPEJO=/espejo python espejo.py --leeme                             (solo el LEEME de la carpeta)
"""
import logging
import os
import pathlib
import re
import shutil
import sys

log = logging.getLogger("espejo")

CARPETAS = {
    "spotify": ("Spotify Charts", True),
    "youtube": ("Youtube Charts", True),
    "bo_report": ("Reportes BackOffice", True),
    "tempo_report": ("Reportes Tempo Control", False),
    "master_tempo": ("Reportes Tempo Control/Tempo IDs", False),
}
PAISES = {"AR", "CL", "PE", "UY", "PY", "CO", "EC", "MX"}
LEEME = """AUDITOR DE RANKINGS DIGITALES - Respaldo y auditoría
====================================================

Esta carpeta es una copia de respaldo y auditoría del sistema Auditor de Rankings Digitales. No es el sistema.

- Fuente de verdad: la base de datos del sistema (PostgreSQL en Docker). Todo lo que muestra la aplicación sale de ahí.
- Espejo: cada vez que se carga un chart o un reporte, el sistema copia acá el archivo original. Los respaldos
  completos de la base (.dump) y de los archivos (.tgz) se guardan en respaldo_documentacion_sistema/respaldos.
- Sin efecto sobre el sistema: el sistema solo escribe en esta carpeta; nunca lee de ella ni borra nada. Si se borra
  o modifica un archivo acá, la base de datos y la aplicación no cambian.

Estructura:
  Spotify Charts/<país>/                    charts de Spotify cargados
  Youtube Charts/<país>/                    charts de YouTube cargados
  Reportes BackOffice/<país>/               reportes de BackOffice cargados
  Reportes Tempo Control/                   reportes de Tempo Control cargados (y Tempo IDs/)
  respaldo_documentacion_sistema/respaldos/ respaldos completos (.dump de la base y .tgz de los archivos)
  respaldo_documentacion_sistema/docs/      documentación técnica, manual de uso y esquema de datos

Para recuperar el sistema a partir de un respaldo: bash ranking.sh restaurar <nombre> (ver docs/README.md).
"""


def raiz():
    r = os.environ.get("ESPEJO", "").strip()
    return pathlib.Path(r) if r else None


def nombre_seguro(nombre):
    # Lo que Windows/OneDrive no acepta en un nombre de archivo.
    limpio = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", (nombre or "").strip()).strip(" .")
    return limpio or "archivo.csv"


def destino(carga, base):
    """Ruta del archivo en el espejo para una fila de csv_uploads, o None si no corresponde copiarla."""
    carpeta = CARPETAS.get(carga.get("format") or "")
    if not carpeta or not carga.get("file_path") or not carga.get("updated_rows"):
        return None
    if "/importado-onedrive/" in str(carga["file_path"]):   # vino de OneDrive (cargar-historicos): ya está ahí
        return None
    sub, por_pais = carpeta
    d = base / sub
    if por_pais:
        partes = str(carga["file_path"]).split("/")
        pais = partes[1] if len(partes) > 2 and partes[1] in PAISES else "sin_pais"
        d = d / pais.lower()
    return d / nombre_seguro(carga.get("filename"))


def escribir_leeme(base):
    try:
        f = base / "LEEME - Respaldo y auditoria.txt"
        if not f.exists() or f.read_text(encoding="utf-8") != LEEME:
            f.write_text(LEEME, encoding="utf-8")
    except OSError as e:
        log.warning("Espejo OneDrive: no se pudo escribir el LEEME: %s", e)


def copiar(carga, storage_dir, solo_faltantes=False):
    """Copia el archivo de una carga al espejo. Nunca lanza excepciones: devuelve True si quedó copiado."""
    base = raiz()
    if base is None:
        return False
    try:
        d = destino(carga, base)
        if d is None:
            return False
        if solo_faltantes and d.exists():
            return True
        origen = pathlib.Path(storage_dir) / "csv-uploads" / carga["file_path"]
        if not origen.is_file():
            log.warning("Espejo OneDrive: no está el archivo %s", carga["file_path"])
            return False
        d.parent.mkdir(parents=True, exist_ok=True)
        tmp = d.with_name(d.name + ".copiando")
        shutil.copyfile(origen, tmp)
        os.replace(tmp, d)
        escribir_leeme(base)
        return True
    except Exception as e:  # el espejo nunca interrumpe una carga
        log.warning("Espejo OneDrive: no se pudo copiar %s: %s", carga.get("filename"), e)
        return False


def sincronizar(pgurl, storage_dir):
    """Copia al espejo las cargas que todavía no están (no borra ni pisa nada)."""
    import psycopg
    from psycopg.rows import dict_row
    with psycopg.connect(pgurl, row_factory=dict_row) as con:
        cargas = con.execute("SELECT filename, file_path, format, updated_rows FROM public.csv_uploads "
                             "ORDER BY uploaded_at").fetchall()
    base = raiz()
    if base is not None:
        base.mkdir(parents=True, exist_ok=True)
        escribir_leeme(base)
    copiadas = sum(copiar(c, storage_dir, solo_faltantes=True) for c in cargas)
    aplica = sum(destino(c, base) is not None for c in cargas) if base else 0
    return copiadas, aplica


def servicio(pgurl, storage_dir, intervalo=3):
    """Copia lo que falte y después, cada `intervalo` segundos, las cargas nuevas (por id de csv_uploads)."""
    import time
    import psycopg
    from psycopg.rows import dict_row
    if raiz() is None:
        log.info("Espejo OneDrive apagado: no hay carpeta configurada.")
        while True:
            time.sleep(3600)
    ultimo = None
    while True:
        try:
            with psycopg.connect(pgurl, row_factory=dict_row, autocommit=True) as con:
                while True:
                    maximo = con.execute("SELECT coalesce(max(id), 0) AS m FROM public.csv_uploads").fetchone()["m"]
                    if ultimo is None or maximo < ultimo:
                        # Al arrancar, o si la base volvió atrás (restaurar): repaso completo, sin pisar nada.
                        copiadas, aplica = sincronizar(pgurl, storage_dir)
                        log.info("Espejo OneDrive: %s de %s archivos de carga presentes.", copiadas, aplica)
                        ultimo = maximo
                    nuevas = con.execute("SELECT id, filename, file_path, format, updated_rows FROM public.csv_uploads "
                                         "WHERE id > %s ORDER BY id", (ultimo,)).fetchall()
                    for c in nuevas:
                        if copiar(c, storage_dir):
                            log.info("Espejo OneDrive: copiado %s", c["filename"])
                        ultimo = c["id"]
                    time.sleep(intervalo)
        except Exception as e:  # base reiniciándose, etc.: se reintenta
            log.warning("Espejo OneDrive: %s; reintento en 10 s", e)
            time.sleep(10)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    if raiz() is None:
        sys.exit("No hay carpeta de espejo configurada (variable ESPEJO).")
    if "--leeme" in sys.argv:   # solo la explicación de la carpeta (la usa ranking.sh respaldo)
        raiz().mkdir(parents=True, exist_ok=True)
        escribir_leeme(raiz())
        sys.exit(0)
    if "--servicio" in sys.argv:
        servicio(os.environ["PGURL"], os.environ.get("STORAGE_DIR", "/data/storage"))
    ok, total = sincronizar(os.environ["PGURL"], os.environ.get("STORAGE_DIR", "/data/storage"))
    print(f"Espejo OneDrive: {ok} de {total} archivos de carga presentes.")
    sys.exit(0 if ok == total else 1)
