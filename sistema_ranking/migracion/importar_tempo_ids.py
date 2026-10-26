"""
Carga masiva de Tempo IDs desde una planilla (bash ranking.sh cargar-tempo-ids <archivo>).

La planilla tiene dos columnas: "Título // Artistas" (o "Título - Artistas") y el Tempo ID (.xlsx o .csv). El archivo
llega por la entrada estándar. Este script limpia el texto y la base hace el cruce y la carga (fn_cargar_tempo_ids,
db/mejoras/06_tempo_ids.sql):
  - tildes mal codificadas ("FrÃ¡gil" -> "Frágil"), tildes sueltas, comillas tipográficas y espacios de más;
  - título y artistas por el último "//" (o el último " - " si no hay "//").
La normalización de títulos (tildes, "&", versiones en vivo, mayúsculas, signos) es la de la base, igual que en la
carga de charts.

    PGURL=... STORAGE_DIR=... python importar_tempo_ids.py --nombre archivo.xlsx [--simular] < archivo.xlsx > reporte.csv

--simular: hace todo en una transacción que se deshace (no cambia nada) y muestra qué pasaría.
Salida: el reporte (CSV con ";" para Excel) por la salida estándar y el resumen por la de errores.
"""
import collections
import csv
import datetime as dt
import io
import json
import os
import pathlib
import re
import sys
import time
import unicodedata
import uuid
import xml.etree.ElementTree as ET
import zipfile

import psycopg

NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
      "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships"}
REL = "{http://schemas.openxmlformats.org/package/2006/relationships}"


def leer_xlsx(datos):
    """Filas (columna A, columna B) de la primera hoja, sin librerías externas."""
    z = zipfile.ZipFile(io.BytesIO(datos))
    compartidos = []
    if "xl/sharedStrings.xml" in z.namelist():
        for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall("m:si", NS):
            compartidos.append("".join(t.text or "" for t in si.iter(f"{{{NS['m']}}}t")))
    libro = ET.fromstring(z.read("xl/workbook.xml"))
    hoja_id = libro.find("m:sheets/m:sheet", NS).get(f"{{{NS['r']}}}id")
    rels = ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))
    destino = next(r.get("Target") for r in rels.iter(f"{REL}Relationship") if r.get("Id") == hoja_id)
    ruta = destino.lstrip("/") if destino.startswith("/") else "xl/" + destino
    filas = []
    for fila in ET.fromstring(z.read(ruta)).iter(f"{{{NS['m']}}}row"):
        valores = {}
        for c in fila.findall("m:c", NS):
            col = re.match(r"[A-Z]+", c.get("r", "A")).group(0)
            tipo, v = c.get("t"), c.find("m:v", NS)
            if tipo == "s" and v is not None:
                valores[col] = compartidos[int(v.text)]
            elif tipo == "inlineStr":
                valores[col] = "".join(t.text or "" for t in c.iter(f"{{{NS['m']}}}t"))
            elif v is not None:
                texto = v.text or ""
                valores[col] = texto[:-2] if re.fullmatch(r"\d+\.0", texto) else texto   # 6662847.0 -> 6662847
        filas.append((valores.get("A"), valores.get("B")))
    return filas


def leer_csv(datos):
    texto = datos.decode("utf-8-sig") if datos[:3] == b"\xef\xbb\xbf" else None
    if texto is None:
        try:
            texto = datos.decode("utf-8")
        except UnicodeDecodeError:
            texto = datos.decode("cp1252")
    delim = ";" if texto.split("\n", 1)[0].count(";") > texto.split("\n", 1)[0].count(",") else ","
    return [(r[0] if r else None, r[1] if len(r) > 1 else None) for r in csv.reader(io.StringIO(texto), delimiter=delim)]


def arreglar_codificacion(s):
    """'FrÃ¡gil' -> 'Frágil' (UTF-8 leído como Windows-1252), sin tocar la 'Ã' legítima ('BATIDÃO')."""
    def par(m):
        a, b = m.group(1), m.group(2)
        try:
            crudo = bytes([ord(a)]) + (b.encode("cp1252") if ord(b) > 255 else bytes([ord(b)]))
            if 0x80 <= crudo[1] <= 0xBF:
                return crudo.decode("utf-8")
        except (UnicodeError, ValueError):
            pass
        return m.group(0)
    return re.sub(r"([ÃÂ])(.)", par, s)


def limpiar(s):
    s = arreglar_codificacion(str(s or ""))
    s = unicodedata.normalize("NFC", s)                                    # tildes sueltas -> letra con tilde
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")          # tachados y marcas que quedan sueltas
    s = s.translate(str.maketrans({"’": "'", "‘": "'", "´": "'", "“": '"', "”": '"', "–": "-", "—": "-", " ": " "}))
    return re.sub(r"\s+", " ", s).strip()


def separar(texto):
    if "//" in texto:
        titulo, artistas = texto.rsplit("//", 1)
    elif " - " in texto:
        titulo, artistas = texto.rsplit(" - ", 1)
    else:
        titulo, artistas = texto, ""
    return titulo.strip(), artistas.strip()


def preparar(filas):
    datos = []
    for n, (texto, tempo) in enumerate(filas, start=1):
        if n == 1 and str(texto or "").strip().lower() in ("concatenate", "track - artista", "obra") \
                or n == 1 and "tempo" in str(tempo or "").lower():
            continue   # encabezado
        texto = limpiar(texto)
        if not texto and tempo in (None, ""):
            continue
        titulo, artistas = separar(texto)
        datos.append({"fila": n, "texto": texto, "titulo": titulo, "artistas": artistas,
                      "tempo_id": "" if tempo is None else str(tempo).strip()})
    return datos


def guardar_archivo(cur, datos, nombre, storage):
    """El archivo original queda en el sistema (Historial de cargas > Reportes Tempo Control > Tempo IDs)."""
    seguro = re.sub(r"[^a-zA-Z0-9._-]+", "_", unicodedata.normalize("NFKD", nombre).encode("ascii", "ignore").decode()).strip("_")
    ruta = f"tempo_ids/{dt.date.today().isoformat()}/{int(time.time() * 1000)}_{seguro or 'tempo_ids.xlsx'}"
    destino = pathlib.Path(storage) / "csv-uploads" / ruta
    destino.parent.mkdir(parents=True, exist_ok=True)
    tmp = destino.with_name(destino.name + f".{uuid.uuid4().hex}.tmp")
    tmp.write_bytes(datos)
    os.replace(tmp, destino)
    cur.execute("INSERT INTO storage.objects (bucket_id, name, metadata) VALUES ('csv-uploads', %s, %s)",
                (ruta, json.dumps({"size": len(datos), "mimetype": "application/octet-stream"})))
    return ruta


def main():
    args = sys.argv[1:]
    simular = "--simular" in args
    nombre = args[args.index("--nombre") + 1] if "--nombre" in args else "tempo_ids.xlsx"
    datos = sys.stdin.buffer.read()
    if not datos:
        sys.exit("No llegó ningún archivo.")
    filas = leer_xlsx(datos) if datos[:2] == b"PK" else leer_csv(datos)
    preparadas = preparar(filas)
    if not preparadas:
        sys.exit("El archivo no tiene filas.")
    with psycopg.connect(os.environ["PGURL"]) as con, con.cursor() as cur:
        cur.execute("SET statement_timeout = 0")
        cur.execute("SELECT * FROM fn_cargar_tempo_ids(%s::jsonb)", (json.dumps(preparadas, ensure_ascii=False),))
        resultado = cur.fetchall()
        es_numero = lambda r: str(r[2] or "").isdigit()
        cuenta = collections.Counter(r[3] for r in resultado if es_numero(r))
        marcas = collections.Counter(r[3] for r in resultado if not es_numero(r) and r[3] != "SIN TEMPO ID")
        vacios = sum(1 for r in resultado if r[3] == "SIN TEMPO ID")
        niveles = collections.Counter(r[4] for r in resultado if r[3] in ("CARGADO", "SIN CAMBIOS"))
        unificadas = sum(1 for r in resultado if r[6] and "Unificada" in r[6])
        if simular:
            con.rollback()
        else:
            cargadas = cuenta.get("CARGADO", 0) + marcas.get("CARGADO", 0)
            ruta = guardar_archivo(cur, datos, nombre, os.environ.get("STORAGE_DIR", "/data/storage"))
            errores = [f"{r[1]}: {r[3]} ({r[6]})" for r in resultado if r[3] in ("NO ENCONTRADA", "CONFLICTO", "CONFLICTO EN EL ARCHIVO")]
            cur.execute("""INSERT INTO csv_uploads (filename, uploaded_by, total_rows, created_tracks, updated_rows, error_count,
                                                    errors, file_path, format)
                           VALUES (%s, 'carga de Tempo IDs (consola)', %s, 0, %s, %s, %s, %s, 'master_tempo')""",
                        (nombre, len(resultado), cargadas, len(errores), json.dumps(errores[:100], ensure_ascii=False), ruta))
            con.commit()

    salida = csv.writer(sys.stdout, delimiter=";", lineterminator="\r\n")
    sys.stdout.write("﻿")   # Excel reconoce las tildes
    salida.writerow(["Fila", "Obra en el archivo", "Tempo ID", "Resultado", "Coincidencia", "Obra en el sistema", "Detalle"])
    for r in resultado:
        salida.writerow([r[0], r[1], r[2], r[3], r[4] or "", r[5] or "", r[6] or ""])

    total = len(resultado)
    con_tempo = sum(cuenta.values())
    con_marca = sum(marcas.values())
    p = lambda n: f"{n} ({100 * n / con_tempo:.0f} %)" if con_tempo else str(n)
    print(("SIMULACIÓN (no se cambió nada)\n" if simular else "") +
          f"Filas del archivo: {total} · con Tempo ID numérico: {con_tempo}\n"
          f"  Cargadas:                      {p(cuenta.get('CARGADO', 0))}" + (f" · {unificadas} obras unificadas" if unificadas else "") + "\n"
          f"  Ya tenían ese Tempo ID:        {p(cuenta.get('SIN CAMBIOS', 0))}\n"
          f"  No encontradas en el sistema:  {p(cuenta.get('NO ENCONTRADA', 0))}\n"
          f"  Conflicto (ya tenían otro):    {cuenta.get('CONFLICTO', 0)}\n"
          f"  Conflicto en el archivo:       {cuenta.get('CONFLICTO EN EL ARCHIVO', 0)} (la misma obra con dos Tempo ID)\n"
          f"Filas con marcador (UNCONTROLLED, COMPILADO): {con_marca}\n"
          f"  Cargadas:                      {marcas.get('CARGADO', 0)}\n"
          f"  Ya lo tenían o tienen un Tempo ID numérico: {marcas.get('SIN CAMBIOS', 0)}\n"
          f"  No encontradas en el sistema:  {marcas.get('NO ENCONTRADA', 0)}\n"
          f"  En conflicto:                  {marcas.get('CONFLICTO EN EL ARCHIVO', 0) + marcas.get('CONFLICTO', 0)}\n"
          f"Filas sin Tempo ID ni marcador (vacías): {vacios}\n"
          f"Coincidencias: " + ", ".join(f"{k}: {v}" for k, v in sorted(niveles.items(), key=lambda x: -x[1]) if k),
          file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except psycopg.Error as e:
        sys.exit(f"Error de la base: {e.diag.message_primary or e}")
