"""
Carga masiva de Tempo IDs desde una planilla (migracion/importar_tempo_ids.py + fn_cargar_tempo_ids,
db/mejoras/06_tempo_ids.sql), con un .xlsx armado acá con los casos de la planilla real:
tildes convertidas en mayúsculas ("ParEntesis"), tildes mal codificadas ("FrÃ¡gil"), "&" o "," entre artistas, otro
orden, menos artistas, "(feat. ...)", títulos sin artista, UNCONTROLLED, vacíos, Tempo IDs repetidos (la misma canción
escrita distinto en Spotify y YouTube) y contradicciones.
También: simular no cambia nada, repetir la carga no cambia nada, queda en el historial y no se puede llamar por la API.

Variables: BASE, PGURL, STORAGE_DIR. Usa obras propias (prefijo "TI ").
"""
import csv
import io
import os
import pathlib
import subprocess
import sys
import tempfile

import httpx
import openpyxl

PGURL = os.environ["PGURL"]
BASE = os.environ.get("BASE", "http://localhost:8787")
RAIZ = pathlib.Path(__file__).resolve().parents[1]
fallas = []


def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + nombre + ("" if cond else f"  -> {extra}"))
    if not cond:
        fallas.append(nombre)


def sqlq(q):
    r = subprocess.run(["psql", PGURL, "-At", "-c", q], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"SQL del test falló: {q}\n{r.stderr}")
    return r.stdout.strip()


# Obras como quedan al cargar los charts (con tildes, "&" convertido en ",", etc.).
OBRAS = [
    ("TI (Entre Paréntesis)", "Shakira & Grupo Frontera"),            # 1 exacta (tildes como mayúsculas en el archivo)
    ("TI Frágil", "Yahritza Y Su Esencia, Grupo Frontera"),          # 1 exacta (FrÃ¡gil mal codificado)
    ("TI Orden", "Bad Bunny, Myke Towers"),                          # 2 otro orden
    ("TI Gata Only", "FloyyMenor"),                                  # 3 un artista (YouTube)
    ("TI Gata Only", "FloyyMenor, Cris Mj"),                         # 1 exacta (Spotify): misma canción -> se unifican
    ("TI Otra vez", "Zion & Lennox"),                                # 4 sin feat.
    ("TI Señuelo", "Otra Persona"),                                  # mismo título, otro artista: no
    ("TI Ya Tiene", "Alguien"),                                      # ya tiene otro Tempo ID: conflicto
    ("TI Envolver", "Anitta"),                                       # 5 solo título (la fila no trae artistas)
    ("TI Repetido", "Uno"), ("TI Repetido", "Dos"),                  # solo título, pero hay dos: no
    ("TI Contradicción", "Banda"),                                   # el archivo trae dos Tempo ID: no
    ("TI 사람 Pt.2", "SUGA, IU"),                                     # coreano
    ("TI Uncontrolled", "Nadie"), ("TI Uncontrolled Dos", "Otra Nadie"),   # el mismo marcador en dos obras
    ("TI Numero Gana", "Banda N"),                                   # una fila con número y otra con UNCONTROLLED
]
FILAS = [
    ("Concatenate", "Tempo ID"),
    ("TI (Entre ParEntesis) // Shakira, Grupo Frontera", 9100001),
    ("TI FrÃ¡gil // Yahritza Y Su Esencia & Grupo Frontera", 9100002),
    ("TI Orden // Myke Towers & Bad Bunny", "9100003"),
    ("TI Gata Only // FloyyMenor, Cris Mj", 9100004),
    ("TI Otra vez (feat. J Balvin) // Zion & Lennox, J Balvin", 9100005),
    ("TI Señuelo // Alguien Más", 9100006),
    ("TI Ya Tiene // Alguien", 9100007),
    ("TI Envolver //", 9100008),
    ("TI Repetido //", 9100009),
    ("TI Contradicción // Banda", 9100010),
    ("TI Contradicción // Banda, Invitado", 9100011),
    ("TI 사람 Pt.2 (feat. IU) // SUGA & IU", 9100012),
    ("TI Uncontrolled // Nadie", "UNCONTROLLED"),
    ("TI Uncontrolled Dos // Otra Nadie", "UNCONTROLLED"),
    ("TI Numero Gana // Banda N", "UNCONTROLLED"),
    ("TI Numero Gana // Banda N", 9100014),
    ("TI Vacío // Nadie", None),
    ("TI No Existe // Nadie", 9100013),
]

sqlq("SELECT set_config('app.allow_hard_delete', 'true', false);"
     "DELETE FROM territory_tracks WHERE track_master_id IN (SELECT id FROM tracks_master WHERE track_name_raw LIKE 'TI %');"
     "DELETE FROM tracks_master WHERE track_name_raw LIKE 'TI %'")
for t, a in OBRAS:
    sqlq(f"INSERT INTO tracks_master (track_name_raw, artist_name_raw) VALUES ($${t}$$, $${a}$$)")
sqlq("UPDATE tracks_master SET tempo_id = '9199999' WHERE track_name_raw = 'TI Ya Tiene'")
# Charts de las dos versiones de "Gata Only" (Spotify y YouTube): al unificarse, la obra que queda tiene los dos.
sqlq("""INSERT INTO territory_tracks (track_master_id, pais_code, rank, platform, snapshot_date)
        SELECT id, 'AR', 1, CASE WHEN artist_name_raw = 'FloyyMenor' THEN 'youtube' ELSE 'spotify' END, '2025-01-02'
        FROM tracks_master WHERE track_name_raw = 'TI Gata Only'""")

tmp = pathlib.Path(tempfile.mkdtemp())
xlsx = tmp / "Tempos_ID.xlsx"
wb = openpyxl.Workbook()
for f in FILAS:
    wb.active.append(list(f))
wb.save(xlsx)


def cargar(simular=False):
    args = [sys.executable, str(RAIZ / "migracion" / "importar_tempo_ids.py"), "--nombre", xlsx.name] + (["--simular"] if simular else [])
    p = subprocess.run(args, input=xlsx.read_bytes(), capture_output=True, env=dict(os.environ, PGURL=PGURL))
    texto = p.stdout.decode("utf-8")
    filas = list(csv.reader(io.StringIO(texto.lstrip("﻿")), delimiter=";"))
    return p.returncode, texto, {r[1]: r for r in filas[1:]}, p.stderr.decode()


def tempo(t, a):
    return sqlq(f"SELECT coalesce(tempo_id, '-') FROM tracks_master WHERE track_name_raw = $${t}$$ AND artist_name_raw = $${a}$$ "
                "AND deleted_at IS NULL") or "(no está)"


antes = sqlq("SELECT string_agg(coalesce(tempo_id, '-'), ',' ORDER BY id) FROM tracks_master WHERE track_name_raw LIKE 'TI %'")
cod, texto, rep, resumen = cargar(simular=True)
check("simular: muestra el resultado y no cambia nada", cod == 0 and "SIMULACIÓN" in resumen and antes == sqlq(
    "SELECT string_agg(coalesce(tempo_id, '-'), ',' ORDER BY id) FROM tracks_master WHERE track_name_raw LIKE 'TI %'"), resumen)

cod, texto, rep, resumen = cargar()
check("carga: termina bien y resume", cod == 0 and "Cargadas:" in resumen and "SIMULACIÓN" not in resumen, resumen)
check("reporte para Excel: con BOM, separado por ';' y encabezados",
      texto.startswith("﻿Fila;Obra en el archivo;Tempo ID;Resultado;Coincidencia;Obra en el sistema;Detalle"), texto[:200])
r = lambda k: rep.get(k, ["", "", "", "(sin fila)", "", "", ""])
check("tildes que en el archivo son mayúsculas ('ParEntesis') y '&' en lugar de ','",
      tempo("TI (Entre Paréntesis)", "Shakira & Grupo Frontera") == "9100001" and r("TI (Entre ParEntesis) // Shakira, Grupo Frontera")[4] == "exacta",
      r("TI (Entre ParEntesis) // Shakira, Grupo Frontera"))
check("tildes mal codificadas ('FrÃ¡gil' -> 'Frágil')",
      tempo("TI Frágil", "Yahritza Y Su Esencia, Grupo Frontera") == "9100002" and "TI Frágil // Yahritza Y Su Esencia & Grupo Frontera" in rep)
check("mismos artistas en otro orden", tempo("TI Orden", "Bad Bunny, Myke Towers") == "9100003"
      and r("TI Orden // Myke Towers & Bad Bunny")[4] == "artistas en otro orden")
gata = sqlq("SELECT count(*) || '|' || min(tempo_id) || '|' || (SELECT count(*) FROM territory_tracks tt JOIN tracks_master tm "
            "ON tm.id = tt.track_master_id WHERE tm.track_name_raw = 'TI Gata Only') FROM tracks_master WHERE track_name_raw = 'TI Gata Only'")
check("la misma canción escrita distinto (Spotify con más artistas, YouTube con uno): una sola obra con el Tempo ID y los charts de ambas",
      gata == "1|9100004|2", gata)
check("título sin '(feat. ...)' y un artista en común", tempo("TI Otra vez", "Zion & Lennox") == "9100005"
      and r("TI Otra vez (feat. J Balvin) // Zion & Lennox, J Balvin")[4] == "título sin feat.")
check("mismo título con otro artista: no se carga", tempo("TI Señuelo", "Otra Persona") == "-"
      and r("TI Señuelo // Alguien Más")[3] == "NO ENCONTRADA", r("TI Señuelo // Alguien Más"))
check("una obra con otro Tempo ID: no se pisa (conflicto)", tempo("TI Ya Tiene", "Alguien") == "9199999"
      and r("TI Ya Tiene // Alguien")[3] == "CONFLICTO" and "9199999" in r("TI Ya Tiene // Alguien")[6])
check("fila sin artistas: solo por título, si hay una sola obra con ese título",
      tempo("TI Envolver", "Anitta") == "9100008" and r("TI Envolver //")[4] == "solo título"
      and tempo("TI Repetido", "Uno") == "-" and tempo("TI Repetido", "Dos") == "-" and r("TI Repetido //")[3] == "NO ENCONTRADA")
check("el archivo trae dos Tempo ID para la misma obra: no se carga ninguno",
      tempo("TI Contradicción", "Banda") == "-" and r("TI Contradicción // Banda")[3] == "CONFLICTO EN EL ARCHIVO"
      and "[conflicto en el archivo]" in r("TI Contradicción // Banda")[5], r("TI Contradicción // Banda"))
check("título en coreano", tempo("TI 사람 Pt.2", "SUGA, IU") == "9100012", r("TI 사람 Pt.2 (feat. IU) // SUGA & IU"))
check("UNCONTROLLED: se carga, también repetido en varias obras",
      tempo("TI Uncontrolled", "Nadie") == "UNCONTROLLED" and tempo("TI Uncontrolled Dos", "Otra Nadie") == "UNCONTROLLED"
      and r("TI Uncontrolled // Nadie")[3] == "CARGADO"
      and sqlq("SELECT estado_bo FROM tracks_master WHERE track_name_raw = 'TI Uncontrolled'") == "uncontrolled")
check("si la misma obra trae un Tempo ID numérico en otra fila, gana el número",
      tempo("TI Numero Gana", "Banda N") == "9100014" and r("TI Numero Gana // Banda N")[3] in ("CARGADO", "SIN CAMBIOS"))
check("fila vacía: se informa y no se carga", r("TI Vacío // Nadie")[3] == "SIN TEMPO ID")
check("un Tempo ID numérico sigue siendo de una sola obra",
      "uq_tracks_master_tempo_id" in subprocess.run(["psql", PGURL, "-c",
          "UPDATE tracks_master SET tempo_id = '9100001' WHERE track_name_raw = 'TI Señuelo'"], capture_output=True, text=True).stderr)
check("obra que no está en el sistema", r("TI No Existe // Nadie")[3] == "NO ENCONTRADA")
check("queda en el historial (Tempo IDs) con el archivo original",
      sqlq("SELECT format || '|' || updated_rows || '|' || (file_path LIKE 'tempo_ids/%')::int FROM csv_uploads "
           "WHERE filename = 'Tempos_ID.xlsx' ORDER BY id DESC LIMIT 1") == "master_tempo|10|1"
      and (pathlib.Path(os.environ["STORAGE_DIR"]) / "csv-uploads" / sqlq(
          "SELECT file_path FROM csv_uploads WHERE filename = 'Tempos_ID.xlsx' ORDER BY id DESC LIMIT 1")).read_bytes() == xlsx.read_bytes())

despues = sqlq("SELECT string_agg(track_artist_concat || '=' || coalesce(tempo_id, '-'), ',' ORDER BY track_artist_concat) "
               "FROM tracks_master WHERE track_name_raw LIKE 'TI %' AND deleted_at IS NULL")
cod, texto, rep, resumen = cargar()
check("repetir la carga no cambia nada", cod == 0 and "Cargadas:                      0" in resumen and despues == sqlq(
    "SELECT string_agg(track_artist_concat || '=' || coalesce(tempo_id, '-'), ',' ORDER BY track_artist_concat) "
    "FROM tracks_master WHERE track_name_raw LIKE 'TI %' AND deleted_at IS NULL"), resumen)

tok = httpx.post(f"{BASE}/auth/login", json={"email": "admin@prueba.local", "password": "clave-admin-123"}).json().get("access_token", "")
r2 = httpx.post(f"{BASE}/rpc/fn_cargar_tempo_ids", json={"p_filas": []}, headers={"Authorization": f"Bearer {tok}"})
check("la carga masiva no se puede llamar desde la aplicación (solo la consola)", r2.status_code in (403, 404), r2.text)

sqlq("SELECT set_config('app.allow_hard_delete', 'true', false);"
     "DELETE FROM territory_tracks WHERE track_master_id IN (SELECT id FROM tracks_master WHERE track_name_raw LIKE 'TI %');"
     "DELETE FROM tracks_master WHERE track_name_raw LIKE 'TI %'")
print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
