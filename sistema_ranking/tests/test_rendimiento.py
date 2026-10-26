"""
Rendimiento con volumen real: con cientos de miles de filas de charts, la aplicación tiene que abrir, buscar, filtrar
y paginar en pocos segundos (antes tardaba minutos: traía las tablas enteras de a 1.000 filas y filtraba en el
navegador). También controla que las páginas del servidor (fn_master_pagina, fn_territory_pagina) den los mismos
resultados que las funciones originales (fn_master_view, fn_territory_view).

Variables: BASE (URL de la API), PGURL (superusuario). Usa la base de la API y la deja vacía al terminar.
"""
import os
import subprocess
import sys
import time

from playwright.sync_api import sync_playwright

BASE, PGURL = os.environ["BASE"], os.environ["PGURL"]
LIMITE_S = float(os.environ.get("LIMITE_SEGUNDOS", "3"))   # holgado: en una PC normal tarda menos de 1 s
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
    sql("TRUNCATE public.envio_obras, public.envios, public.territory_tracks, public.territory_control, public.territory_bo_report, "
        "public.territory_tempo_report, public.tracks_master, public.audit_logs, public.csv_uploads; DELETE FROM storage.objects")


vaciar()
t0 = time.time()
sql("""ALTER TABLE tracks_master DISABLE TRIGGER trg_audit_tracks_master;
INSERT INTO tracks_master (track_name_raw, artist_name_raw, tempo_id, estado_bo)
SELECT 'Tema ' || g, 'Artista ' || (g % 3000), CASE WHEN g % 3 = 0 THEN (100000 + g)::text END, 'uncontrolled'
FROM generate_series(1, 20000) g;
ALTER TABLE tracks_master ENABLE TRIGGER trg_audit_tracks_master;
INSERT INTO territory_tracks (track_master_id, tempo_id, pais_code, rank, peak_rank, previous_rank, weeks_on_chart, streams, platform, snapshot_date)
SELECT m.id, m.tempo_id, p.pais::pais_code_enum, x.r, x.r, x.r + 1, 3, 100000 - x.r, pl.plat, date '2022-01-06' + 7 * w
FROM unnest(array['AR','CL','PE','UY','PY','CO','EC','MX']) p(pais)
CROSS JOIN unnest(array['spotify','youtube']) pl(plat)
CROSS JOIN generate_series(0, 129) w
CROSS JOIN LATERAL (SELECT r, 1 + ((r * 7919 + w * 104729 + length(p.pais || pl.plat) * 31) % 20000) AS t FROM generate_series(1, 100) r) x
JOIN tracks_master m ON m.track_name_raw = 'Tema ' || x.t
ON CONFLICT DO NOTHING;
INSERT INTO territory_bo_report (track_master_id, tempo_id, pais_code, bo_id, reclamos, mech_bo)
SELECT m.id, m.tempo_id, 'AR', 'BO' || m.tempo_id, CASE WHEN m.tempo_id::int % 2 = 0 THEN 'Sí' ELSE 'No' END, 50
FROM tracks_master m WHERE m.tempo_id IS NOT NULL AND m.tempo_id::int % 7 = 0;
ANALYZE;""")
filas = int(sql("select count(*) from territory_tracks"))
print(f"Volumen de prueba: {filas} filas de charts, {sql('select count(*) from tracks_master')} canciones ({time.time() - t0:.0f} s)")

# ---- mismas respuestas que las funciones originales
for filtros in ["", "p_pais => 'AR'", "p_date_from => '2023-01-01', p_date_to => '2023-06-30'", "p_pais => 'CL', p_date_from => '2024-01-01'"]:
    a = ", " + filtros if filtros else ""
    check(f"tabla principal ({filtros or 'sin filtros'}): mismo total que fn_master_view",
          sql(f"select total from fn_master_pagina(p_limite => 1 {a})") == sql(f"select count(*) from fn_master_view({filtros})"))
    check(f"tabla por territorio ({filtros or 'sin filtros'}): mismo total que fn_territory_view",
          sql(f"select total from fn_territory_pagina(p_limite => 1 {a})") == sql(f"select count(*) from fn_territory_view({filtros})"))
pagina = sql("select string_agg(id::text, ',' order by n) from (select id, row_number() over () n from fn_master_pagina(p_limite => 100, p_offset => 100)) s")
todas = sql("select string_agg(id::text, ',') from (select id from fn_master_view() order by last_chart_date desc nulls last, track_artist_concat, id offset 100 limit 100) s")
check("tabla principal: la página 2 son las filas 101 a 200 del mismo orden", pagina == todas)
check("búsqueda por título o Tempo ID (sin distinguir mayúsculas; % y _ se buscan literalmente)",
      sql("select total from fn_master_pagina(p_buscar => 'TEMA 1234', p_limite => 1)")
      == sql("select count(*) from tracks_master where lower(track_artist_concat || ' ' || coalesce(tempo_id, '')) like '%tema 1234%'")
      and sql("select count(*) from fn_master_pagina(p_buscar => '%')") == "0")
check("filtro de reclamos en la base",
      sql("select total from fn_territory_pagina(p_reclamos => 'Sí', p_limite => 1)")
      == sql("select count(*) from fn_territory_view() where reclamos = 'Sí'"))
check("últimas cargas por territorio y plataforma",
      sql("select string_agg(pais_code || platform || snapshot_date, ',' order by 1) from fn_ultimas_cargas()")
      == sql("select string_agg(pais_code || platform || m, ',' order by 1) from (select pais_code, platform, max(snapshot_date) m "
             "from territory_tracks where deleted_at is null group by 1, 2) s"))

# ---- Panel de control con volumen real: 300.000 filas de auditoría de cargas y cambios manuales
sql("""INSERT INTO panel.acceso (email) VALUES ('admin@prueba.local') ON CONFLICT DO NOTHING;
INSERT INTO csv_uploads (filename, uploaded_by, uploaded_at, total_rows, updated_rows, format)
SELECT 'f' || g || '.csv', (SELECT id::text FROM auth.users WHERE email = 'admin@prueba.local'),
       now() - interval '80 days' + g * interval '7 minutes', 200, 200, 'spotify' FROM generate_series(1, 1500) g;
INSERT INTO audit_logs (table_name, row_id, operation, changed_by, changed_at, new_data)
SELECT 'tracks_master', gen_random_uuid(), 'INSERT', (SELECT id::text FROM auth.users WHERE email = 'admin@prueba.local'),
       now() - interval '80 days' + (g / 200) * interval '7 minutes', '{}' FROM generate_series(1, 300000) g;
ANALYZE audit_logs;""")
cab = {"Authorization": "Bearer " + __import__("httpx").post(BASE + "/auth/login", json={"email": "admin@prueba.local",
                                                                                         "password": "clave-admin-123"}).json()["access_token"]}
for ruta in ("estado", "actividad", "integridad", "usuarios"):
    t = time.time()
    r = __import__("httpx").get(f"{BASE}/panel/{ruta}", headers=cab, timeout=120)
    seg = time.time() - t
    check(f"Panel de control, {ruta}: {seg:.2f} s (máximo {LIMITE_S:.0f} s)", r.status_code == 200 and seg <= LIMITE_S, r.text[:200])
check("Panel de control: la actividad no lista los cambios de las cargas fila por fila",
      not any(a["tipo"] == "Cambio" for a in __import__("httpx").get(f"{BASE}/panel/actividad", headers=cab).json()))
sql("TRUNCATE audit_logs; DELETE FROM panel.acceso WHERE email = 'admin@prueba.local'")

# ---- tiempos en el navegador
total_obras = int(sql("select count(*) from tracks_master"))
with sync_playwright() as p:
    nav = p.chromium.launch(executable_path="/opt/pw-browsers/chromium-1194/chrome-linux/chrome")
    pag = nav.new_page()
    pag.goto(BASE + "/")
    pag.fill("#loginEmail", "admin@prueba.local"); pag.fill("#loginPass", "clave-admin-123")

    def medir(nombre, accion, condicion, extra=lambda: ""):
        t = time.time()
        accion()
        pag.wait_for_function(condicion, timeout=120000)
        seg = time.time() - t
        check(f"{nombre}: {seg:.2f} s (máximo {LIMITE_S:.0f} s)", seg <= LIMITE_S, extra())

    pie = "document.querySelector('footer') ? document.querySelector('footer').innerText : ''"
    medir("abrir: tabla principal con su total", lambda: pag.click("#loginBtn"),
          f"() => ({pie}).includes('{total_obras:,} canciones'.replace(/,/g, '.')) && document.querySelectorAll('[data-field-master]').length === 100",
          lambda: pag.inner_text("footer"))
    check("muestra 100 filas por página y el total", "1–100 de" in pag.inner_text(".pager"), pag.inner_text(".pager"))
    ident = sql("select count(*) filter (where tempo_id is not null) || '|' || count(*) filter (where tempo_id is null) from tracks_master")
    check("contador de identificadas y sin identificar, iguales a la base",
          f"Identificadas: {int(ident.split('|')[0]):,} · Sin identificar: {int(ident.split('|')[1]):,}".replace(",", ".")
          in pag.inner_text(".pager"), (ident, pag.inner_text(".pager")))
    medir("página siguiente", lambda: pag.click('.pager [data-dir="1"]'),
          "() => document.querySelector('.pager .rango').innerText.startsWith('101–200')")
    esperado = sql("select count(*) from tracks_master where lower(track_artist_concat || ' ' || coalesce(tempo_id, '')) like '%tema 1234%'")
    medir("buscar (tipeando)", lambda: pag.type("#searchMaster", "Tema 1234", delay=40),
          f"() => ({pie}).endsWith('{esperado} canciones')", lambda: pag.inner_text("footer"))
    total_t = int(sql("select count(*) from fn_territory_view()"))
    medir("abrir la tabla por territorio", lambda: pag.click('[data-tab="territory"]'),
          f"() => ({pie}).includes('{total_t:,} registros'.replace(/,/g, '.')) && document.querySelectorAll('[data-history-track]').length === 100",
          lambda: pag.inner_text("footer"))
    total_cl = sql("select count(*) from fn_territory_view(p_pais => 'CL')")
    medir("filtrar por territorio", lambda: pag.select_option("#countryFilter", "CL"),
          f"() => ({pie}).endsWith('{int(total_cl):,} registros de territorio'.replace(/,/g, '.'))", lambda: pag.inner_text("footer"))
    check("el filtro por territorio muestra solo ese territorio",
          pag.evaluate("() => [...document.querySelectorAll('tbody tr')].every(tr => tr.cells[0].innerText === 'CL')"))
    pag.select_option("#countryFilter", "")
    pag.wait_for_function(f"() => ({pie}).includes('{total_t:,} registros'.replace(/,/g, '.'))", timeout=60000)
    medir("filtrar por reclamos", lambda: pag.select_option("#reclamosFilter", "Sí"),
          f"() => ({pie}).endsWith('{int(sql(chr(10).join(['select count(*) from fn_territory_view() where reclamos = ' + chr(39) + 'Sí' + chr(39)]))):,} registros de territorio'.replace(/,/g, '.'))",
          lambda: pag.inner_text("footer"))
    pag.click('[data-tab="master"]')
    medir("cartel de descarga del reporte BO con sus cantidades", lambda: pag.click("#exportBo"),
          "() => document.querySelector('[data-envio-modo=\"todas\"]') !== null")
    nav.close()

vaciar()
print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
