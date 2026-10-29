"""
Panel de control (db/mejoras/05_panel.sql, /panel/* de api/app.py, pestaña "Panel de control" del front):
  - acceso: solo las personas de panel.acceso; cualquier otro usuario recibe 403 en cada pedido y no ve la pestaña;
  - usuarios: alta con código de activación, rol, bloqueo (no el propio), código de contraseña, cierre de sesiones;
  - actividad: ingresos, cargas, descargas y cambios manuales; integridad: semanas faltantes y archivos faltantes;
  - estado, eventos, "Respaldar ahora" (queda pedido) y registro del servidor; y lo mismo en el navegador.

Usa sus propios usuarios y datos. Variables: BASE, PGURL, STORAGE_DIR (el de la API).
"""
import json
import os
import pathlib
import subprocess
import sys

import httpx
from playwright.sync_api import sync_playwright

BASE = os.environ.get("BASE", "http://localhost:8787")
PGURL = os.environ["PGURL"]
STORAGE = pathlib.Path(os.environ["STORAGE_DIR"])
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


sqlq("""SELECT auth.set_password('panel@prueba.local', 'clave-panel-123');
        SELECT auth.set_password('comun.panel@prueba.local', 'clave-comun-123');
        INSERT INTO public.app_users (user_id, app_role, oficina)
        SELECT id, CASE WHEN email = 'panel@prueba.local' THEN 'admin' ELSE 'usuario_estandar' END, 'AR'
        FROM auth.users WHERE email IN ('panel@prueba.local', 'comun.panel@prueba.local') ON CONFLICT (user_id) DO NOTHING;
        INSERT INTO panel.acceso (email) VALUES ('panel@prueba.local') ON CONFLICT DO NOTHING""")


def ingresar(email, clave):
    r = httpx.post(f"{BASE}/auth/login", json={"email": email, "password": clave})
    return {"Authorization": "Bearer " + r.json().get("access_token", "")}


h = ingresar("panel@prueba.local", "clave-panel-123")
comun = ingresar("comun.panel@prueba.local", "clave-comun-123")
get = lambda ruta, cab=h, **p: httpx.get(f"{BASE}/panel/{ruta}", headers=cab, params=p, timeout=60)
post = lambda ruta, cuerpo=None, cab=h: httpx.post(f"{BASE}/panel/{ruta}", headers=cab, json=cuerpo or {}, timeout=60)

# ------------------------------------------------------------------ acceso
check("acceso: la persona del panel lo tiene", get("acceso").json() == {"acceso": True})
check("acceso: un usuario común no", get("acceso", comun).json() == {"acceso": False})
rechazos = [get(r, comun).status_code for r in ("estado", "eventos", "registro", "usuarios", "actividad", "integridad")]
rechazos += [post("usuarios", {"accion": "codigo", "email": "panel@prueba.local"}, comun).status_code,
             post("respaldo", None, comun).status_code]
check("un usuario común recibe 403 en cada pedido del panel", set(rechazos) == {403}, rechazos)
check("sin sesión: 401", httpx.get(f"{BASE}/panel/estado").status_code == 401)
r = httpx.post(f"{BASE}/rpc/fn_x", headers=comun)
check("las funciones del panel no se pueden llamar por /rpc (solo fn_ públicas)", r.status_code == 404, r.text)
check("las tablas del panel no se pueden leer directamente",
      httpx.get(f"{BASE}/rest/acceso", headers=comun).status_code >= 400)
check("el acceso queda dado por defecto a rocio.guevara@sonymusicpub.com",
      sqlq("select count(*) from panel.acceso where email = 'rocio.guevara@sonymusicpub.com'") == "1")

# ------------------------------------------------------------------ usuarios
r = post("usuarios", {"accion": "crear", "email": "Nueva.Persona@Prueba.local", "rol": "usuario_estandar", "oficina": "CL"})
codigo = r.json().get("resultado", "")
check("alta de usuario: devuelve un código de activación", r.status_code == 200 and len(codigo) == 9 and codigo[4] == "-", r.text)
usuarios = {u["email"]: u for u in get("usuarios").json()}
nueva = usuarios.get("nueva.persona@prueba.local", {})
check("el usuario nuevo figura sin activar, con su rol y oficina",
      nueva.get("sin_clave") and nueva.get("rol") == "usuario_estandar" and nueva.get("oficina") == "CL" and nueva.get("codigo_vence"), nueva)
check("el usuario nuevo no puede ingresar hasta elegir su contraseña",
      httpx.post(f"{BASE}/auth/login", json={"email": "nueva.persona@prueba.local", "password": ""}).status_code == 400)
r = httpx.post(f"{BASE}/auth/restablecer", json={"email": "nueva.persona@prueba.local", "codigo": codigo, "nueva": "clave-nueva-persona"})
check("con el código elige su contraseña e ingresa", r.status_code == 204
      and httpx.post(f"{BASE}/auth/login", json={"email": "nueva.persona@prueba.local", "password": "clave-nueva-persona"}).status_code == 200, r.text)
check("alta repetida: mensaje claro", "Ya existe" in post("usuarios", {"accion": "crear", "email": "nueva.persona@prueba.local",
                                                                       "rol": "auditor"}).json()["message"])
check("alta con email inválido: se rechaza", post("usuarios", {"accion": "crear", "email": "sin-arroba", "rol": "auditor"}).status_code == 400)
r = post("usuarios", {"accion": "rol", "email": "nueva.persona@prueba.local", "rol": "auditor", "oficina": "PE"})
check("cambio de rol y oficina", r.status_code == 200 and sqlq(
    "select app_role || '|' || oficina from app_users a join auth.users u on u.id = a.user_id where u.email = 'nueva.persona@prueba.local'") == "auditor|PE", r.text)
h_nueva = ingresar("nueva.persona@prueba.local", "clave-nueva-persona")
r = post("usuarios", {"accion": "bloquear", "email": "nueva.persona@prueba.local"})
check("bloquear: corta su sesión y no puede ingresar", r.status_code == 200
      and httpx.get(f"{BASE}/rest/app_users", headers=h_nueva).status_code == 401
      and httpx.post(f"{BASE}/auth/login", json={"email": "nueva.persona@prueba.local", "password": "clave-nueva-persona"}).status_code == 400)
post("usuarios", {"accion": "desbloquear", "email": "nueva.persona@prueba.local"})
check("desbloquear", httpx.post(f"{BASE}/auth/login", json={"email": "nueva.persona@prueba.local",
                                                          "password": "clave-nueva-persona"}).status_code == 200)
r = post("usuarios", {"accion": "bloquear", "email": "panel@prueba.local"})
check("no se puede bloquear el propio usuario", r.status_code == 400 and "propio" in r.json()["message"], r.text)
h_otra = ingresar("nueva.persona@prueba.local", "clave-nueva-persona")
r = post("usuarios", {"accion": "cerrar_sesiones", "email": "nueva.persona@prueba.local"})
check("cerrar las sesiones de un usuario", r.status_code == 200 and r.json()["resultado"] >= 1
      and httpx.get(f"{BASE}/rest/app_users", headers=h_otra).status_code == 401, r.text)
r = post("usuarios", {"accion": "codigo", "email": "nueva.persona@prueba.local"})
check("código para restablecer la contraseña", r.status_code == 200 and len(r.json()["resultado"]) == 9, r.text)
check("acción desconocida: 400", post("usuarios", {"accion": "borrar", "email": "x"}).status_code == 400)
eventos = [e["mensaje"] for e in get("eventos", servicio="panel").json()]
check("cada acción del panel queda registrada con quién la hizo",
      any("Alta de nueva.persona@prueba.local" in m for m in eventos) and any("Bloqueo de" in m for m in eventos)
      and all(e["usuario"] == "panel@prueba.local" for e in get("eventos", servicio="panel").json()), eventos[:5])

# ------------------------------------------------------------------ actividad e integridad
ruta = "youtube/EC/2026-10-23/panel_youtube-ec-weekly-2025-01-02.csv"
httpx.post(f"{BASE}/storage/upload/csv-uploads/{ruta}", headers=dict(h, **{"Content-Type": "text/csv"}), content=b"rank,track\n1,x\n")
filas = [{"track_name": "Tema Panel", "artist_names": "Banda Panel", "pais_code": "EC", "rank": "1", "snapshot_date": d}
         for d in ("2025-01-02", "2025-01-09", "2025-01-23", "2025-01-31")]
r = httpx.post(f"{BASE}/rpc/fn_cargar_archivo", headers=h, json={"p_formato": "youtube", "p_filas": filas, "p_ruta": ruta,
                                                                 "p_archivo": "youtube-ec-weekly-2025-01-02.csv", "p_total": 4})
check("(carga de prueba)", r.status_code == 200, r.text)
httpx.post(f"{BASE}/rpc/fn_cargar_archivo", headers=h, json={"p_formato": "youtube", "p_filas": [], "p_ruta": None,
                                                            "p_archivo": "vacio.csv", "p_total": 3, "p_errores": ["Fila sin título"]})
obra = sqlq("select id from tracks_master where track_name_raw = 'Tema Panel'")
httpx.post(f"{BASE}/rpc/fn_asignar_tempo_id", headers=comun, json={"p_track_id": obra, "p_tempo_id": "5550001"})
httpx.post(f"{BASE}/rpc/fn_preparar_envio", headers=comun, json={"p_tipo": "csv_principal", "p_modo": "todas"})
act = get("actividad").json()
tipos = {(a["usuario"], a["tipo"]) for a in act}
check("actividad: cargas, cambios manuales, descargas e ingresos, con el usuario",
      {("panel@prueba.local", "Carga"), ("comun.panel@prueba.local", "Cambio"), ("comun.panel@prueba.local", "Descarga"),
       ("panel@prueba.local", "Ingreso")} <= tipos, sorted(tipos))
check("actividad: el cambio manual dice qué se cambió",
      any(a["tipo"] == "Cambio" and "Tempo ID" in a["detalle"] for a in act), [a for a in act if a["tipo"] == "Cambio"])
check("actividad: los cambios de una carga no se listan fila por fila",
      not any(a["tipo"] == "Cambio" and a["usuario"] == "panel@prueba.local" for a in act))
solo = get("actividad", usuario="comun.panel@prueba.local", tipo="Descarga").json()
check("actividad: filtros por usuario y tipo", solo and all(a["usuario"] == "comun.panel@prueba.local" and a["tipo"] == "Descarga" for a in solo))

integ = get("integridad").json()
ec = next((c for c in integ["charts"] if c["pais"] == "EC" and c["plataforma"] == "youtube"), {})
check("integridad: semanas cargadas y la semana faltante (2025-01-16); una fecha corrida no cuenta como faltante",
      ec.get("semanas") == 4 and ec.get("faltantes") == ["2025-01-16"], ec)
check("integridad: cargas sin filas cargadas o con avisos",
      any(p["archivo"] == "vacio.csv" for p in integ["problemas"]), integ["problemas"][:3])
(STORAGE / "csv-uploads" / ruta).unlink()
integ = get("integridad").json()
check("integridad: detecta un archivo registrado que falta en el almacenamiento",
      any(f["ruta"] == ruta for f in integ["archivos"]["faltantes"]), integ["archivos"])

# ------------------------------------------------------------------ estado, respaldo y registro
e = get("estado").json()
check("estado: base, contenido, recursos de la computadora y API",
      e["base"]["tamano"] > 0 and e["datos"]["obras"] >= 1 and e["recursos"]["disco"]["total"] > 0
      and e["recursos"]["memoria"]["total"] > 0 and e["api"]["iniciada"], {k: e[k] for k in ("base", "recursos", "api")})
check("estado: la actualización de la base dejó su aviso", "instalador" in e["servicios"], e["servicios"])
r = post("respaldo")
r2 = post("respaldo")
check("Respaldar ahora: queda pedido (y no se duplica si ya hay uno pendiente)", r.status_code == 200 and r.json() == r2.json()
      and sqlq(f"select estado from panel.solicitudes where id = {r.json()['id']}") == "pendiente", r.text)
sqlq("update panel.solicitudes set estado = 'listo' where estado = 'pendiente'")
check("registro del servidor: muestra los pedidos rechazados", any("403" in l["mensaje"] for l in get("registro").json()))

# ------------------------------------------------------------------ en el navegador
with sync_playwright() as p:
    nav = p.chromium.launch(executable_path="/opt/pw-browsers/chromium-1194/chrome-linux/chrome")
    errores_js = []
    pag = nav.new_page()
    pag.on("pageerror", lambda e: errores_js.append(str(e)))
    pag.goto(BASE + "/")
    pag.fill("#loginEmail", "comun.panel@prueba.local"); pag.fill("#loginPass", "clave-comun-123"); pag.click("#loginBtn")
    pag.wait_for_selector("#logoutBtn"); pag.wait_for_timeout(500)
    check("un usuario común no ve la pestaña del panel", pag.locator('[data-tab="panel"]').count() == 0)
    pag.click("#logoutBtn"); pag.wait_for_selector("#loginEmail")
    pag.fill("#loginEmail", "panel@prueba.local"); pag.fill("#loginPass", "clave-panel-123"); pag.click("#loginBtn")
    pag.wait_for_selector('[data-tab="panel"]')
    check("sin la casilla 'Ver eliminados' (tampoco para el administrador)", pag.locator("#toggleDeleted, #toggleDeletedT").count() == 0
          and "Ver eliminados" not in pag.inner_text("body"))
    # Lo que informa Tailscale (tailscale status --json y tailscale funnel status --json, con la forma de la versión 1.104).
    def tunel(status, funnel):
        j = None if status is None else json.dumps({"status": status, "funnel": funnel})
        sqlq("select panel.latido_tunel(" + ("null" if j is None else f"$j${j}$j$::jsonb") + ")")
        return json.loads(sqlq("select detalle from panel.servicios where servicio = 'tunel'"))
    yo = {"HostName": "auditor-rankings", "DNSName": "auditor-rankings.tail1234.ts.net.", "Online": True,
          "KeyExpiry": "2027-04-27T12:00:00Z"}
    abierto = {"TCP": {"443": {"HTTPS": True}}, "AllowFunnel": {"auditor-rankings.tail1234.ts.net:443": True}}
    d = tunel({"BackendState": "NeedsLogin", "AuthURL": "https://login.tailscale.com/a/x", "Self": {"DNSName": ""}}, {})
    check("acceso compartido sin sesión de Tailscale: lo indica con qué hacer", d["estado"] == "sin_sesion"
          and "bash ranking.sh compartir" in d["mensaje"] and "url" not in d, d)
    d = tunel({"BackendState": "Running", "Self": yo}, {})
    check("con sesión pero sin enlace público habilitado: lo indica", d["estado"] == "sin_funnel", d)
    d = tunel(None, None)
    check("contenedor detenido: lo indica", d["estado"] == "detenido" and "bash ranking.sh abrir" in d["mensaje"], d)
    d = tunel({"BackendState": "Running", "Self": yo}, abierto)
    check("activo: enlace https del equipo, con el vencimiento de la sesión",
          d == {"estado": "activo", "url": "https://auditor-rankings.tail1234.ts.net/", "acceso": "cualquiera",
                "vence": "2027-04-27T12:00:00Z"}, d)
    pag.click('[data-tab="panel"]'); pag.wait_for_selector(".servicio")
    check("el Panel muestra el enlace para entrar desde otras computadoras, con botón para copiarlo",
          pag.get_attribute("#enlaceCompartido", "href") == "https://auditor-rankings.tail1234.ts.net/"
          and pag.locator("#copiarEnlace").count() == 1 and "pantalla de ingreso" in pag.inner_text(".panel-body")
          and "27/04/2027" in pag.inner_text(".panel-body"), pag.inner_text(".panel-body")[:600])
    sqlq("delete from panel.servicios where servicio = 'tunel'")
    texto = pag.inner_text(".panel-body")
    check("Estado del sistema: servicios, recursos, contenido y respaldos",
          all(t in texto for t in ("Base de datos", "Funcionando", "Disco", "Memoria", "Obras sin Tempo ID", "Último respaldo")), texto[:400])
    pag.click('[data-panel-sub="usuarios"]'); pag.wait_for_selector("#panelCrear")
    check("dos perfiles: el encabezado muestra Administrador y no hay selector de rol",
          "Administrador" in pag.inner_text(".who") and pag.locator("#panelNuevoRol, [data-usuario-rol]").count() == 0)
    pag.fill("#panelNuevoEmail", "desde.navegador@prueba.local")
    pag.fill("#panelNuevaOficina", "UY"); pag.click("#panelCrear"); pag.wait_for_selector("#panelCodigo")
    cod = pag.inner_text("#panelCodigo")
    check("alta desde el panel: muestra el código de activación una vez", len(cod) == 9 and "72 horas" in pag.inner_text(".modal"), cod)
    pag.click("#closeCodigo")
    check("el usuario creado figura en la lista", pag.locator('tr[data-usuario="desde.navegador@prueba.local"]').count() == 1)
    pag.once("dialog", lambda d: d.accept())
    pag.click('[data-usuario-accion="bloquear"][data-email="desde.navegador@prueba.local"]')
    pag.wait_for_function("() => document.querySelector('tr[data-usuario=\"desde.navegador@prueba.local\"]').innerText.includes('Bloqueado')")
    check("bloquear desde el panel", sqlq("select banned_until > now() from auth.users where email = 'desde.navegador@prueba.local'") == "t")
    check("el usuario creado es usuario estándar", "Usuario estándar" in pag.inner_text('tr[data-usuario="desde.navegador@prueba.local"]')
          and sqlq("select app_role from app_users a join auth.users u on u.id = a.user_id "
                   "where u.email = 'desde.navegador@prueba.local'") == "usuario_estandar")
    pag.fill('[data-usuario-oficina="desde.navegador@prueba.local"]', "PE"); pag.press('[data-usuario-oficina="desde.navegador@prueba.local"]', "Tab")
    pag.wait_for_timeout(1000)
    check("cambiar la oficina desde el panel", sqlq("select app_role || '|' || oficina from app_users a join auth.users u on u.id = a.user_id "
                                                    "where u.email = 'desde.navegador@prueba.local'") == "usuario_estandar|PE")
    pag.click('[data-panel-sub="respaldos"]'); pag.wait_for_selector("#panelRespaldar")
    pag.click("#panelRespaldar"); pag.wait_for_timeout(1000)
    check("Respaldar ahora desde el panel", sqlq("select count(*) from panel.solicitudes where estado = 'pendiente'") == "1"
          and pag.is_disabled("#panelRespaldar"))
    sqlq("update panel.solicitudes set estado = 'listo' where estado = 'pendiente'")
    pag.click('[data-panel-sub="actividad"]'); pag.wait_for_selector("#panelActTipo")
    pag.select_option("#panelActTipo", "Carga"); pag.wait_for_timeout(800)
    check("actividad desde el panel, con filtro", "youtube-ec-weekly-2025-01-02.csv" in pag.inner_text(".tabla-panel"))
    pag.click('[data-panel-sub="integridad"]'); pag.wait_for_selector('[data-integridad="EC-youtube"]')
    check("integridad desde el panel: semana faltante", "2025-01-16" in pag.inner_text('[data-integridad="EC-youtube"]'))
    pag.click('[data-panel-sub="registro"]'); pag.wait_for_selector("#panelConsola")
    check("registro del servidor desde el panel", "API iniciada" in pag.inner_text("#panelConsola") or
          "403" in pag.inner_text("#panelConsola"))
    check("sin errores de JavaScript", not errores_js, errores_js)
    nav.close()

print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
