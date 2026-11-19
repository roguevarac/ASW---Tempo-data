"""
Carga masiva (única) de charts históricos de Spotify y YouTube desde carpetas, por ejemplo las del espejo de OneDrive
("Spotify Charts" y "Youtube Charts"). La usa: bash ranking.sh cargar-historicos

Lee cada archivo igual que "Carga CSV" del front (frontend_ranking_digital.html: readFileText, quitarNotaInicial,
Papa.parse con canonicalHeader, detectFormat, detectCountry*, detectDateFromFilename, entero, processRankingCsv y
finishUpload) y carga con la misma función de la base (fn_upsert_ranking_batch). tests/test_importar_charts.py
compara el resultado con el del front real. Diferencias a propósito, por tratarse de históricos:
  - si el nombre no indica el país, se usa la carpeta del país (ar/, AR/, Argentina/...) antes que Source.Name;
  - si el nombre no indica la semana, el archivo no se carga (el front usaría la fecha del día);
  - si la plataforma no surge del nombre ni de los links, manda la carpeta ("Youtube Charts" o "Spotify Charts");
  - un archivo ya cargado (importado antes, o cargado con datos desde la aplicación) no se vuelve a cargar: se
    puede cortar y retomar;
  - los archivos se guardan en <plataforma>/<PAÍS>/importado-onedrive/ y el espejo no los vuelve a copiar a OneDrive
    (ya están ahí).

Uso: PGURL=postgresql://postgres:...@db/ranking STORAGE_DIR=/data/storage python importar_charts.py CARPETA [CARPETA ...]
"""
import codecs
import csv
import io
import json
import os
import pathlib
import re
import sys
import time
import unicodedata

QUIEN = "importación histórica"
MARCA = "importado-onedrive"

COUNTRY_ALIASES = {"ar": "AR", "arg": "AR", "cl": "CL", "chl": "CL", "pe": "PE", "per": "PE", "uy": "UY", "ury": "UY",
                   "py": "PY", "pry": "PY", "co": "CO", "col": "CO", "ec": "EC", "ecu": "EC", "mx": "MX", "mex": "MX"}
COUNTRY_NAME_ALIASES = {"ARGENTINA": "AR", "CHILE": "CL", "PERU": "PE", "URUGUAY": "UY", "PARAGUAY": "PY",
                        "COLOMBIA": "CO", "ECUADOR": "EC", "MEXICO": "MX"}
HEADER_ALIASES = {
    "source_name": "source_name", "rank": "rank", "previous_rank": "previous_rank", "peak_rank": "peak_rank",
    "track_name": "track_name", "artist_names": "artist_names", "artist_name": "artist_names",
    "weeks_on_chart": "weeks_on_chart", "periods_on_chart": "weeks_on_chart",
    "streams": "streams", "views": "streams",
    "weekly_growth": "weekly_growth", "growth": "weekly_growth",
    "uri": "uri", "youtube_url": "uri", "source": "source",
    "position": "rank", "artist": "artist_names", "url": "uri",
    "tempo_id": "tempo_id", "bo_id": "bo_id", "ctrl": "percent_ctrl", "percent_ctrl": "percent_ctrl",
    "collect_mec": "collect_mec", "collect_ejec": "collect_ejec", "control": "control", "cwr": "cwr", "nota": "nota",
    "submitters_song_code": "tempo_id", "internal_song_code": "bo_id",
    "song_owners": "ca", "song_owner": "ca", "songowners": "ca", "owners": "ca",
    "bointernal_status": "bo_status", "internal_status": "bo_status", "counterclaim_status": "reclamos",
    "song_id": "tempo_id", "song_title_tx": "song_title", "pais": "pais_nombre",
    "performance_pc_total": "perf_pc", "mechanical_pc_total": "mech_pc", "sync_pc_total": "sync_pc",
    "publishers": "publishers", "contratos_del_pais": "contratos",
    "song_tempo_create_date": "created_date", "estado_obra": "estado_obra",
    "track_artista": "track_artist_concat", "track_artist": "track_artist_concat",
}
# Espacios que saca String.prototype.trim() de JavaScript (incluye el BOM).
JS_ESPACIOS = " \t\n\r\v\f             " \
              "    　﻿"


def js_trim(s):
    return s.strip(JS_ESPACIOS)


def strip_accents(s):
    return "".join(c for c in unicodedata.normalize("NFD", s) if not "̀" <= c <= "ͯ")


# TextDecoder('windows-1252') del navegador: los 5 bytes que cp1252 no define pasan como el carácter de igual código.
codecs.register_error("w1252", lambda e: (chr(e.object[e.start]), e.start + 1))


def leer_texto(datos):
    texto = datos.decode("utf-8-sig", errors="replace")
    if "�" in texto:
        texto = datos.decode("cp1252", errors="w1252")
    return texto


def quitar_nota_inicial(texto):
    if re.match(r'^﻿?\s*"?note that', texto, re.I):
        return texto[texto.find("\n") + 1:]
    return texto


def canonical_header(h):
    key = js_trim(strip_accents(re.sub(r"^﻿", "", h))).lower()
    key = re.sub(r"^_+|_+$", "", re.sub(r"[^a-z0-9]+", "_", key))
    if key in HEADER_ALIASES:
        return HEADER_ALIASES[key]
    if key.startswith("mechanicall_collect_share"):
        return "mech_bo"
    if "owner" in key:
        return "ca"
    if "status" in key and "claim" not in key:
        return "bo_status"
    return key


def _filas(texto, delim, limite=None):
    out = []
    for fila in csv.reader(io.StringIO(texto, newline=""), delimiter=delim):
        out.append(fila)
        if limite and len(out) >= limite:
            break
    return out


def adivinar_separador(texto):
    """Como Papa.parse (guessDelimiter): el separador con más campos por fila y la cantidad más pareja."""
    mejor, mejor_delta, max_campos = ",", None, None
    for d in [",", "\t", "|", ";", "\x1e", "\x1f"]:
        filas = _filas(texto, d, 10)
        delta, total, vacias, previo = 0, 0, 0, None
        for f in filas:
            if len(f) == 0 or (len(f) == 1 and f[0] == ""):
                vacias += 1
                continue
            total += len(f)
            if previo is None:
                previo = len(f)
            elif len(f) > 0:
                delta += abs(len(f) - previo)
                previo = len(f)
        promedio = total / (len(filas) - vacias) if len(filas) - vacias > 0 else 0
        if (mejor_delta is None or delta <= mejor_delta) and (max_campos is None or promedio > max_campos) and promedio > 1.99:
            mejor, mejor_delta, max_campos = d, delta, promedio
    return mejor


def parsear(texto):
    """Papa.parse(texto, {header: true, skipEmptyLines: true, transformHeader: canonicalHeader})."""
    filas = [f for f in _filas(texto, adivinar_separador(texto)) if not (len(f) == 0 or (len(f) == 1 and f[0] == ""))]
    if not filas:
        return []
    encabezados, vistos = [], {}
    for h in filas[0]:
        h = canonical_header(h)
        if h in vistos:                     # Papa renombra los repetidos: a, a_1, a_2...
            vistos[h] += 1
            nuevo = f"{h}_{vistos[h]}"
            while nuevo in vistos:
                vistos[h] += 1
                nuevo = f"{h}_{vistos[h]}"
            vistos[nuevo] = 0
            h = nuevo
        else:
            vistos[h] = 0
        encabezados.append(h)
    datos = []
    for f in filas[1:]:
        d = {}
        for i, v in enumerate(f):
            if i < len(encabezados):
                d[encabezados[i]] = v
            else:
                d.setdefault("__parsed_extra", []).append(v)
        datos.append(d)
    return datos


def detect_country(texto):
    t = str(texto or "").lower()
    for alias, code in COUNTRY_ALIASES.items():
        if re.search(rf"(^|[^a-z]){alias}([^a-z]|$)", t):
            return code
    return None


def detect_country_from_filename(nombre):
    if not nombre:
        return None
    limpio = strip_accents(nombre).upper()
    m = re.search(r"PAIS_([A-Z]+)", limpio)
    if m and m.group(1) in COUNTRY_NAME_ALIASES:
        return COUNTRY_NAME_ALIASES[m.group(1)]
    for nombre_pais, code in COUNTRY_NAME_ALIASES.items():
        if nombre_pais in limpio:
            return code
    return None


def detect_date_from_filename(nombre):
    if not nombre:
        return None
    m = re.search(r"(20\d{2})-(\d{2})-(\d{2})", nombre) or re.search(r"(20\d{2})(\d{2})(\d{2})", nombre)
    return f"{m.group(1)}-{m.group(2)}-{m.group(3)}" if m else None


def detect_format(row, nombre):
    if "track_artist_concat" in row and "tempo_id" in row:
        return "master_tempo"
    if "perf_pc" in row or "mech_pc" in row or "estado_obra" in row:
        return "tempo_report"
    if "mech_bo" in row or "bo_status" in row or "reclamos" in row or "ca" in row:
        return "bo_report"
    if "track_name" in row and "artist_names" in row:
        fname = (nombre or "").lower()
        uri = str(row.get("uri") or "").lower()
        if "youtube" in fname or "youtube.com" in uri or "youtu.be" in uri:
            return "youtube"
        if "spotify" in fname or uri.startswith("spotify:"):
            return "spotify"
        return "youtube" if "weekly_growth" in row else "spotify"
    return None


def plataforma_concluyente(row, nombre):
    fname = (nombre or "").lower()
    uri = str(row.get("uri") or "").lower()
    return "youtube" in fname or "spotify" in fname or "youtube.com" in uri or "youtu.be" in uri or uri.startswith("spotify:")


def entero(v):
    t = re.sub(r"\s", "", js_trim(str(v if v is not None else "")))
    if re.fullmatch(r"\d{1,3}([.,]\d{3})+", t):
        return re.sub(r"[.,]", "", t)
    m = re.fullmatch(r"(\d+)([.,]\d+)?", t)
    return m.group(1) if m else None


def js_parse_float(s):
    m = re.match(r"^[\s﻿ ]*([+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?)", s)
    return float(m.group(1)) if m else None


def crecimiento(v):
    if not v:
        return None
    n = js_parse_float(str(v).replace("%", "", 1).replace(",", ".", 1))
    if n is None:
        return None
    return int(n) if n == int(n) else n


def sanitizar_nombre(nombre):
    limpio = re.sub(r"[^a-zA-Z0-9._-]+", "_", strip_accents(nombre))
    limpio = re.sub(r"_+", "_", limpio)
    return re.sub(r"^_|_$", "", limpio) or "archivo.csv"


def pais_de_carpeta(rel):
    for parte in rel.parts[:-1]:
        p = strip_accents(parte).upper()
        if p in COUNTRY_NAME_ALIASES.values():
            return p
        if p in COUNTRY_NAME_ALIASES:
            return COUNTRY_NAME_ALIASES[p]
    return None


def plataforma_de_carpeta(raiz):
    n = raiz.name.lower()
    return "youtube" if "youtube" in n else "spotify" if "spotify" in n else None


def es_chart(p):
    n = p.name
    if n.startswith(("~$", ".")) or not p.is_file():
        return False
    return p.suffix.lower() == ".csv" or (p.suffix == "" and "weekly" in n.lower())


def preparar(nombre, rel, raiz, datos):
    """Lo que hace processRankingCsv antes de llamar a la base. Devuelve (formato, país, semana, filas, errores, aviso)."""
    texto = quitar_nota_inicial(leer_texto(datos))
    filas = parsear(texto)
    if not filas:
        return None, None, None, [], ["CSV vacío"], None
    formato = detect_format(filas[0], nombre)
    aviso = None
    carpeta = plataforma_de_carpeta(raiz)
    if formato in ("spotify", "youtube") and carpeta and formato != carpeta:
        if not plataforma_concluyente(filas[0], nombre):
            formato = carpeta
        else:
            aviso = f"está en la carpeta de {carpeta} pero es un chart de {formato}"
    if formato not in ("spotify", "youtube"):
        return formato, None, None, filas, ["No es un chart de Spotify o YouTube."], None
    pais = detect_country_from_filename(nombre) or detect_country(nombre) or pais_de_carpeta(rel)
    if not pais and "source_name" not in filas[0]:
        return formato, None, None, filas, [
            f'No se pudo determinar el país: el nombre "{nombre}" no lo incluye y el archivo no trae columna Source.Name.'], aviso
    semana = detect_date_from_filename(nombre)
    if not semana:
        return formato, pais, None, filas, [
            f'El nombre "{nombre}" no indica la semana del chart (por ejemplo 2024-01-04): no se cargó.'], aviso
    preparadas, errores = [], []
    for row in filas:
        track = js_trim(row["track_name"]) if row.get("track_name") is not None else None
        artista = js_trim(row["artist_names"]) if row.get("artist_names") is not None else ""
        if not track:
            errores.append("Fila sin título")
            continue
        p = pais or detect_country(row.get("source_name"))
        if not p:
            errores.append(f"No se pudo determinar país en: {row.get('source_name') or '(sin Source.Name)'}")
            continue
        preparadas.append({
            "track_name": track, "artist_names": artista, "pais_code": p,
            "rank": entero(row.get("rank")), "peak_rank": entero(row.get("peak_rank")),
            "previous_rank": entero(row.get("previous_rank")), "weeks_on_chart": entero(row.get("weeks_on_chart")),
            "streams": entero(row.get("streams")), "source": row.get("source") or None, "uri": row.get("uri") or None,
            "weekly_growth": crecimiento(row.get("weekly_growth")), "snapshot_date": semana,
        })
    return formato, pais, semana, filas, errores, aviso, preparadas


def a_nombre_del_sistema(storage, destino):
    """Corre como root (para leer OneDrive): lo guardado queda a nombre del dueño del almacenamiento (el usuario de la
    API), así la API puede seguir creando carpetas y archivos ahí."""
    if os.geteuid() != 0:
        return
    st = storage.stat() if storage.exists() else storage.parent.stat()
    p = destino
    while p != storage and storage in p.parents:
        os.chown(p, st.st_uid, st.st_gid)
        p = p.parent


def importar(pgurl, storage_dir, carpetas, salida=print):
    import psycopg
    storage = pathlib.Path(storage_dir) / "csv-uploads"
    if not storage.exists():
        storage.mkdir(parents=True)
        if os.geteuid() == 0:   # mismo dueño que la carpeta del almacenamiento (el usuario de la API)
            st = storage.parent.stat()
            os.chown(storage, st.st_uid, st.st_gid)
    archivos = []
    ilegibles = []
    for c in carpetas:
        raiz = pathlib.Path(c)
        if not raiz.is_dir():
            salida(f"No existe la carpeta {raiz}: se saltea.")
            continue
        antes = len(archivos)
        # os.walk sigue aunque una subcarpeta no se pueda leer (queda informada).
        for actual, _, nombres in os.walk(raiz, onerror=lambda e: ilegibles.append(f"{e.filename}: {e.strerror}")):
            for n in nombres:
                p = pathlib.Path(actual) / n
                if es_chart(p):
                    rel = p.relative_to(raiz)
                    archivos.append((detect_date_from_filename(p.name) or "", str(rel).lower(), p, rel, raiz))
        salida(f"{raiz.name}: {len(archivos) - antes} archivos")
    archivos.sort()
    total = len(archivos)
    salida(f"Archivos encontrados: {total}")
    for x in ilegibles:
        salida(f"  No se pudo leer la carpeta {x}")
    res = {"cargados": 0, "con_errores": 0, "no_cargados": 0, "ya_importados": 0, "filas": 0, "nuevas": 0}
    problemas, avisos = [], []
    inicio = time.time()
    # autocommit: cada archivo se confirma en su propia transacción (con.transaction()), así una carga cortada
    # conserva lo hecho y se retoma desde ahí.
    with psycopg.connect(pgurl, autocommit=True) as con:
        # Ya cargados: lo importado antes (aunque no haya cargado filas) y cualquier carga con datos, por ejemplo las
        # copias que el espejo dejó en estas mismas carpetas.
        ya = {r[0] for r in con.execute(
            "SELECT filename FROM public.csv_uploads WHERE file_path LIKE %s OR updated_rows > 0", (f"%/{MARCA}/%",)).fetchall()}
        for n, (_, _, p, rel, raiz) in enumerate(archivos, 1):
            nombre = p.name
            if nombre in ya:
                res["ya_importados"] += 1
                continue
            try:
                datos = p.read_bytes()
            except OSError as e:   # por ejemplo, un archivo de OneDrive que está solo en la nube y no se descargó
                res["no_cargados"] += 1
                problemas.append(f"{rel}: no se pudo leer el archivo ({e.strerror or e}). Abrí la carpeta en OneDrive y "
                                 "marcá \"Mantener siempre en este dispositivo\"; después volvé a correr la carga.")
                continue
            r = preparar(nombre, rel, raiz, datos)
            formato, pais, semana, filas, errores, aviso = r[:6]
            preparadas = r[6] if len(r) > 6 else []
            if aviso:
                avisos.append(f"{rel}: {aviso}")
            if formato not in ("spotify", "youtube"):
                res["no_cargados"] += 1
                problemas.append(f"{rel}: {errores[0]}")
                continue
            cargadas = nuevas = 0
            with con.transaction():
                cur = con.cursor()
                for i in range(0, len(preparadas), 250):
                    lote = preparadas[i:i + 250]
                    for idx, creada, error in cur.execute(
                            "SELECT idx, track_created, error_message FROM public.fn_upsert_ranking_batch(%s::jsonb, %s)",
                            (json.dumps(lote), formato)).fetchall():
                        if error:
                            errores.append(f"{lote[idx - 1]['track_name'] if idx - 1 < len(lote) else 'fila'}: {error}")
                        else:
                            cargadas += 1
                            nuevas += 1 if creada else 0
                ruta = f"{formato}/{pais or 'sin_pais'}/{MARCA}/{int(time.time() * 1000)}_{sanitizar_nombre(nombre)}"
                cur.execute("INSERT INTO storage.objects (bucket_id, name, metadata) VALUES ('csv-uploads', %s, %s)",
                            (ruta, json.dumps({"size": len(datos), "mimetype": "text/csv"})))
                destino = storage / ruta
                destino.parent.mkdir(parents=True, exist_ok=True)
                destino.write_bytes(datos)
                a_nombre_del_sistema(storage, destino)
                cur.execute("INSERT INTO public.csv_uploads (filename, total_rows, created_tracks, updated_rows, error_count, "
                            "errors, file_path, format, uploaded_by) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)",
                            (nombre, len(filas), nuevas, cargadas, len(errores), json.dumps(errores[:100]), ruta, formato, QUIEN))
            ya.add(nombre)
            res["filas"] += cargadas
            res["nuevas"] += nuevas
            if cargadas and not errores:
                res["cargados"] += 1
            elif cargadas:
                res["con_errores"] += 1
                problemas.append(f"{rel}: {len(errores)} filas con error (por ejemplo: {errores[0]})")
            else:
                res["no_cargados"] += 1
                problemas.append(f"{rel}: {errores[0] if errores else 'sin filas'}")
            if n % 25 == 0 or n == total:
                seg = time.time() - inicio
                salida(f"  {n} de {total} archivos ({res['filas']} filas cargadas, {res['nuevas']} canciones nuevas, "
                       f"{seg / 60:.1f} min)")
    salida("")
    salida(f"Cargados completos: {res['cargados']}  |  con filas con error: {res['con_errores']}  |  "
           f"no cargados: {res['no_cargados']}  |  ya cargados antes: {res['ya_importados']}")
    salida(f"Filas cargadas: {res['filas']}  |  canciones nuevas: {res['nuevas']}")
    if avisos:
        salida(f"\nAvisos ({len(avisos)}):")
        for a in avisos:
            salida("  " + a)
    if problemas:
        salida(f"\nArchivos con problemas ({len(problemas)}):")
        for x in problemas:
            salida("  " + x)
    return res, problemas, avisos


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    r, _, _ = importar(os.environ["PGURL"], os.environ.get("STORAGE_DIR", "/data/storage"), sys.argv[1:])
    sys.exit(0)
