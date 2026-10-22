"""
Prueba el front REAL (front/index.html sin cambios de lógica) en Chromium contra la API propia.
Recorre lo que hace un usuario: login, carga de CSV de Spotify y de Tempo IDs, tabla principal,
edición de tempo_id, tabla por territorio, histórico de cambios, descarga de CSV, historial de
cargas (solo lectura, por plataforma, país y reporte), reporte BO, sesión persistente y cierre de sesión.

Variables: BASE (URL de la API), PGURL (superusuario de la base).
"""
import os
import pathlib
import re
import subprocess
import sys
import tempfile

from playwright.sync_api import sync_playwright

BASE = os.environ.get("BASE", "http://localhost:8787")
PGURL = os.environ["PGURL"]
fallas, errores_js = [], []


def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + nombre + ("" if cond else f"  -> {extra}"))
    if not cond:
        fallas.append(nombre)


def sqlq(q):
    return subprocess.run(["psql", PGURL, "-At", "-c", q], capture_output=True, text=True, check=True).stdout.strip()


tmp = pathlib.Path(tempfile.mkdtemp())
spotify = tmp / "regional-ar-weekly-2026-10-08.csv"
spotify.write_text("rank,uri,artist_names,track_name,source,peak_rank,previous_rank,weeks_on_chart,streams\n"
                   "1,spotify:track:1,Artista Navegador,Tema Navegador,Sello,1,2,3,5000\n"
                   "2,spotify:track:2,Otro Artista,Segundo Tema,Sello,2,1,8,4000\n", encoding="utf-8")
youtube = tmp / "youtube-charts-top-songs-uy-weekly-20261001.csv"
youtube.write_text("Rank,Previous Rank,Track Name,Artist Name,Weeks on Chart,Views,Weekly Growth,YouTube URL\n"
                   "1,3,Tema Video,Artista Video,4,90000,12.5%,https://www.youtube.com/watch?v=abc\n", encoding="utf-8")
# Formato oficial de YouTube Charts (Artist Names, Periods on Chart, Growth; vistas con separador de miles).
youtube_oficial = tmp / "youtube-charts-top-songs-py-weekly-20230309.csv"
youtube_oficial.write_text("Rank,Previous Rank,Track Name,Artist Names,Periods on Chart,Views,Growth,YouTube URL\n"
                           '1,--,Tema Oficial,Artista Oficial,1,"1,234,567",N/A,https://www.youtube.com/watch?v=xyz\n', encoding="utf-8")
# Formato viejo de Spotify Charts: una línea de aviso antes de los encabezados Position, Track Name, Artist, Streams, URL.
spotify_viejo = tmp / "regional-py-weekly-2023-12-14 -ult.csv"
spotify_viejo.write_text("Note that these figures are generated using a formula that protects against any artificial inflation of streams.,,,,\n"
                         "Position,Track Name,Artist,Streams,URL\n"
                         "1,Tema Viejo,Artista Viejo,345678,https://open.spotify.com/track/abc\n", encoding="utf-8")
tempo = tmp / "tempo_ids.csv"
tempo.write_text("Track - Artista,Tempo ID\nTema Navegador - Artista Navegador,777001\n", encoding="utf-8")

with sync_playwright() as p:
    nav = p.chromium.launch(executable_path="/opt/pw-browsers/chromium-1194/chrome-linux/chrome")
    ctx = nav.new_context(accept_downloads=True)
    pag = ctx.new_page()
    pag.on("pageerror", lambda e: errores_js.append(str(e)))
    pag.on("console", lambda m: errores_js.append(m.text) if m.type == "error" else None)

    pag.goto(BASE + "/")
    pag.wait_for_selector("#loginEmail")
    check("la página carga y muestra el login", pag.is_visible("#loginBtn"))

    pag.fill("#loginEmail", "admin@prueba.local"); pag.fill("#loginPass", "incorrecta"); pag.click("#loginBtn")
    try:
        pag.wait_for_function("() => document.body.innerText.includes('El email o la contraseña no son correctos.')", timeout=10000)
    except Exception:
        pass
    # el 400 del login incorrecto es esperado (supabase-js también lo registra en consola)
    errores_js.clear()
    check("login incorrecto muestra el error", "El email o la contraseña no son correctos." in pag.content())

    pag.fill("#loginEmail", "admin@prueba.local"); pag.fill("#loginPass", "clave-admin-123"); pag.click("#loginBtn")
    pag.wait_for_selector("#logoutBtn", timeout=10000)
    check("login correcto entra al sistema", pag.is_visible("#logoutBtn"))

    # ---- carga de CSV (Spotify y Tempo IDs), en secuencia como el front
    pag.click('[data-tab="upload"]')
    pag.set_input_files("#fileInput", [str(spotify)])
    pag.wait_for_function("() => !document.body.innerText.includes('Procesando')", timeout=20000)
    pag.wait_for_timeout(1500)
    check("CSV de Spotify cargado: 2 obras con el país y la fecha del nombre del archivo",
          sqlq("select count(*) || '|' || min(pais_code) || '|' || min(snapshot_date) from territory_tracks where platform='spotify'") == "2|AR|2026-10-08")
    check("archivo de Spotify archivado en el bucket",
          sqlq("select count(*) from storage.objects where name like 'spotify/AR/%regional-ar-weekly-2026-10-08.csv'") == "1")
    guia = pag.inner_text(".upload-guide")
    check("Carga CSV indica cómo subir los charts (registro formal)",
          "subí los archivos .csv con el nombre de descarga" in guia and "acá" not in guia and "subilos" not in guia, guia)
    check("Carga CSV nombra los tipos de archivo y no lista columnas",
          all(t in guia for t in ("Spotify", "YouTube", "Reporte BackOffice", "Reporte Tempo Control", "Tempo IDs"))
          and "artist_names" not in pag.inner_text(".panel-body") and "Submitters_Song_Code" not in pag.inner_text(".panel-body"), guia)
    fila_carga = pag.inner_text("#uploadQueue tbody tr")
    check("la carga muestra cada archivo con su estado, tipo, país y semana",
          all(t in fila_carga for t in ("regional-ar-weekly-2026-10-08.csv", "Cargado", "Spotify", "AR", "2026-10-08")), fila_carga)
    pag.set_input_files("#fileInput", [str(tempo)])
    pag.wait_for_timeout(2500)
    check("CSV de Tempo IDs cargado", sqlq("select tempo_id from tracks_master where track_name_clean='Tema Navegador'") == "777001")

    # ---- tabla principal: se ven las obras y se edita un tempo_id
    pag.click('[data-tab="master"]'); pag.wait_for_timeout(1000)
    check("tabla principal muestra las obras cargadas", "Tema Navegador - Artista Navegador" in pag.content())

    campo = pag.locator('[data-field-master="tempo_id"][value=""]').first
    campo.fill("777002"); campo.press("Tab"); pag.wait_for_timeout(1500)
    check("editar tempo_id desde la tabla (fn_set_tempo_id)", sqlq("select tempo_id from tracks_master where track_name_clean='Segundo Tema'") == "777002")

    pag.click('[data-tab="upload"]')
    # YouTube se carga a mano, igual que Spotify (no hay carga automática)
    pag.set_input_files("#fileInput", [str(youtube)])
    pag.wait_for_function("() => !document.body.innerText.includes('Procesando')", timeout=20000)
    pag.wait_for_timeout(1500)
    check("CSV de YouTube cargado a mano: país y fecha del nombre del archivo",
          sqlq("select count(*) || '|' || min(pais_code) || '|' || min(snapshot_date) || '|' || min(streams) from territory_tracks where platform='youtube'")
          == "1|UY|2026-10-01|90000")
    pag.click('[data-tab="master"]'); pag.wait_for_timeout(1000)

    # ---- fecha de última carga: por país (cada país se carga en otro momento)
    def ultima_carga():
        return "\n".join(l.strip() for l in pag.inner_text("#lastLoads").splitlines() if l.strip())
    check("con todos los países pide elegir uno para ver la fecha",
          ultima_carga() == "Seleccionar país para ver fecha de última carga", ultima_carga())
    check("el pie de página ya no menciona Supabase", "Supabase" not in pag.inner_text("footer"), pag.inner_text("footer"))
    pag.select_option("#masterCountry", "AR"); pag.wait_for_timeout(1500)
    check("país AR: fecha de Spotify de AR y YouTube sin cargas",
          ultima_carga() == "Último Spotify cargado (AR): 2026-10-08\nÚltimo YouTube cargado (AR): —", ultima_carga())
    pag.select_option("#masterCountry", "UY"); pag.wait_for_timeout(1500)
    check("país UY: fecha de YouTube de UY y Spotify sin cargas",
          ultima_carga() == "Último Spotify cargado (UY): —\nÚltimo YouTube cargado (UY): 2026-10-01", ultima_carga())
    pag.click('[data-tab="history"]'); pag.wait_for_timeout(500)
    check("en Historial se ven las fechas del último país elegido", "(UY): 2026-10-01" in ultima_carga(), ultima_carga())
    pag.click('[data-tab="territory"]'); pag.wait_for_timeout(500)
    check("en la tabla por territorio, sin país elegido, pide elegir uno",
          ultima_carga() == "Seleccionar país para ver fecha de última carga", ultima_carga())
    pag.click('[data-tab="master"]'); pag.select_option("#masterCountry", ""); pag.wait_for_timeout(1500)

    # ---- nombres de archivo de los charts: país, semana y plataforma salen del nombre
    nombres = {
        "regional-ar-weekly-2021-01-07.csv": ["AR", "2021-01-07", "spotify"],
        "regional-py-weekly-2023-12-14 -ult.csv": ["PY", "2023-12-14", "spotify"],
        "youtube-py-weekly-2023-03-09.csv": ["PY", "2023-03-09", "youtube"],
        "youtube-TopSongs-ar-weekly-2021-01-07.csv": ["AR", "2021-01-07", "youtube"],
        "regional-ar-weekly-2024-07-04.csv": ["AR", "2024-07-04", "spotify"],
        "youtube-charts-top-songs-py-weekly-20230309": ["PY", "2023-03-09", "youtube"],
        "youtube-charts-top-songs-py-weekly-20230309.csv": ["PY", "2023-03-09", "youtube"],
    }
    leidos = pag.evaluate("""(nombres) => Object.fromEntries(nombres.map(n => [n, [
        detectCountryFromFilename(n) || detectCountry(n), detectDateFromFilename(n),
        detectFormat({ track_name: 'x', artist_names: 'y' }, n)]]))""", list(nombres))
    for n, esperado in nombres.items():
        check(f"nombre de chart '{n}': país, semana y plataforma", leidos[n] == esperado, leidos[n])

    # ---- formatos de chart: el oficial de YouTube y el viejo de Spotify (con aviso arriba)
    pag.click('[data-tab="upload"]')
    pag.set_input_files("#fileInput", [str(youtube_oficial), str(spotify_viejo)])
    pag.wait_for_function("() => !document.body.innerText.includes('Procesando')", timeout=20000)
    pag.wait_for_timeout(1500)
    fila = ("select t.platform || '|' || t.pais_code || '|' || t.snapshot_date || '|' || t.rank || '|' || coalesce(t.previous_rank::text, '-') "
            "|| '|' || t.streams || '|' || coalesce(t.weeks_on_chart::text, '-') || '|' || coalesce(t.uri, '-') "
            "from territory_tracks t join tracks_master m on m.id = t.track_master_id where m.track_name_clean = ")
    check("YouTube formato oficial: Artist Names, Periods on Chart y vistas \"1,234,567\"",
          sqlq(fila + "'Tema Oficial'") == "youtube|PY|2023-03-09|1|-|1234567|1|https://www.youtube.com/watch?v=xyz"
          and sqlq("select artist_name_clean from tracks_master where track_name_clean = 'Tema Oficial'") == "Artista Oficial",
          sqlq(fila + "'Tema Oficial'"))
    check("Spotify formato viejo (aviso arriba; Position, Artist, URL) con nombre '... -ult.csv'",
          sqlq(fila + "'Tema Viejo'") == "spotify|PY|2023-12-14|1|-|345678|-|https://open.spotify.com/track/abc"
          and sqlq("select artist_name_clean from tracks_master where track_name_clean = 'Tema Viejo'") == "Artista Viejo",
          sqlq(fila + "'Tema Viejo'"))
    check("los dos archivos cargados sin errores", pag.inner_text(".metric.ok .n").strip() == "2"
          and pag.inner_text(".metric.err .n").strip() == "0", pag.inner_text(".summary-row"))
    pag.click('[data-tab="master"]'); pag.wait_for_timeout(1000)

    # ---- descarga de la tabla principal: elige "solo las nuevas" o "todas" y queda registrada
    total_obras = int(sqlq("select count(*) from tracks_master where deleted_at is null"))
    pag.click("#exportMaster"); pag.wait_for_selector('[data-envio-modo="nuevas"]')
    check("Descargar CSV pregunta nuevas o todas, con la cantidad de cada una",
          f"Solo las nuevas · {total_obras} obras" in pag.inner_text(".modal") and f"Todas · {total_obras} obras" in pag.inner_text(".modal"),
          pag.inner_text(".modal"))
    with pag.expect_download() as d:
        pag.click('[data-envio-modo="nuevas"]')
    contenido = pathlib.Path(d.value.path()).read_text(encoding="utf-8")
    check("descarga CSV de la tabla principal (solo nuevas = todas la primera vez)",
          contenido.startswith("track_artist_concat,tempo_id") and "777001" in contenido
          and len(contenido.strip().splitlines()) == total_obras + 1 and d.value.suggested_filename == "tabla_principal_nuevas.csv",
          (d.value.suggested_filename, contenido[:300]))
    pag.wait_for_timeout(1000)
    check("la descarga del CSV queda en el historial y marca las obras",
          sqlq("select count(*) from csv_uploads where format='csv_principal' and file_path like 'csv_principal/%'") == "1"
          and pag.locator(".seg", has_text="CSV: nunca").count() == 0, sqlq("select count(*) from csv_uploads where format='csv_principal'"))
    pag.click("#exportMaster"); pag.wait_for_selector('[data-envio-modo="nuevas"]')
    check("después ya no hay nuevas para el CSV (la opción queda apagada) y muestra la última descarga",
          pag.is_disabled('[data-envio-modo="nuevas"]') and "Solo las nuevas · 0 obras" in pag.inner_text(".modal")
          and "solo nuevas" in pag.inner_text(".modal"), pag.inner_text(".modal"))
    pag.click("#closeEnvio")

    # ---- tabla por territorio + histórico
    sqlq("select fn_upsert_bo_report_row('777001','AR','00123','C','ok','',50)")
    pag.click('[data-tab="territory"]'); pag.wait_for_timeout(1000)
    check("tabla por territorio muestra la obra", "Tema Navegador" in pag.content())
    pag.locator('[data-history-track]').first.click(); pag.wait_for_selector("#closeHistory", timeout=5000)
    check("histórico de cambios abre", pag.is_visible("#closeHistory"))
    pag.click("#closeHistory")

    # ---- reporte BO: solo las nuevas (contador + descarga + copia en el bucket + seguimiento)
    pag.click('[data-tab="master"]'); pag.wait_for_timeout(800)
    con_tempo = int(sqlq("select count(*) from tracks_master where deleted_at is null and tempo_id ~ '^[0-9]+$'"))
    check("la barra de la tabla principal no tiene un desplegable de seguimiento (se elige al descargar)",
          pag.locator("#segFilter").count() == 0)
    pag.click("#exportBo"); pag.wait_for_selector('[data-envio-modo="nuevas"]')
    with pag.expect_download() as d:
        pag.click('[data-envio-modo="nuevas"]')
    bo = pathlib.Path(d.value.path()).read_text(encoding="utf-8")
    carga = sqlq("select counter from bo_export_counter")
    check("reporte BO (nuevas) con número de carga y solo obras con Tempo ID",
          d.value.suggested_filename == f"reporte_bo_carga{carga}_nuevas.csv" and "777001;" in bo
          and len(bo.strip().splitlines()) == con_tempo and all(l.endswith(f";BOcarga{carga}") for l in bo.splitlines()),
          (d.value.suggested_filename, bo[:200]))
    pag.wait_for_timeout(1000)
    check("copia del reporte BO guardada y registrada",
          sqlq("select count(*) from csv_uploads where format='bo_generado' and file_path like 'bo_generado/%'") == "1")
    check("la columna Seguimiento muestra la carga del reporte BO (y 'nunca' en las que no salieron)",
          pag.locator(".seg", has_text=f"BO: carga {carga}").count() == con_tempo
          and pag.locator(".seg", has_text="BO: nunca").count() == total_obras - con_tempo, pag.inner_text("tbody"))
    pag.click("#exportBo"); pag.wait_for_selector('[data-envio-modo="todas"]')
    check("reporte BO: sin nuevas, 'solo las nuevas' queda apagada", pag.is_disabled('[data-envio-modo="nuevas"]'), pag.inner_text(".modal"))
    with pag.expect_download() as d:
        pag.click('[data-envio-modo="todas"]')
    bo2 = pathlib.Path(d.value.path()).read_text(encoding="utf-8")
    check("reporte BO (todas, revisión completa): vuelve a incluir todo con la carga siguiente",
          d.value.suggested_filename == f"reporte_bo_carga{int(carga) + 1}.csv" and len(bo2.strip().splitlines()) == con_tempo,
          (d.value.suggested_filename, bo2[:200]))
    pag.wait_for_timeout(800)

    # ---- manual de uso
    check("el enlace al manual está arriba", pag.get_attribute("#manualLink", "href") == "manual.html")
    manual = ctx.new_page(); manual.goto(BASE + "/manual.html")
    texto_manual = manual.inner_text("main")
    check("el manual explica cargas, limpieza de títulos, nuevas/todas y estado de trabajo",
          all(t in texto_manual for t in ("Carga CSV", "Normalización de títulos", "Solo las nuevas", "Estado de trabajo automático",
                                          "Nombres de los charts", "youtube-TopSongs-ar-weekly-2021-01-07.csv",
                                          "Historial de cargas", "carácter informativo", "Reporte Tempo Control",
                                          "Respaldo en OneDrive", "no altera la información")),
          texto_manual[:300])
    manual.close()

    # ---- historial de cargas: solo lectura, por plataforma y país, y por reporte
    pag.click('[data-tab="history"]'); pag.wait_for_selector(".subtab", timeout=10000)
    check("la pestaña se llama Historial de cargas", pag.inner_text('[data-tab="history"]').strip() == "Historial de cargas")
    subtabs = pag.locator(".subtab").all_inner_texts()
    check("el historial se divide en YouTube, Spotify, Reportes BackOffice y Reportes Tempo Control",
          [re.sub(r"\d+$", "", t).strip() for t in subtabs] == ["YouTube", "Spotify", "Reportes BackOffice", "Reportes Tempo Control"], subtabs)
    def panel():
        return pag.inner_text(".panel-body")
    check("el historial no tiene la nota redundante de solo lectura", "Solo lectura" not in panel(), panel()[:200])
    check("el historial es solo informativo: sin descargas ni borrados",
          pag.locator(".panel-body button", has_text="Descargar").count() == 0
          and pag.locator(".panel-body button", has_text="Eliminar").count() == 0)
    pag.click('[data-hist-tab="spotify"]'); pag.wait_for_timeout(300)
    check("Spotify, todos los países: resumen por país (semanas cargadas)",
          pag.locator('tr[data-hist-pais="AR"]').count() == 1 and pag.locator('tr[data-hist-pais="PY"]').count() == 1
          and pag.is_disabled('.chip[data-hist-pais="CL"]'), panel()[:600])
    pag.click('.chip[data-hist-pais="AR"]'); pag.wait_for_timeout(300)
    fila = pag.inner_text(".panel-body tbody tr")
    check("Spotify AR: cada semana con sus canciones, el archivo del que salió y quién lo cargó",
          all(t in fila for t in ("2026-10-08", "2", "regional-ar-weekly-2026-10-08.csv", "admin")), fila)
    pag.click('[data-hist-tab="youtube"]'); pag.wait_for_timeout(300)
    pag.click('.chip[data-hist-pais="PY"]'); pag.wait_for_timeout(300)
    check("YouTube PY: la semana y el archivo oficial de YouTube",
          "2023-03-09" in panel() and "youtube-charts-top-songs-py-weekly-20230309.csv" in panel(), panel()[:600])
    pag.click('[data-hist-tab="bo"]'); pag.wait_for_timeout(300)
    check("Reportes BackOffice: obras con datos de BO por país", "AR\t1" in panel() and "obras con datos del reporte backoffice" in panel().lower(),
          panel()[:600])
    pag.click('[data-hist-tab="tempo"]'); pag.wait_for_timeout(300)
    check("Reportes Tempo Control: obras con Tempo ID y la carga de Tempo IDs",
          "Obras de la tabla principal con Tempo ID: 2" in panel() and "tempo_ids.csv" in panel() and "Tempo IDs" in panel(), panel()[:600])
    todo = "".join(pag.click(f'[data-hist-tab="{k}"]') or panel() for k in ("youtube", "spotify", "bo", "tempo"))
    check("las descargas (reporte BO y CSV generados) no aparecen como cargas",
          "reporte_bo_carga" not in todo and "tabla_principal" not in todo)

    # ---- sesión persistente y cierre
    pag.reload(); pag.wait_for_selector("#logoutBtn", timeout=10000)
    check("al recargar la página sigue la sesión", pag.is_visible("#logoutBtn"))
    pag.click("#logoutBtn"); pag.wait_for_selector("#loginEmail", timeout=5000)
    check("cerrar sesión vuelve al login", pag.is_visible("#loginEmail"))

    # ---- usuario auditor: solo lectura (sin pestaña de carga habilitada)
    pag.fill("#loginEmail", "auditor@prueba.local"); pag.fill("#loginPass", "clave-auditor-123"); pag.click("#loginBtn")
    pag.wait_for_selector("#logoutBtn", timeout=10000)
    pag.click('[data-tab="master"]'); pag.wait_for_timeout(1000)
    check("auditor entra y ve la tabla principal en solo lectura",
          "Tema Navegador" in pag.content() and pag.locator('[data-field-master="tempo_id"]').count() == 0)
    nav.close()

reales = [e for e in errores_js if "fonts.g" not in e and "net::ERR" not in e]
check("sin errores de JavaScript en la página", not reales, reales[:5])
print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
