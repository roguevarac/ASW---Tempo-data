"""
Carga masiva de charts históricos (migracion/importar_charts.py, "bash ranking.sh cargar-historicos").

1. Paridad con el front: los mismos archivos cargados por "Carga CSV" en el navegador real y por el importador dejan
   la base igual (canciones, semanas, posiciones, streams, errores por archivo).
2. Lo propio de la carga masiva: país tomado de la carpeta, archivos sin semana que no se cargan, archivos que no son
   charts, retomar sin duplicar, y que el espejo no vuelva a copiar a OneDrive lo que vino de ahí.

Variables: BASE (URL de la API), PGURL (superusuario), STORAGE_DIR (el de la API). Ver tests/correr_todo.sh.
"""
import os
import pathlib
import subprocess
import sys
import tempfile

from playwright.sync_api import sync_playwright

RAIZ = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RAIZ / "migracion"))
sys.path.insert(0, str(RAIZ / "api"))
import importar_charts  # noqa: E402
import espejo  # noqa: E402

BASE, PGURL, STORAGE_DIR = os.environ["BASE"], os.environ["PGURL"], os.environ["STORAGE_DIR"]
fallas = []


def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + nombre + ("" if cond else f"  -> {extra}"))
    if not cond:
        fallas.append(nombre)


def sql(q):
    r = subprocess.run(["psql", PGURL, "-At", "-F", "|", "-c", q], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(r.stderr)
    return r.stdout.strip()


def vaciar():
    sql("TRUNCATE public.envio_identificadas, public.envio_obras, public.envios, public.territory_tracks, public.territory_control, public.territory_bo_report, "
        "public.territory_tempo_report, public.tracks_master, public.audit_logs, public.csv_uploads; DELETE FROM storage.objects")


def foto():
    """Lo cargado, comparable entre las dos vías (sin ids, fechas de carga ni orden de llegada)."""
    charts = sql("select string_agg(x, E'\\n' order by x) from (select concat_ws('|', m.track_name_clean, m.artist_name_clean, "
                 "m.track_artist_concat, t.pais_code, t.snapshot_date, t.platform, t.rank, t.peak_rank, t.previous_rank, "
                 "t.weeks_on_chart, t.streams, t.source, t.uri, t.weekly_growth) x from territory_tracks t "
                 "join tracks_master m on m.id = t.track_master_id) s")
    archivos = sql("select string_agg(x, E'\\n' order by x) from (select concat_ws('|', filename, format, total_rows, "
                   "updated_rows, error_count, errors::text) x from csv_uploads) s")
    obras = sql("select count(*) from tracks_master")
    return charts, archivos, obras


tmp = pathlib.Path(tempfile.mkdtemp())
od = tmp / "OneDrive - Sony" / "RANKING DIGITAL REGIONAL"
sp, yt = od / "Spotify Charts", od / "Youtube Charts"


def escribir(ruta, texto, codificacion="utf-8"):
    ruta.parent.mkdir(parents=True, exist_ok=True)
    ruta.write_bytes(texto.encode(codificacion))
    return ruta


HEAD_SP = "rank,uri,artist_names,track_name,source,peak_rank,previous_rank,weeks_on_chart,streams\n"
HEAD_YT = "Rank,Previous Rank,Track Name,Artist Name,Weeks on Chart,Views,Weekly Growth,YouTube URL\n"
paridad = [
    escribir(sp / "ar" / "regional-ar-weekly-2021-01-07.csv", HEAD_SP +
             '1,spotify:track:1,Artista A & Artista B,"Canción, con coma (En Vivo)",Sello,1,2,3,"1,234,567"\n'
             "2,spotify:track:2,Otro,¿Qué Pasó? [Live Session],Sello,2,1,8,4000\n"
             ",spotify:track:3,Sin Titulo,,Sello,,,,\n"),
    escribir(sp / "PY" / "regional-py-weekly-2023-12-14 -ult.csv",
             "Note that these figures are generated using a formula that protects against any artificial inflation of streams.,,,,\n"
             "Position,Track Name,Artist,Streams,URL\n"
             "1,Tema Viejo - Live at Luna Park,Artista Viejo,345678,https://open.spotify.com/track/abc\n"
             "2,Canción, Otro\n"),
    escribir(sp / "ar" / "regional-ar-weekly-2024-07-04.csv", HEAD_SP +
             "1,spotify:track:9,Niño Ñandú,Corazón,Sello,1,1,1,1.234.567\n", "cp1252"),
    escribir(yt / "py" / "youtube-py-weekly-2023-03-09.csv", HEAD_YT +
             '1,--,Video Uno,Artista Video,4,"90,000",12.5%,https://www.youtube.com/watch?v=1\n'
             "2,3,Video Sin Artista,,1,5000,-3%,https://www.youtube.com/watch?v=2\n"),
    escribir(yt / "ar" / "youtube-TopSongs-ar-weekly-2021-01-07.csv",
             "﻿Rank;Previous Rank;Track Name;Artist Name;Weeks on Chart;Views;Weekly Growth;YouTube URL\n"
             "1;2;Canción;Artista A & Artista B;5;123456;1,5%;https://youtu.be/x\n"),
    escribir(yt / "py" / "youtube-charts-top-songs-py-weekly-20230309.csv",
             "Rank,Previous Rank,Track Name,Artist Names,Periods on Chart,Views,Growth,YouTube URL\n"
             '1,NEW,Tema Oficial,Artista Oficial,1,"1,234,567",N/A,https://www.youtube.com/watch?v=xyz\n'),
]
# Solo para la carga masiva.
sin_pais = escribir(sp / "uy" / "regional-global-weekly-2022-05-05.csv", HEAD_SP + "1,spotify:track:u,Art UY,Tema UY,S,1,1,1,10\n")
sin_fecha = escribir(yt / "cl" / "youtube-cl-weekly.csv", HEAD_YT + "1,1,Tema CL,Art CL,1,10,1%,https://youtu.be/c\n")
escribir(sp / "notas.txt", "no es un csv")
escribir(sp / "desktop.ini", "[.ShellClassInfo]")
no_chart = escribir(sp / "ar" / "tempo_ids.csv", "track_artist_concat,tempo_id\nTema - Artista,123\n")

# ---------------------------------------------------------------- 1. paridad con el front real
vaciar()
with sync_playwright() as p:
    nav = p.chromium.launch(executable_path="/opt/pw-browsers/chromium-1194/chrome-linux/chrome")
    pag = nav.new_page()
    pag.goto(BASE + "/")
    pag.fill("#loginEmail", "admin@prueba.local"); pag.fill("#loginPass", "clave-admin-123"); pag.click("#loginBtn")
    pag.wait_for_selector("#logoutBtn", timeout=10000)
    pag.click('[data-tab="upload"]')
    pag.set_input_files("#fileInput", [str(f) for f in paridad])
    pag.wait_for_function("() => document.body.innerText.includes('Carga finalizada')", timeout=60000)
    pag.wait_for_timeout(1000)
    nav.close()
por_front = foto()
check(f"el front cargó los 6 charts de prueba ({len(por_front[0].splitlines())} filas de chart, {por_front[2]} canciones)", por_front[1].count("\n") == 5 and len(por_front[0].splitlines()) == 9, por_front[1])

vaciar()
res, problemas, avisos = importar_charts.importar(PGURL, STORAGE_DIR, [str(sp), str(yt)], salida=lambda *_: None)
# Solo los archivos que también cargó el front.
nombres = {f.name for f in paridad}
por_import = foto()
archivos_import = "\n".join(l for l in por_import[1].splitlines() if l.split("|")[0] in nombres)
charts_import = "\n".join(l for l in por_import[0].splitlines()
                          if not l.startswith(("Tema UY|",)))
check("paridad: mismas canciones, semanas, posiciones, streams y crecimiento que Carga CSV",
      charts_import == por_front[0], "\n".join(sorted(set(charts_import.splitlines()) ^ set(por_front[0].splitlines()))))
check("paridad: mismo resultado por archivo (filas, cargadas, errores y mensajes)",
      archivos_import == por_front[1], "\n".join(sorted(set(archivos_import.splitlines()) ^ set(por_front[1].splitlines()))))

# ---------------------------------------------------------------- 2. lo propio de la carga masiva
check("sin país en el nombre: toma el país de la carpeta (uy/)",
      sql("select t.pais_code || '|' || t.snapshot_date from territory_tracks t join tracks_master m on m.id = t.track_master_id "
          "where m.track_name_clean = 'Tema UY'") == "UY|2022-05-05")
check("sin semana en el nombre: no se carga (no usa la fecha del día) y queda registrado con el motivo",
      sql("select count(*) from tracks_master where track_name_clean = 'Tema CL'") == "0"
      and "no indica la semana" in sql("select errors::text from csv_uploads where filename = 'youtube-cl-weekly.csv'")
      and any("youtube-cl-weekly.csv" in x for x in problemas), problemas)
check("lo que no es un chart se informa y no se carga; .txt y desktop.ini se ignoran",
      any("tempo_ids.csv" in x and "No es un chart" in x for x in problemas)
      and sql("select count(*) from csv_uploads where filename in ('tempo_ids.csv', 'notas.txt', 'desktop.ini')") == "0", problemas)
check("resumen: 7 archivos cargados (1 con una fila sin título), 2 no cargados (sin semana y no chart)",
      res["cargados"] + res["con_errores"] == 7 and res["con_errores"] == 1 and res["no_cargados"] == 2 and res["ya_importados"] == 0, res)
filas = sql("select file_path || '|' || uploaded_by from csv_uploads where filename = 'regional-ar-weekly-2021-01-07.csv'")
check("cada archivo queda en el sistema como 'importación histórica', en <plataforma>/<PAÍS>/importado-onedrive/",
      filas.startswith("spotify/AR/importado-onedrive/") and filas.endswith("|importación histórica"), filas)
guardado = pathlib.Path(STORAGE_DIR) / "csv-uploads" / filas.split("|")[0]
check("el archivo guardado es idéntico al original", guardado.read_bytes() == paridad[0].read_bytes())
cargas = [dict(zip(("filename", "file_path", "format", "updated_rows"), l.split("|")))
          for l in sql("select filename, file_path, format, updated_rows from csv_uploads").splitlines()]
for c in cargas:
    c["updated_rows"] = int(c["updated_rows"])
check("el espejo no vuelve a copiar a OneDrive lo que vino de ahí",
      all(espejo.destino(c, od) is None for c in cargas), [c for c in cargas if espejo.destino(c, od)])
antes = foto()
res2, _, _ = importar_charts.importar(PGURL, STORAGE_DIR, [str(sp), str(yt)], salida=lambda *_: None)
check("volver a correrlo no duplica nada (retoma: saltea lo ya importado)",
      res2["ya_importados"] == 8 and foto() == antes, res2)

# ---------------------------------------------------------------- 3. en la aplicación
with sync_playwright() as p:
    nav = p.chromium.launch(executable_path="/opt/pw-browsers/chromium-1194/chrome-linux/chrome")
    pag = nav.new_page()
    pag.goto(BASE + "/")
    pag.fill("#loginEmail", "admin@prueba.local"); pag.fill("#loginPass", "clave-admin-123"); pag.click("#loginBtn")
    pag.wait_for_selector("#logoutBtn", timeout=10000)
    pag.click('[data-tab="history"]'); pag.wait_for_selector(".subtab", timeout=10000)
    pag.click('[data-hist-tab="spotify"]'); pag.click('.chip[data-hist-pais="AR"]'); pag.wait_for_timeout(400)
    texto = pag.inner_text(".panel-body")
    check("Historial de cargas: cada semana importada con su archivo y 'importación histórica' como usuario",
          "2021-01-07" in texto and "regional-ar-weekly-2024-07-04.csv" in texto and "importación histórica" in texto, texto[:500])
    nav.close()

vaciar()
print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
