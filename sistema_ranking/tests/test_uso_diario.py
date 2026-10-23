"""
Mejoras de uso diario (db/mejoras/04_uso_diario.sql, api/app.py, tempo-client.js), por HTTP y en el navegador:
  - sesiones en la base: renovación mientras se usa, vencimiento por inactividad, cierre de sesión que anula el token,
    bloqueo, cambio y restablecimiento de contraseña desde el ingreso, y mensajes en castellano;
  - carga de un archivo en una sola transacción (todo o nada), charts sin semana rechazados;
  - Tempo ID repetido: unificación de las dos obras con sus charts, reportes, controles y envíos;
  - descarga de la tabla por territorio con todos los filtros; respuestas comprimidas.

Usa sus propios usuarios y obras (no depende de los datos de otras pruebas). Variables: BASE, PGURL.
"""
import os
import pathlib
import re
import subprocess
import sys
import tempfile

import httpx
from playwright.sync_api import sync_playwright

BASE = os.environ.get("BASE", "http://localhost:8787")
PGURL = os.environ["PGURL"]
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


sqlq("""SELECT auth.set_password('diario@prueba.local', 'clave-diario-123');
        SELECT auth.set_password('diario.auditor@prueba.local', 'clave-auditor-456');
        SELECT auth.set_password('diario.olvido@prueba.local', 'clave-olvido-789');
        INSERT INTO public.app_users (user_id, app_role, oficina)
        SELECT id, CASE WHEN email LIKE 'diario.auditor%' THEN 'auditor' ELSE 'usuario_estandar' END, 'AR'
        FROM auth.users WHERE email LIKE 'diario%' ON CONFLICT (user_id) DO NOTHING""")


def ingresar(email="diario@prueba.local", clave="clave-diario-123"):
    r = httpx.post(f"{BASE}/auth/login", json={"email": email, "password": clave})
    return r, {"Authorization": "Bearer " + r.json().get("access_token", "")}


def rpc(h, fn, params):
    return httpx.post(f"{BASE}/rpc/{fn}", json=params, headers=h, timeout=60)


def leer(h):
    return httpx.get(f"{BASE}/rest/app_users", params={"select": "app_role"}, headers=h).status_code


_, h_aud = ingresar("diario.auditor@prueba.local", "clave-auditor-456")   # antes de que se frene su ingreso
# ------------------------------------------------------------------ sesiones
r = httpx.post(f"{BASE}/auth/login", json={"email": "diario@prueba.local", "password": "otra"})
check("ingreso con contraseña incorrecta: mensaje en castellano", r.json()["message"] == "El email o la contraseña no son correctos.", r.text)
r, h = ingresar()
sid = sqlq("select s.id from auth.sesiones s join auth.users u on u.id = s.user_id where u.email = 'diario@prueba.local' "
           "order by creada desc limit 1")
check("el ingreso abre una sesión en la base", r.status_code == 200 and bool(sid) and r.json()["expires_in"] > 0, r.text)
r = httpx.post(f"{BASE}/auth/renovar", headers=h)
h_nuevo = {"Authorization": "Bearer " + r.json()["access_token"]}
check("renovar da un token nuevo de la misma sesión", r.status_code == 200 and leer(h_nuevo) == 200 and leer(h) == 200, r.text)
sqlq(f"update auth.sesiones set ultimo_uso = now() - interval '9 hours' where id = '{sid}'")
r = httpx.get(f"{BASE}/rest/app_users", headers=h_nuevo)
check("vence tras SESSION_HOURS sin uso, con mensaje claro",
      r.status_code == 401 and "venció" in r.json()["message"], r.text)
check("una sesión vencida no se puede renovar", httpx.post(f"{BASE}/auth/renovar", headers=h_nuevo).status_code == 401)
_, h = ingresar()
check("cerrar sesión responde", httpx.post(f"{BASE}/auth/salir", headers=h).status_code == 204)
check("después de cerrar sesión el token ya no sirve", leer(h) == 401)
_, h = ingresar()
sqlq("update auth.users set banned_until = now() + interval '1 day' where email = 'diario@prueba.local'")
check("bloquear al usuario corta su sesión en el acto", leer(h) == 401)
sqlq("update auth.users set banned_until = null where email = 'diario@prueba.local'")

# Cambio de contraseña desde la pantalla de ingreso (sin sesión): pide la actual.
_, h = ingresar()
_, h_otra_pc = ingresar()
clave = lambda **b: httpx.post(f"{BASE}/auth/clave", json=dict(email="diario@prueba.local", **b))
r = clave(actual="equivocada", nueva="clave-diario-nueva")
check("cambiar contraseña: la actual equivocada se rechaza", r.status_code == 400 and "actual no son correctos" in r.json()["message"], r.text)
r = clave(actual="clave-diario-123", nueva="corta")
check("cambiar contraseña: mínimo 10 caracteres", r.status_code == 400 and "10 caracteres" in r.json()["message"], r.text)
r = clave(actual="clave-diario-123", nueva="clave-diario-nueva")
check("cambiar contraseña: se guarda sin haber ingresado", r.status_code == 204, r.text)
check("cambiar contraseña: cierra las sesiones abiertas", leer(h) == 401 and leer(h_otra_pc) == 401)
check("cambiar contraseña: se ingresa con la nueva y no con la anterior",
      ingresar(clave="clave-diario-nueva")[0].status_code == 200 and ingresar()[0].status_code == 400)

# Contraseña olvidada: código de un solo uso que genera quien administra el sistema.
salida = subprocess.run([sys.executable, "admin/usuarios.py", "codigo", "diario@prueba.local"], capture_output=True, text=True,
                        env=dict(os.environ, PGURL=PGURL), cwd=pathlib.Path(__file__).resolve().parents[1]).stdout
codigo = (re.search(r"([A-Z2-9]{4}-[A-Z2-9]{4})", salida) or [None, ""])[1]
check("usuarios.py codigo: genera un código XXXX-XXXX", bool(codigo) and "30 minutos" in salida, salida)
check("el código se guarda solo como hash", codigo and sqlq("select count(*) from auth.codigos_clave where codigo_hash like '%" + codigo[:4] + "%'") == "0")
_, h = ingresar(clave="clave-diario-nueva")
resto = lambda c, n="clave-restablecida-1": httpx.post(f"{BASE}/auth/restablecer", json={"email": "diario@prueba.local", "codigo": c, "nueva": n})
r = resto("AAAA-AAAA")
check("restablecer: un código equivocado se rechaza con un mensaje claro", r.status_code == 400 and "no es válido o venció" in r.json()["message"], r.text)
r = resto(codigo.lower().replace("-", " "))
check("restablecer: con el código (sin importar mayúsculas ni separador) se guarda la nueva", r.status_code == 204, r.text)
check("restablecer: se ingresa con la nueva, se cierran las sesiones y el código no sirve otra vez",
      ingresar(clave="clave-restablecida-1")[0].status_code == 200 and leer(h) == 401
      and resto(codigo, "otra-clave-12345").status_code == 400)
codigo = subprocess.run([sys.executable, "admin/usuarios.py", "codigo", "diario@prueba.local"], capture_output=True, text=True,
                        env=dict(os.environ, PGURL=PGURL), cwd=pathlib.Path(__file__).resolve().parents[1]).stdout
codigo = re.search(r"([A-Z2-9]{4}-[A-Z2-9]{4})", codigo)[1]
for _ in range(5):
    resto("BBBB-BBBB")
check("restablecer: después de 5 intentos fallidos el código deja de servir", resto(codigo).status_code in (400, 429))
sqlq("update auth.codigos_clave set intentos = 0, vence = now() - interval '1 minute'")
check("restablecer: un código vencido no sirve", resto(codigo).status_code in (400, 429))
sqlq("select auth.set_password('diario@prueba.local', 'clave-diario-123'); delete from auth.codigos_clave")
check("los ingresos correctos no cuentan como intentos fallidos", all(ingresar()[0].status_code == 200 for _ in range(10)))
for _ in range(8):
    httpx.post(f"{BASE}/auth/login", json={"email": "diario.auditor@prueba.local", "password": "mala"})
r = httpx.post(f"{BASE}/auth/login", json={"email": "diario.auditor@prueba.local", "password": "clave-auditor-456"})
check("8 intentos fallidos frenan el ingreso unos minutos", r.status_code == 429 and "intentos fallidos" in r.json()["message"], r.text)

# ------------------------------------------------------------------ carga de un archivo (todo o nada)
_, h = ingresar()
filas = [{"track_name": "Diario Uno", "artist_names": "Banda Diario", "pais_code": "UY", "rank": "1", "snapshot_date": "2025-03-06"},
         {"track_name": "Diario Dos", "artist_names": "Banda Diario", "pais_code": "UY", "rank": "2", "snapshot_date": "2025-03-06"},
         {"track_name": "Diario Tres", "artist_names": "Otra Banda", "pais_code": "UY", "rank": "3", "snapshot_date": "2025-03-06"}]
antes = sqlq("select count(*) from territory_tracks") + "|" + sqlq("select count(*) from csv_uploads")
r = rpc(h, "fn_cargar_archivo", {"p_formato": "spotify", "p_filas": filas, "p_archivo": None, "p_ruta": "x", "p_total": 3})
check("si algo falla al registrar la carga, no queda ninguna fila cargada (todo o nada)",
      r.status_code >= 400 and sqlq("select count(*) from territory_tracks") + "|" + sqlq("select count(*) from csv_uploads") == antes, r.text)
r = rpc(h, "fn_cargar_archivo", {"p_formato": "spotify", "p_filas": filas, "p_archivo": "regional-uy-weekly-2025-03-06.csv",
                                 "p_ruta": "spotify/UY/2025-03-06/x.csv", "p_total": 4, "p_errores": ["Fila sin título"]})
check("carga correcta: filas cargadas y registro en el historial con sus avisos",
      r.status_code == 200 and r.json() == {"updated": 3, "created_tracks": 3, "errors": ["Fila sin título"]}
      and sqlq("select total_rows || '|' || updated_rows || '|' || error_count || '|' || format || '|' || (uploaded_by is not null)::int "
               "from csv_uploads where filename = 'regional-uy-weekly-2025-03-06.csv'") == "4|3|1|spotify|1", r.text)
r = rpc(h_aud, "fn_cargar_archivo", {"p_formato": "spotify", "p_filas": filas[:1], "p_archivo": "a.csv", "p_ruta": "y", "p_total": 1})
check("el auditor no carga datos", r.status_code != 200 or r.json()["updated"] == 0, r.text)

# ------------------------------------------------------------------ Tempo ID repetido: unificación
uno = sqlq("select id from tracks_master where track_name_raw = 'Diario Uno'")
dos = sqlq("select id from tracks_master where track_name_raw = 'Diario Dos'")
tres = sqlq("select id from tracks_master where track_name_raw = 'Diario Tres'")
check("asignar un Tempo ID libre", rpc(h, "fn_asignar_tempo_id", {"p_track_id": uno, "p_tempo_id": "4440001"}).json() == 0)
rpc(h, "fn_cargar_archivo", {"p_formato": "bo_report", "p_pais": "UY", "p_archivo": "bo_uy.csv", "p_ruta": "z", "p_total": 1,
                             "p_filas": [{"tempo_id": "4440001", "bo_id": "BO1", "reclamos": "No", "mech_bo": "50"}]})
# La otra obra tiene charts de otra semana, el mismo chart (se descarta) y está en un envío.
sqlq(f"""insert into territory_tracks (track_master_id, pais_code, rank, platform, snapshot_date)
         values ('{dos}', 'UY', 9, 'youtube', '2025-03-13');
         insert into envios (tipo, modo, obras) values ('csv_principal', 'todas', 1);
         insert into envio_obras select max(id), '{dos}' from envios""")
r = rpc(h, "fn_asignar_tempo_id", {"p_track_id": dos, "p_tempo_id": "4440001"})
check("Tempo ID repetido sin confirmar: no cambia nada y nombra la obra que lo tiene",
      r.status_code == 409 and '"Diario Uno - Banda Diario"' in r.json()["message"]
      and sqlq(f"select coalesce(tempo_id, '-') from tracks_master where id = '{dos}'") == "-", r.text)
r = rpc(h, "fn_asignar_tempo_id", {"p_track_id": dos, "p_tempo_id": "4440001", "p_unificar": True})
check("con confirmación, las obras se unifican en la que ya tenía el Tempo ID", r.status_code == 200 and r.json() == 1
      and sqlq(f"select count(*) from tracks_master where id = '{dos}'") == "0", r.text)
check("la obra que queda tiene los charts de ambas (sin duplicar la misma semana)",
      sqlq(f"select string_agg(platform || ' ' || snapshot_date || ' ' || tempo_id, ',' order by snapshot_date) "
           f"from territory_tracks where track_master_id = '{uno}'") == "spotify 2025-03-06 4440001,youtube 2025-03-13 4440001")
check("la obra que queda conserva su reporte BO y recibe los envíos de la otra",
      sqlq(f"select count(*) from territory_bo_report where track_master_id = '{uno}'") == "1"
      and sqlq(f"select count(*) from envio_obras where track_master_id = '{uno}'") == "1")
r = rpc(h_aud, "fn_asignar_tempo_id", {"p_track_id": tres, "p_tempo_id": "4440001", "p_unificar": True})
check("el auditor no modifica ni unifica obras", r.status_code == 403 and sqlq(f"select count(*) from tracks_master where id = '{tres}'") == "1", r.text)
check("quitar el Tempo ID (vacío)", rpc(h, "fn_asignar_tempo_id", {"p_track_id": uno, "p_tempo_id": ""}).json() == 0
      and sqlq(f"select coalesce(tempo_id, '-') from tracks_master where id = '{uno}'") == "-")

# ------------------------------------------------------------------ descarga de la tabla por territorio
h_csv = dict(h, Accept="text/csv", **{"Accept-Encoding": "gzip"})
r = httpx.post(f"{BASE}/rpc/fn_territory_exportar", headers=h_csv, json={"p_pais": "UY", "p_buscar": "diario", "p_reclamos": "No"})
lineas = r.text.strip().split("\n")
check("descarga con todos los filtros de la pantalla (país, búsqueda, reclamos)",
      r.status_code == 200 and lineas[0].startswith("Pais,Track - Artista") and len(lineas) == 2
      and lineas[1].startswith("UY,Diario Uno - Banda Diario,"), r.text[:300])
check("las respuestas grandes viajan comprimidas",
      httpx.get(f"{BASE}/", headers={"Accept-Encoding": "gzip"}).headers.get("content-encoding") == "gzip")

# ------------------------------------------------------------------ en el navegador
tmp = pathlib.Path(tempfile.mkdtemp())
sin_semana = tmp / "regional-uy-weekly.csv"
sin_semana.write_text("rank,uri,artist_names,track_name,source,peak_rank,previous_rank,weeks_on_chart,streams\n"
                      "1,spotify:track:9,Banda Sin Semana,Tema Sin Semana,Sello,1,2,3,5000\n", encoding="utf-8")
with sync_playwright() as p:
    nav = p.chromium.launch(executable_path="/opt/pw-browsers/chromium-1194/chrome-linux/chrome")
    pag = nav.new_page()
    errores_js = []
    pag.on("pageerror", lambda e: errores_js.append(str(e)))
    pag.goto(BASE + "/")
    pag.fill("#loginEmail", "diario@prueba.local"); pag.fill("#loginPass", "clave-diario-123"); pag.click("#loginBtn")
    pag.wait_for_selector("#logoutBtn")

    # La sesión se renueva sola al usarse: se simula que pasó la mitad de su vigencia.
    pag.evaluate("() => { const s = JSON.parse(localStorage.getItem('rk_session')); s.renovar_desde = 1; "
                 "localStorage.setItem('rk_session', JSON.stringify(s)); }")
    pag.click('[data-tab="territory"]'); pag.wait_for_timeout(1500)
    nuevo = pag.evaluate("() => JSON.parse(localStorage.getItem('rk_session'))")
    check("la sesión se renueva sola mientras se usa la aplicación",
          nuevo["renovar_desde"] > 1 and nuevo["access_token"])

    pag.click('[data-tab="upload"]')
    pag.set_input_files("#fileInput", [str(sin_semana)])
    pag.wait_for_function("() => !document.body.innerText.includes('Procesando')", timeout=20000)
    pag.wait_for_timeout(1000)
    fila = pag.inner_text("#uploadQueue tbody tr")
    check("un chart sin la semana en el nombre no se carga (y se informa)",
          sqlq("select count(*) from tracks_master where track_name_raw = 'Tema Sin Semana'") == "0"
          and sqlq("select error_count || '|' || updated_rows || '|' || (errors ->> 0 like '%no indica la semana%')::int "
                   "from csv_uploads where filename = 'regional-uy-weekly.csv'") == "1|0|1", fila)

    pag.click("#logoutBtn"); pag.wait_for_selector("#loginEmail")
    check("cerrar sesión desde la aplicación anula la sesión en el servidor",
          httpx.get(f"{BASE}/rest/app_users", headers={"Authorization": "Bearer " + nuevo["access_token"]}).status_code == 401)

    # Contraseñas en la pantalla de ingreso.
    check("dentro de la aplicación no hay botón de contraseña (está en el ingreso)", pag.locator("#claveBtn").count() == 0)
    pag.click("#linkCambiar")
    pag.fill("#loginEmail", "diario@prueba.local"); pag.fill("#claveActual", "clave-diario-123")
    pag.fill("#claveNueva", "clave-navegador-1"); pag.fill("#claveRepetir", "otra-distinta-1")
    pag.click("#claveGuardar")
    check("cambiar contraseña: avisa si las nuevas no coinciden", "no coinciden" in pag.inner_text("#loginErr"))
    pag.fill("#claveRepetir", "clave-navegador-1"); pag.click("#claveGuardar")
    pag.wait_for_selector("#loginOk")
    check("cambiar contraseña desde el ingreso: vuelve al ingreso con el email y la nueva funciona",
          pag.input_value("#loginEmail") == "diario@prueba.local" and ingresar(clave="clave-navegador-1")[0].status_code == 200)
    pag.click("#linkOlvide")
    pag.fill("#loginEmail", "diario.olvido@prueba.local")   # usuario aparte: el freno de intentos de arriba no lo alcanza
    check("¿Olvidaste la contraseña?: indica cómo obtener el código", "administra el sistema" in pag.inner_text(".login-card"))
    pag.fill("#claveCodigo", "CCCC-CCCC"); pag.fill("#claveNueva", "clave-olvidada-1"); pag.fill("#claveRepetir", "clave-olvidada-1")
    pag.click("#claveGuardar"); pag.wait_for_function("() => document.getElementById('loginErr').innerText.length > 0")
    check("restablecer desde el ingreso: un código equivocado se informa", "no es válido" in pag.inner_text("#loginErr"))
    codigo = sqlq("select auth.generar_codigo_clave('diario.olvido@prueba.local')")
    pag.fill("#claveCodigo", codigo); pag.click("#claveGuardar"); pag.wait_for_selector("#loginOk")
    pag.fill("#loginPass", "clave-olvidada-1"); pag.click("#loginBtn")
    pag.wait_for_selector("#logoutBtn")
    check("restablecer desde el ingreso con el código y entrar con la contraseña nueva", pag.is_visible("#logoutBtn"))
    sqlq("select auth.set_password('diario@prueba.local', 'clave-diario-123')")
    check("sin errores de JavaScript", not errores_js, errores_js)
    nav.close()

print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
