"""
Prueba el front REAL (front/index.html sin cambios de lógica) en Chromium contra la API propia.
Recorre lo que hace un usuario: login, carga de CSV de Spotify y de Tempo IDs, tabla principal,
edición de tempo_id, tabla por territorio, histórico de cambios, descarga de CSV, historial de
cargas con descarga del archivo guardado, reporte BO, sesión persistente y cierre de sesión.

Variables: BASE (URL de la API), PGURL (superusuario de la base).
"""
import os
import pathlib
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
        pag.wait_for_function("() => document.body.innerText.includes('Invalid login credentials')", timeout=10000)
    except Exception:
        pass
    # el 400 del login incorrecto es esperado (supabase-js también lo registra en consola)
    errores_js.clear()
    check("login incorrecto muestra el error", "Invalid login credentials" in pag.content())

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
          sqlq("select count(*) from storage.objects where name like 'spotify/%regional-ar-weekly-2026-10-08.csv'") == "1")
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
    pag.select_option("#segFilter", "bo_nunca"); pag.wait_for_timeout(300)
    check("filtro Seguimiento: nunca en un reporte BO muestra todas al principio",
          pag.locator("tbody tr").count() == total_obras, pag.locator("tbody tr").count())
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
    check("la columna Seguimiento muestra la carga del reporte BO",
          pag.locator(".seg", has_text=f"BO: carga {carga}").count() == 0  # con el filtro "nunca", ya no aparecen
          and pag.locator("tbody tr .seg").count() == 2 * (total_obras - con_tempo), pag.inner_text("tbody"))
    pag.select_option("#segFilter", "bo_ya"); pag.wait_for_timeout(300)
    check("filtro Seguimiento: ya en un reporte BO",
          pag.locator(".seg", has_text=f"BO: carga {carga}").count() == con_tempo, pag.inner_text("tbody"))
    pag.select_option("#segFilter", "")
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
          all(t in texto_manual for t in ("Carga CSV", "Cómo se ordenan los títulos", "Solo las nuevas", "Estado de trabajo automático")),
          texto_manual[:300])
    manual.close()

    # ---- historial de cargas y descarga del archivo guardado (link firmado)
    pag.click('[data-tab="history"]'); pag.wait_for_timeout(800)
    check("historial muestra las cargas", "regional-ar-weekly-2026-10-08.csv" in pag.content())
    with pag.expect_download() as d:
        pag.locator('[data-download-name="regional-ar-weekly-2026-10-08.csv"]').first.click()
    check("descargar el archivo original desde el historial",
          pathlib.Path(d.value.path()).read_text(encoding="utf-8") == spotify.read_text(encoding="utf-8"))

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
