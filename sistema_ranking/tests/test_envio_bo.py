"""
Envío del reporte BO al servidor de BO (api/envio_bo.py y POST /bo/enviar).

No hay acceso al servidor real (intranet.backoffice-ms.com): se prueba contra servidores FTP locales (pyftpdlib), uno
sin cifrado y otro con TLS y certificado propio. La API de correr_todo.sh apunta a BO_SERVIDOR=127.0.0.1:BO_PUERTO.
Requiere: pip install pyftpdlib pyopenssl.
"""
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import time

import httpx
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler
from pyftpdlib.ioloop import IOLoop
from pyftpdlib.servers import FTPServer

BASE = os.environ.get("BASE", "http://localhost:8787")
PGURL = os.environ["PGURL"]
PUERTO_API = int(os.environ.get("BO_PUERTO_PRUEBA", "2121"))   # el de la API (correr_todo.sh)
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "api"))
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


tmp = pathlib.Path(tempfile.mkdtemp(prefix="rk_bo_"))
comandos = {}    # puerto -> comandos FTP recibidos (para comprobar que el usuario y la contraseña no se enviaron)


def huella_de(puerto):
    import ssl
    pem = (tmp / f"cert{puerto}.pem").read_text()   # clave privada y certificado en el mismo archivo
    return envio_bo.huella(ssl.PEM_cert_to_DER_cert(pem[pem.index("-----BEGIN CERTIFICATE-----"):]))


def servidor_ftp(puerto, carpeta, tls=False, cifrados=None, exigir_tls=True, solo_en=None, otras=("Otra carpeta",)):
    """solo_en: subcarpeta donde el usuario puede cargar archivos (en la raíz, solo leer), como en BO."""
    carpeta.mkdir(parents=True, exist_ok=True)
    autorizador = DummyAuthorizer()
    autorizador.add_user("bo_rocio", "clave-bo", str(carpeta), perm="elr" if solo_en else "elradfmw")
    if solo_en:
        (carpeta / solo_en).mkdir(exist_ok=True)
        for otra in otras:
            (carpeta / otra).mkdir(exist_ok=True)
        autorizador.override_perm("bo_rocio", str(carpeta / solo_en), perm="elradfmw", recursive=True)
    registro = comandos.setdefault(puerto, [])

    def process_command(self, cmd, *args, **kwargs):
        registro.append(cmd)
        return base.process_command(self, cmd, *args, **kwargs)
    if tls:
        cert = tmp / f"cert{puerto}.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost",
                        "-keyout", str(cert), "-out", str(cert)], check=True, capture_output=True)
        base = TLS_FTPHandler
        manejador = type("ManejadorTLS", (TLS_FTPHandler,), {"process_command": process_command})
        manejador.certfile = str(cert)
        manejador.tls_control_required = exigir_tls
        manejador.tls_data_required = exigir_tls
        if cifrados:   # servidor que solo acepta cifrados antiguos (como el de BO: "handshake failure" con Python)
            from OpenSSL import SSL
            ctx = SSL.Context(SSL.TLS_METHOD)
            ctx.set_max_proto_version(SSL.TLS1_2_VERSION)
            ctx.set_cipher_list(cifrados.encode())
            ctx.use_certificate_chain_file(str(cert))
            ctx.use_privatekey_file(str(cert))
            manejador.ssl_context = ctx
    else:
        base = FTPHandler
        manejador = type("Manejador", (FTPHandler,), {"process_command": process_command})
    manejador.authorizer = autorizador
    servidor = FTPServer(("127.0.0.1", puerto), manejador, ioloop=IOLoop())   # un ciclo propio por servidor
    threading.Thread(target=servidor.serve_forever, kwargs={"blocking": True}, daemon=True).start()
    time.sleep(0.3)
    return servidor


# ------------------------------------------------------------------ módulo de envío
import envio_bo  # noqa: E402

simple = tmp / "simple"
cifrado = tmp / "cifrado"
servidor_ftp(2141, simple)
servidor_ftp(2142, cifrado, tls=True)

r = envio_bo.subir("bo_rocio", "clave-bo", "reporte_bo_carga1.csv", b"1;Tema;BOcarga1", servidor="127.0.0.1", puerto=2141, modo="auto")
check("servidor sin cifrado: sube el archivo a la carpeta del usuario (como FileZilla, con FTP simple)",
      r == "FTP" and (simple / "reporte_bo_carga1.csv").read_bytes() == b"1;Tema;BOcarga1", r)
envio_bo.TLS_VERIFICAR = False
r = envio_bo.subir("bo_rocio", "clave-bo", "reporte_bo_carga2.csv", b"2;Tema;BOcarga2", servidor="127.0.0.1", puerto=2142, modo="auto")
check("servidor con TLS: sube cifrado (FTPS explícito, también la conexión de datos)",
      r == "FTPS" and (cifrado / "reporte_bo_carga2.csv").read_bytes() == b"2;Tema;BOcarga2", r)
# El caso real de BO (17/11/2026): "[SSL: SSLV3_ALERT_HANDSHAKE_FAILURE]": el servidor solo acepta cifrados que Python ya
# no ofrece por defecto (intercambio RSA, SHA1). FileZilla los acepta.
antiguo = tmp / "antiguo"
servidor_ftp(2143, antiguo, tls=True, cifrados="AES256-SHA:@SECLEVEL=0")
r = envio_bo.subir("bo_rocio", "clave-bo", "reporte_bo_carga3.csv", b"3;Tema;BOcarga3", servidor="127.0.0.1", puerto=2143, modo="auto")
check("servidor con cifrados antiguos (handshake failure): reintenta en modo compatible, como FileZilla, y sube cifrado",
      r == "FTPS" and (antiguo / "reporte_bo_carga3.csv").read_bytes() == b"3;Tema;BOcarga3", r)
# Ofrece TLS pero el cifrado no se puede establecer de ninguna forma: con BO_MODO=auto sube con FTP simple.
sin_cifrado = tmp / "sin_cifrado"
servidor_ftp(2144, sin_cifrado, tls=True, cifrados="NULL-SHA:@SECLEVEL=0", exigir_tls=False)
r = envio_bo.subir("bo_rocio", "clave-bo", "reporte_bo_carga4.csv", b"4", servidor="127.0.0.1", puerto=2144, modo="auto")
check("TLS imposible de establecer: con BO_MODO=auto sube con FTP simple",
      r == "FTP" and (sin_cifrado / "reporte_bo_carga4.csv").read_bytes() == b"4", r)
try:
    envio_bo.subir("bo_rocio", "clave-bo", "x.csv", b"x", servidor="127.0.0.1", puerto=2144, modo="ftps")
    check("...con BO_MODO=ftps no sube sin cifrado y explica por qué", False)
except envio_bo.ErrorEnvio as e:
    check("...con BO_MODO=ftps no sube sin cifrado y explica por qué", "conexión cifrada" in str(e), str(e))
envio_bo.TLS_VERIFICAR = True
# El caso real de BO (17/11/2026): "El certificado del servidor de BO no es de confianza" (autofirmado). Como FileZilla:
# se muestra el certificado; aceptado (su huella), se envía, y solo con ese certificado.
comandos[2142].clear()
try:
    envio_bo.subir("bo_rocio", "clave-bo", "x.csv", b"x", servidor="127.0.0.1", puerto=2142, modo="auto")
    check("certificado autofirmado: no envía y devuelve sus datos para aceptarlo (como FileZilla)", False)
except envio_bo.CertificadoDesconocido as e:
    i = e.info
    check("certificado autofirmado: no envía y devuelve sus datos para aceptarlo (como FileZilla)",
          i["huella"] == huella_de(2142) and "autofirmado" in i["motivo"] and i.get("emitido_para") == "localhost"
          and i.get("valido_hasta"), i)
check("...sin enviar el usuario ni la contraseña a un servidor con un certificado no aceptado",
      "AUTH" in comandos[2142] and "USER" not in comandos[2142] and "PASS" not in comandos[2142], comandos[2142])
r = envio_bo.subir("bo_rocio", "clave-bo", "reporte_bo_carga5.csv", b"5", servidor="127.0.0.1", puerto=2142, modo="auto",
                   huellas=[huella_de(2142)])
check("certificado aceptado: envía cifrado", r == "FTPS" and (cifrado / "reporte_bo_carga5.csv").read_bytes() == b"5", r)
comandos[2142].clear()
try:
    envio_bo.subir("bo_rocio", "clave-bo", "x.csv", b"x", servidor="127.0.0.1", puerto=2142, modo="auto",
                   huellas=[huella_de(2143)])
    check("si el servidor presenta otro certificado que el aceptado, vuelve a preguntar y no envía la contraseña", False)
except envio_bo.CertificadoDesconocido as e:
    check("si el servidor presenta otro certificado que el aceptado, vuelve a preguntar y no envía la contraseña",
          e.info["huella"] == huella_de(2142) and "PASS" not in comandos[2142], comandos[2142])
# El caso real de BO (17/11/2026): "550 /reporte_bo_carga12_identificadas.csv: Permission denied": en la carpeta que se
# abre al conectarse no se puede escribir; en FileZilla el archivo se carga en una subcarpeta.
restringido = tmp / "restringido"
servidor_ftp(2145, restringido, tls=True, exigir_tls=False, solo_en="Upload")
envio_bo.TLS_VERIFICAR = False
try:
    envio_bo.subir("bo_rocio", "clave-bo", "r.csv", b"r", servidor="127.0.0.1", puerto=2145, modo="auto")
    check("sin permiso en la carpeta inicial: no envía y devuelve sus subcarpetas para elegir (por TLS)", False)
except envio_bo.CarpetaSinPermiso as e:
    check("sin permiso en la carpeta inicial: no envía y devuelve sus subcarpetas para elegir (por TLS)",
          e.carpeta == "/" and e.carpetas == ["Otra carpeta", "Upload"] and "permiso" in str(e), (e.carpeta, e.carpetas, str(e)))
    reg = "\n".join(e.registro)
    check("...con el registro de la conexión, como el de FileZilla, sin la contraseña",
          "Comando: USER bo_rocio" in reg and "Comando: PASS ********" in reg and "clave-bo" not in reg
          and "Comando: STOR r.csv" in reg and "Respuesta: 550" in reg, reg)
r = envio_bo.subir("bo_rocio", "clave-bo", "r.csv", b"r", servidor="127.0.0.1", puerto=2145, modo="auto", carpeta="/Upload")
check("con la carpeta elegida, carga el archivo ahí", r == "FTPS" and (restringido / "Upload" / "r.csv").read_bytes() == b"r", r)
try:
    envio_bo.subir("bo_rocio", "clave-bo", "r.csv", b"r", servidor="127.0.0.1", puerto=2145, modo="auto", carpeta="/No existe")
    check("carpeta inexistente: lo dice y ofrece las carpetas de la inicial", False)
except envio_bo.CarpetaSinPermiso as e:
    check("carpeta inexistente: lo dice y ofrece las carpetas de la inicial",
          "No se pudo abrir la carpeta /No existe" in str(e) and "Upload" in e.carpetas, (str(e), e.carpetas))
# Como en BO (17/11/2026): cada usuario ve una sola carpeta (la suya, por ejemplo 12345) y no tiene que indicarla.
unica = tmp / "unica"
servidor_ftp(2146, unica, tls=True, exigir_tls=False, solo_en="12345", otras=())
r = envio_bo.subir("bo_rocio", "clave-bo", "u.csv", b"u", servidor="127.0.0.1", puerto=2146, modo="auto")
check("sin permiso en la carpeta inicial y con una sola carpeta adentro: carga ahí sin que la persona la indique",
      r == "FTPS" and r.carpeta == "/12345" and (unica / "12345" / "u.csv").read_bytes() == b"u", (r, r.carpeta))
envio_bo.TLS_VERIFICAR = True


class _FtpSinMlsd:   # servidor sin MLSD que lista como IIS o como Unix
    def __init__(self, lineas):
        self.lineas = lineas

    def mlsd(self, facts=None):
        raise envio_bo.ftplib.error_perm("500 MLSD not understood")

    def retrlines(self, cmd, cb):
        for linea in self.lineas:
            cb(linea)


check("lista carpetas de servidores sin MLSD (formato de IIS y de Unix)",
      envio_bo._carpetas(_FtpSinMlsd(["11-17-26  01:23PM       <DIR>          Upload",
                                     "11-17-26  01:23PM                  120 archivo.csv",
                                     "11-17-26  01:23PM       <DIR>          Reportes BO"])) == ["Reportes BO", "Upload"]
      and envio_bo._carpetas(_FtpSinMlsd(["drwxr-xr-x 2 bo bo 4096 Nov 17 13:23 Upload", "-rw-r--r-- 1 bo bo 9 Nov 17 13:23 x.csv",
                                         "drwxr-xr-x 2 bo bo 4096 Nov 17 13:23 ."])) == ["Upload"])
try:
    envio_bo.subir("bo_rocio", "otra", "x.csv", b"x", servidor="127.0.0.1", puerto=2141, modo="auto")
    check("contraseña de BO incorrecta: lo dice", False)
except envio_bo.ErrorEnvio as e:
    check("contraseña de BO incorrecta: lo dice", "usuario o la contraseña" in str(e), str(e))
try:
    envio_bo.subir("bo_rocio", "clave-bo", "x.csv", b"x", servidor="127.0.0.1", puerto=2199, modo="auto")
    check("servidor que no responde: pide revisar la conexión (sin mencionar la VPN)", False)
except envio_bo.ErrorEnvio as e:
    check("servidor que no responde: pide revisar la conexión (sin mencionar la VPN)",
          "conexión a internet" in str(e) and "VPN" not in str(e), str(e))
try:
    envio_bo.subir("bo_rocio", "clave-bo", "x.csv", b"x", servidor="127.0.0.1", puerto=2141, modo="ftps")
    check("con BO_MODO=ftps no baja a FTP sin cifrado", False)
except envio_bo.ErrorEnvio as e:
    check("con BO_MODO=ftps no baja a FTP sin cifrado", "cifradas" in str(e), str(e))

# ------------------------------------------------------------------ API: POST /bo/enviar
carpeta_api = tmp / "api"
servidor_ftp(PUERTO_API, carpeta_api, tls=True, exigir_tls=False, solo_en="Upload")   # como BO: autofirmado, carga en subcarpeta
sqlq("""SELECT auth.set_password('bo.habilitada@prueba.local', 'clave-bo-123456');
        SELECT auth.set_password('bo.otra@prueba.local', 'clave-bo-123456');
        INSERT INTO public.app_users (user_id, app_role, oficina) SELECT id, 'usuario_estandar', 'AR' FROM auth.users
        WHERE email LIKE 'bo.%@prueba.local' ON CONFLICT (user_id) DO NOTHING;
        INSERT INTO public.envio_bo_usuarios (email) VALUES ('bo.habilitada@prueba.local') ON CONFLICT DO NOTHING;
        SELECT count(*) FROM fn_upsert_ranking_row('Tema Envio BO, con coma', 'Banda BO', 'AR', 1, 1, 1, 1, 10, 'x', 'u', 'spotify', null, '2026-10-08');
        UPDATE tracks_master SET tempo_id = '8880001' WHERE track_name_raw = 'Tema Envio BO, con coma'""")
check("instalado, el envío queda habilitado para todas las personas (pedido del 17/11/2026)",
      sqlq("select todos from envio_bo_config") == "t")
sqlq("update envio_bo_config set todos = false")   # para probar la habilitación de a una persona
check("al comienzo solo la usuaria que lo pidió tiene habilitado el envío de a una",
      sqlq("select string_agg(email, ',' order by email) from envio_bo_usuarios where email not like '%prueba.local'")
      == "rocio.guevara@sonymusicpub.com")


def ingresar(email):
    r = httpx.post(f"{BASE}/auth/login", json={"email": email, "password": "clave-bo-123456"})
    return {"Authorization": "Bearer " + r.json().get("access_token", "")}


h = ingresar("bo.habilitada@prueba.local")
h_otra = ingresar("bo.otra@prueba.local")
check("fn_envio_bo_habilitado: sí para la persona habilitada y no para las demás",
      httpx.post(f"{BASE}/rpc/fn_envio_bo_habilitado", json={}, headers=h).json() is True
      and httpx.post(f"{BASE}/rpc/fn_envio_bo_habilitado", json={}, headers=h_otra).json() is False)
filtros = {"p_buscar": "Tema Envio BO"}
r = httpx.post(f"{BASE}/bo/enviar", headers=h_otra, json={"modo": "todas", "usuario": "bo_rocio", "clave": "clave-bo", "filtros": filtros})
check("una persona sin habilitar no puede enviar", r.status_code == 403, r.text)
envios_antes = sqlq("select count(*) from envios where tipo = 'reporte_bo'")
sqlq("delete from envio_bo_certificados")
comandos[PUERTO_API].clear()
r = httpx.post(f"{BASE}/bo/enviar", headers=h, json={"modo": "todas", "usuario": "bo_rocio", "clave": "clave-bo", "filtros": filtros}, timeout=60)
d = r.json().get("detalle") or {}
check("certificado no reconocido: no envía, devuelve sus datos y no registra el envío",
      r.status_code == 409 and r.json().get("code") == "certificado_bo" and d.get("huella") == huella_de(PUERTO_API)
      and d.get("puede_aceptar") is False and "PASS" not in comandos[PUERTO_API]
      and sqlq("select count(*) from envios where tipo = 'reporte_bo'") == envios_antes, r.text)
cert = {k: d.get(k) for k in ("huella", "emitido_para", "emitido_por", "valido_desde", "valido_hasta", "motivo")}
r = httpx.post(f"{BASE}/bo/enviar", headers=h, json={"modo": "todas", "usuario": "bo_rocio", "clave": "clave-bo", "filtros": filtros,
                                                     "aceptar_certificado": cert}, timeout=60)
check("solo un Administrador acepta el certificado", r.status_code == 403 and "Administrador" in r.json()["message"]
      and sqlq("select count(*) from envio_bo_certificados") == "0", r.text)
sqlq("insert into panel.acceso (email) values ('bo.habilitada@prueba.local') on conflict do nothing")
r = httpx.post(f"{BASE}/bo/enviar", headers=h, json={"modo": "todas", "usuario": "bo_rocio", "clave": "mal", "filtros": filtros,
                                                     "aceptar_certificado": cert}, timeout=60)
check("el error trae el registro de la conexión (sin la contraseña)",
      r.status_code == 502 and any(l.startswith("Respuesta: 530") for l in (r.json().get("detalle") or {}).get("registro", []))
      and "Comando: PASS ********" in r.json()["detalle"]["registro"] and '"mal"' not in r.text.replace('"clave": "mal"', ''), r.text)
check("con la contraseña de BO incorrecta no se envía ni queda registrado (ni el número de carga)",
      r.status_code == 502 and "usuario o la contraseña" in r.json()["message"]
      and sqlq("select count(*) from envios where tipo = 'reporte_bo'") == envios_antes, r.text)
check("...pero el certificado aceptado queda recordado, con quién lo aceptó (y en la Actividad del Panel)",
      sqlq("select aceptado_por || '=' || huella from envio_bo_certificados") == "bo.habilitada@prueba.local=" + huella_de(PUERTO_API)
      and sqlq("select count(*) from panel.eventos where mensaje like 'Certificado del servidor de BO aceptado%'") != "0")
r = httpx.post(f"{BASE}/bo/enviar", headers=h, json={"modo": "todas", "usuario": "bo_rocio", "clave": "", "filtros": filtros})
check("sin contraseña pide ingresarla", r.status_code == 400 and "contraseña de BO" in r.json()["message"], r.text)
r = httpx.post(f"{BASE}/bo/enviar", headers=h, json={"modo": "todas", "usuario": "bo_rocio", "clave": "clave-bo", "filtros": filtros}, timeout=60)
d = r.json().get("detalle") or {}
check("sin permiso en la carpeta inicial: devuelve la carpeta y sus subcarpetas, y no registra el envío",
      r.status_code == 409 and r.json().get("code") == "carpeta_bo" and d.get("carpeta") == "/" and "Upload" in d.get("carpetas", [])
      and sqlq("select count(*) from envios where tipo = 'reporte_bo'") == envios_antes, r.text)
r = httpx.post(f"{BASE}/bo/enviar", headers=h, json={"modo": "todas", "usuario": "bo_rocio", "clave": "clave-bo", "filtros": filtros,
                                                     "carpeta": "/Upload"}, timeout=60)
carga = r.json().get("carga") if r.status_code == 200 else None
archivo = carpeta_api / "Upload" / f"reporte_bo_carga{carga}.csv"
check("con usuario y contraseña de BO, el reporte queda en la carpeta del usuario, con el formato de siempre",
      r.status_code == 200 and r.json().get("carpeta") == "/Upload" and archivo.exists() and archivo.read_text() == f"8880001;Tema Envio BO con coma;BOcarga{carga}",
      (r.text, archivo.read_text() if archivo.exists() else "(no está)"))
check("...queda registrado como enviado (para 'Identificadas desde el último envío' y la Actividad del Panel)",
      sqlq("select enviado_a || '=' || obras from envios where tipo = 'reporte_bo' order by id desc limit 1") == "127.0.0.1=1"
      and r.json()["contenido"] == archivo.read_text(), r.text)
sqlq("delete from panel.acceso where email = 'bo.habilitada@prueba.local'")

# "Identificadas desde tu último reporte BO" es por persona (18/11/2026): cada una genera el reporte para sus países.
def identificadas(hdr):
    r = httpx.post(f"{BASE}/rpc/fn_envio_conteo", json={"p_tipo": "reporte_bo", **filtros}, headers=hdr).json()
    return (r[0] if isinstance(r, list) else r).get("identificadas")


sqlq("update envio_bo_config set todos = true")
check("lo que envió una persona no se descuenta para las demás (cada una genera el reporte de sus países)",
      identificadas(h) == 0 and identificadas(h_otra) == 1, (identificadas(h), identificadas(h_otra)))
r = httpx.post(f"{BASE}/bo/enviar", headers=h_otra, json={"modo": "identificadas", "usuario": "bo_rocio", "clave": "clave-bo",
                                                          "filtros": filtros, "carpeta": "/Upload"}, timeout=60)
check("...la otra persona envía sus identificadas y después le quedan en 0",
      r.status_code == 200 and r.json()["obras"] == 1 and identificadas(h_otra) == 0 and identificadas(h) == 0, r.text)
# Base anterior (una sola marca por obra, para todos): al aplicar 01 se reparte por persona, sin perder lo enviado.
sqlq("""alter table envio_identificadas drop constraint envio_identificadas_pkey; delete from envio_identificadas;
        alter table envio_identificadas drop column usuario;
        insert into envio_identificadas (tipo, track_master_id, envio_id)
        select distinct on (e.tipo, eo.track_master_id) e.tipo, eo.track_master_id, e.id
        from envio_obras eo join envios e on e.id = eo.envio_id order by e.tipo, eo.track_master_id, e.created_at;
        alter table envio_identificadas add primary key (tipo, track_master_id)""")
raiz = pathlib.Path(__file__).resolve().parents[1]
r = subprocess.run(["psql", PGURL, "-v", "ON_ERROR_STOP=1", "-q", "-c", "SET ROLE app_owner", "-f", str(raiz / "db/mejoras/01_seguimiento.sql")],
                   capture_output=True, text=True)
check("base anterior: las marcas pasan a ser por persona (cada una conserva lo que ya envió)",
      r.returncode == 0 and identificadas(h) == 0 and identificadas(h_otra) == 0
      and sqlq("select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'envio_identificadas'::regclass and contype = 'p'")
      == "PRIMARY KEY (tipo, usuario, track_master_id)", r.stderr[-800:])
sqlq("update envio_bo_config set todos = false")
check("habilitado para todas: también puede enviar quien no está en la lista",
      httpx.post(f"{BASE}/rpc/fn_envio_bo_habilitado", json={}, headers=h_otra).json() is False
      and (sqlq("update envio_bo_config set todos = true") or True)
      and httpx.post(f"{BASE}/rpc/fn_envio_bo_habilitado", json={}, headers=h_otra).json() is True)
check("la contraseña de BO no queda guardada en la base",
      sqlq("select count(*) from audit_logs where coalesce(new_data::text, '') like '%clave-bo%'") == "0"
      and "clave-bo" not in sqlq("select coalesce(string_agg(mensaje, ' '), '') from panel.eventos"))

print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
