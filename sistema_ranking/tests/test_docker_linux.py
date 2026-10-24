"""
Prueba "bash ranking.sh ..." de punta a punta con Docker Engine (Linux / WSL2), como lo usa una persona en la terminal:
instalar (detrás de un proxy que inspecciona HTTPS: primero falla y explica qué hacer; con los certificados de la
empresa anda), migrar desde un Supabase simulado tomando el historial de carpetas tipo OneDrive, poner contraseñas,
usuarios, respaldo y restauración, detener, abrir, y una versión nueva del proyecto en otra
carpeta que sigue usando los mismos datos.

Si Docker Hub está bloqueado o limitado, ranking.sh usa solo los espejos públicos de las imágenes oficiales.
Diferencias con la PC, solo de esta prueba: sin powershell.exe (las carpetas se escriben a mano), y el certificado
"de la empresa" es una autoridad certificadora creada por la prueba, con un servidor HTTPS firmado por ella.

Variables: PGHOST_URL, ORIGEN_DB, STORAGE_ORIGEN (como test_migracion.py: la base de origen con datos),
"""
import hashlib
import os
import pathlib
import re
import shutil
import subprocess
import time
import sys
import tempfile

import httpx
import pexpect

RAIZ = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RAIZ / "tests"))
import supabase_falso  # noqa: E402

SERVIDOR = os.environ["PGHOST_URL"].rstrip("/")
ORIGEN = f"{SERVIDOR}/{os.environ.get('ORIGEN_DB', 'ranking')}"
STORAGE_ORIGEN = pathlib.Path(os.environ["STORAGE_ORIGEN"])
CLAVE = "clave-service-role-secreta-de-prueba-123"
fallas = []


def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + nombre + ("" if cond else f"  -> {extra}"))
    if not cond:
        fallas.append(nombre)


def sql(url, q):
    return subprocess.run(["psql", url, "-At", "-c", q], capture_output=True, text=True, check=True).stdout.strip()


base = pathlib.Path(tempfile.mkdtemp(prefix="rk_docker_"))
proyecto = base / "proyectos" / "ASW---Tempo-data-claude-funny-bell-bbdz84" / "sistema_ranking"   # el ZIP descomprimido
shutil.copytree(RAIZ, proyecto, ignore=shutil.ignore_patterns(".env", "exportacion", "__pycache__", "tests", "*.crt"))
# Como si el proyecto se hubiera copiado desde Windows/OneDrive con fin de línea de Windows: ranking.sh lo arregla solo.
for f in [proyecto / "db" / "instalar.sh", proyecto / "db" / "05_permisos.sql", proyecto / "docker-compose.yml"]:
    f.write_bytes(f.read_bytes().replace(b"\n", b"\r\n"))
config = base / "config" / "ranking.env"
respaldos = base / "respaldos"
# Proyecto e imagen propios de la prueba: nunca toca los datos ni la imagen de un sistema real en la misma máquina.
PROYECTO_COMPOSE, IMAGEN = "rk-prueba", "rk-prueba-api:local"
ENTORNO = dict(os.environ, RK_CONFIG=str(config), RK_RESPALDOS=str(respaldos), HOME=str(base), TERM="dumb",
               RK_BACKOFFICE=str(base / "onedrive" / "Backoffice"), RK_ESPEJO=str(base / "onedrive" / "Latam" / "RANKING DIGITAL REGIONAL"),
               COMPOSE_PROJECT_NAME=PROYECTO_COMPOSE, IMAGEN_API=IMAGEN)
subprocess.run(["docker", "compose", "-p", PROYECTO_COMPOSE, "--profile", "herramientas", "down", "-v"], capture_output=True)
# Espejo de auditoría (la carpeta compartida de OneDrive). Como /mnt/c en WSL: es del usuario de la PC (uid 1000) y
# no la puede escribir otro usuario (la API corre como 10001), solo root.
ESPEJO = pathlib.Path(ENTORNO["RK_ESPEJO"])
ESPEJO.mkdir(parents=True)
os.chown(ESPEJO, 1000, 1000)
ESPEJO.chmod(0o755)
respaldos.mkdir()
os.chown(respaldos, 1000, 1000)   # como en la PC: la carpeta de respaldos es del usuario de Ubuntu

# Carpetas "OneDrive" con los CSV del historial por su nombre original, salvo uno (tiene que bajarse del bucket).
onedrive = base / "onedrive" / "Backoffice"
carpetas = [onedrive / "Charts historicos Youtube", onedrive / "Charts historicos_spotify"]
for c in carpetas:
    c.mkdir(parents=True)
(onedrive / "RANKING DIGITAL REGIONAL").mkdir()   # donde el usuario guardó el proyecto (y van los respaldos)
registrados = sql(ORIGEN, "select string_agg(name, chr(10) order by name) from storage.objects").splitlines()
originales = dict(l.split("|", 1) for l in sql(ORIGEN, "select file_path || '|' || filename from csv_uploads where file_path is not null").splitlines())
for i, n in enumerate(registrados[1:]):
    shutil.copyfile(STORAGE_ORIGEN / "csv-uploads" / n, carpetas[i % 2] / originales.get(n, n.rsplit("/", 1)[-1]))

srv, pedidos = supabase_falso.iniciar(ORIGEN, STORAGE_ORIGEN, CLAVE, host="0.0.0.0")
gateway = subprocess.run(["docker", "network", "inspect", "bridge", "-f", "{{(index .IPAM.Config 0).Gateway}}"],
                         capture_output=True, text=True, check=True).stdout.strip()
URL_SB = f"http://{gateway}:{srv.server_port}"


def ranking(*argumentos, carpeta=None, timeout=900, entorno=None):
    p = pexpect.spawn("bash", [str((carpeta or proyecto) / "ranking.sh"), *argumentos], cwd=str(carpeta or proyecto),
                      env=entorno or ENTORNO, encoding="utf-8", timeout=timeout, dimensions=(50, 250))
    p.logfile_read = open(base / f"{argumentos[0]}.log", "a", encoding="utf-8")
    return p


def fin(p):
    p.expect(pexpect.EOF)
    p.close()
    return p.exitstatus


def valor(k):
    for l in config.read_text().splitlines():
        if l.startswith(k + "="):
            return l.split("=", 1)[1].strip("'")
    return None


def api(ruta=""):
    return f"http://127.0.0.1:{valor('PUERTO')}{ruta}"


def login(email, clave):
    try:
        return httpx.post(api("/auth/login"), json={"email": email, "password": clave}, trust_env=False)
    except httpx.HTTPError as e:
        return httpx.Response(599, text=str(e))


def dc(*a, entrada=None):
    return subprocess.run(["docker", "compose", "--project-directory", str(proyecto), "--env-file", str(config), *a],
                          capture_output=True, text=True, input=entrada, env=dict(ENTORNO, RESPALDOS_DIR=str(respaldos)))


def base_nueva(q):
    return dc("exec", "-T", "db", "psql", "-U", "postgres", "-d", "ranking", "-At", "-c", q).stdout.strip()


def texto(nombre):
    return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", (base / nombre).read_text())


# Docker Compose v5.6 / Buildx 0.38 rechazan "network: host" al armar la imagen (salvo permiso explícito), y
# las versiones de este entorno no lo hacen: se controla acá para que no vuelva.
check("docker-compose.yml no arma la imagen con network: host",
      not re.search(r"^\s*network:\s*host", (RAIZ / "docker-compose.yml").read_text(), re.M))
exito = False
try:
    # ================================================================ mensajes ante errores de red de la empresa
    funcion = subprocess.run(["sed", "-n", r"/^if \[ -t 1 \]/p;/^aviso()/p;/^explicar_error_red()/,/^}/p", str(proyecto / "ranking.sh")],
                             capture_output=True, text=True).stdout
    for error, esperado in [("x509: certificate signed by unknown authority", "bash ranking.sh certificados"),
                            ("SSL: CERTIFICATE_VERIFY_FAILED", "bash ranking.sh certificados"),
                            ("toomanyrequests: You have reached your pull rate limit", "docker login"),
                            ("dial tcp: lookup registry-1.docker.io: no such host", "HTTPS_PROXY"),
                            ("proxyconnect tcp: i/o timeout", "Red de la empresa")]:
        (base / "error.txt").write_text(error)
        r = subprocess.run(["bash", "-c", funcion + f'\nCONFIG=x; explicar_error_red "{base / "error.txt"}"'], capture_output=True, text=True)
        check(f"ante '{error[:40]}...' explica qué hacer", esperado in r.stdout, r.stdout + r.stderr)
    # Una "autoridad certificadora de la empresa" y un servidor HTTPS firmado por ella: es lo que ve Python detrás de un
    # proxy que inspecciona HTTPS. Su certificado va a certificados/ (lo que hace "ranking.sh certificados" desde Windows).
    ca = base / "ca"
    ca.mkdir()
    for cmd in (["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=CA de la empresa (prueba)",
                 "-keyout", ca / "ca.key", "-out", ca / "empresa.crt"],
                ["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=127.0.0.1", "-keyout", ca / "srv.key", "-out", ca / "srv.csr"]):
        subprocess.run([str(x) for x in cmd], check=True, capture_output=True)
    (ca / "ext.cnf").write_text("subjectAltName=IP:127.0.0.1\n")
    subprocess.run(["openssl", "x509", "-req", "-in", ca / "srv.csr", "-CA", ca / "empresa.crt", "-CAkey", ca / "ca.key",
                    "-CAcreateserial", "-days", "2", "-extfile", ca / "ext.cnf", "-out", ca / "srv.crt"], check=True, capture_output=True)
    import http.server, ssl, threading  # noqa: E401
    https = http.server.ThreadingHTTPServer(("127.0.0.1", 0), type("H", (http.server.BaseHTTPRequestHandler,), {
        "do_GET": lambda self: (self.send_response(200), self.end_headers()), "log_message": lambda self, *a: None}))
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(ca / "srv.crt", ca / "srv.key")
    https.socket = ctx.wrap_socket(https.socket, server_side=True)
    threading.Thread(target=https.serve_forever, daemon=True).start()
    shutil.copyfile(ca / "empresa.crt", proyecto / "certificados" / "empresa.crt")

    # ================================================================ proxy que inspecciona HTTPS (como el de la empresa)
    # Si en este entorno el armado de la imagen pasa por un proxy que inspecciona HTTPS, sin su certificado falla y
    # ranking.sh dice qué hacer; con el certificado (lo que deja "ranking.sh certificados") sigue.
    cert_entorno = pathlib.Path(os.environ.get("CERT_PROXY", "/root/.ccr/ca-bundle.crt"))
    if cert_entorno.exists():
        codigo = fin(ranking("instalar", "--automatico"))
        log = texto("instalar.log")
        if "CERTIFICATE_VERIFY_FAILED" in log or "x509" in log:
            check("proxy que inspecciona HTTPS sin su certificado: falla y dice que corras 'ranking.sh certificados'",
                  codigo != 0 and "bash ranking.sh certificados" in log, log[-1500:])
        shutil.copyfile(cert_entorno, proyecto / "certificados" / "proxy-del-entorno.crt")

    # ================================================================ instalar
    p = ranking("instalar")
    p.expect(r"Crear ahora un usuario administrador nuevo\? \(S/N\)"); p.sendline("S")
    p.expect("Email"); p.sendline("jefe@nuevo.local")
    p.expect("Oficina"); p.sendline("AR")
    p.expect("Contraseña nueva"); p.sendline("clave-jefe-12345")
    p.expect("Repetila"); p.sendline("clave-jefe-12345")
    codigo = fin(p)
    log = texto("instalar.log")
    check("instalar: termina bien", codigo == 0 and "Listo. Entrá desde el navegador" in log, log[-2000:])
    check("instalar: arregla los archivos copiados con fin de línea de Windows",
          "Arreglé el fin de línea de 3 archivos" in log and b"\r" not in (proyecto / "db" / "instalar.sh").read_bytes(), log[:1500])
    check("instalar: claves al azar fuera del proyecto, solo legibles por el usuario",
          all(len(valor(k) or "") == 64 for k in ("POSTGRES_PASSWORD", "AUTHENTICATOR_PASSWORD", "JWT_SECRET"))
          and oct(config.stat().st_mode)[-3:] == "600" and not (proyecto / ".env").exists())
    check("instalar: la base es PostgreSQL 17 con C.UTF-8 (como Supabase)",
          base_nueva("select current_setting('server_version_num')::int / 10000 || datlocprovider::text || datlocale from pg_database where datname='ranking'") == "17bC.UTF-8")
    check("instalar: el sistema responde solo en esta PC (127.0.0.1)", httpx.get(api("/health"), trust_env=False).status_code == 200
          and "127.0.0.1:" in dc("port", "api", "8000").stdout, dc("port", "api", "8000").stdout)
    check("instalar: el admin creado entra", login("jefe@nuevo.local", "clave-jefe-12345").status_code == 200)
    m = httpx.get(api("/manifest.webmanifest"), trust_env=False)
    check("instalar: la imagen sirve la aplicación instalable (manifiesto, service worker, íconos)",
          m.status_code == 200 and m.json().get("display") == "standalone"
          and httpx.get(api("/sw.js"), trust_env=False).status_code == 200
          and httpx.get(api("/iconos/icono-512.png"), trust_env=False).content[:4] == b"\x89PNG", m.text[:200])
    # Con el certificado de la empresa en la imagen, Python confía en un servidor firmado por ella (como el proxy que
    # inspecciona las conexiones a Supabase y YouTube); sin él, la misma conexión se rechaza.
    prueba_tls = f"import httpx; print(httpx.get('https://127.0.0.1:{https.server_port}/', timeout=20).status_code)"
    con = subprocess.run(["docker", "run", "--rm", "--network", "host", "-e", "NO_PROXY=*", IMAGEN,
                          "python", "-c", prueba_tls], capture_output=True, text=True)
    sin = subprocess.run(["docker", "run", "--rm", "--network", "host", "-e", "NO_PROXY=*",
                          "-e", "SSL_CERT_FILE=/usr/local/lib/python3.12/site-packages/certifi/cacert.pem",
                          IMAGEN, "python", "-c", prueba_tls], capture_output=True, text=True)
    check("con el certificado de la empresa, la imagen confía en su proxy (y sin él, no)",
          con.stdout.strip() == "200" and "CERTIFICATE_VERIFY_FAILED" in sin.stderr, (con.stdout + con.stderr[-300:], sin.stderr[-300:]))

    # ================================================================ migrar
    p = ranking("migrar")
    p.expect("URL del proyecto"); p.sendline(URL_SB)
    p.expect("service_role key"); p.sendline(CLAVE)
    for c in carpetas:   # las de OneDrive las encuentra solo
        p.expect(re.escape(str(c)))
    p.expect("Agregar otra carpeta"); p.sendline("")
    p.expect(r"Borrarlos y cargar lo de Supabase\? \(S/N\)"); p.sendline("S")
    p.expect("1 archivos del historial no están en esas carpetas")
    p.expect("Opción"); p.sendline("1")
    while p.expect([r"Poner contraseña a (\S+) ahora\? \(S/N\)", "Migración completa"]) == 0:
        if p.match.group(1) == "admin@prueba.local":
            p.sendline("S")
            p.expect("Contraseña nueva"); p.sendline("clave-migrada-123")
            p.expect("Repetila"); p.sendline("clave-migrada-123")
        else:
            p.sendline("N")
    codigo = fin(p)
    log = texto("migrar.log")
    check("migrar: termina bien", codigo == 0 and "Migración completa" in log, log[-2500:])
    for t in sql(ORIGEN, "select string_agg(tablename, ' ') from pg_tables where schemaname='public' and tablename not in ('envios', 'envio_obras')").split():
        q = f"select count(*) || ':' || coalesce(md5(string_agg(x::text, '|' order by x::text)), '') from public.{t} x"
        check(f"migrar: tabla {t} idéntica", sql(ORIGEN, q) == base_nueva(q))
    r = login("admin@prueba.local", "clave-migrada-123")
    check("migrar: el usuario migrado entra con la contraseña nueva", r.status_code == 200, r.text)
    tok = {"Authorization": "Bearer " + r.json().get("access_token", "")}
    r2 = httpx.get(api("/rest/app_users"), params={"select": "app_role", "user_id": "eq." + r.json()["user"]["id"]}, headers=tok, trust_env=False)
    check("migrar: conserva su rol", r2.json() == [{"app_role": "admin"}], r2.text)
    hashes = dc("exec", "-T", "api", "sh", "-c", "cd /data/storage/csv-uploads && find . -type f -exec sha256sum {} +").stdout
    check("migrar: todo el historial de archivos (carpetas + 1 del bucket), idéntico",
          {l.split("  ", 1)[1][2:]: l.split()[0] for l in hashes.splitlines()} ==
          {n: hashlib.sha256((STORAGE_ORIGEN / "csv-uploads" / n).read_bytes()).hexdigest() for n in registrados}, hashes[:500])
    bajadas = [x for x in pedidos if x.startswith("/storage/v1/object/csv-uploads/")]
    check("migrar: del bucket bajó solo el que faltaba", bajadas and all(registrados[0].split("/")[-1] in x for x in bajadas), bajadas)
    firma = httpx.post(api(f"/storage/sign/csv-uploads/{registrados[1]}"), json={"expiresIn": 60}, headers=tok, trust_env=False).json()
    bajado = httpx.get(api(firma.get("signedUrl", "")), trust_env=False)
    check("migrar: desde el historial se descarga el archivo original",
          bajado.status_code == 200 and bajado.content == (STORAGE_ORIGEN / "csv-uploads" / registrados[1]).read_bytes())
    check("migrar: no pregunta ni programa una carga automática de YouTube (los charts se cargan a mano)",
          "Horario" not in log and "YOUTUBE_CRON" not in config.read_text()
          and "YouTube" not in dc("logs", "api").stdout + dc("logs", "api").stderr, log[-800:])
    filtrada = [str(f) for f in [config, *proyecto.rglob("*")] if f.is_file() and CLAVE.encode() in f.read_bytes()]
    filtrada += ["volumen exportacion"] if CLAVE in dc("run", "--rm", "--no-deps", "-T", "herramientas", "sh", "-c",
                                                     "cat /exportacion/* /exportacion/*/* 2>/dev/null").stdout else []
    check("migrar: la service_role key no quedó guardada en ningún lado", not filtrada, filtrada)

    # ================================================================ espejo de auditoría en OneDrive (solo escritura)
    check("espejo: instalar guarda la carpeta de OneDrive en la configuración", valor("ESPEJO_DIR") == str(ESPEJO), valor("ESPEJO_DIR"))
    r = subprocess.run(["bash", str(proyecto / "ranking.sh"), "espejo"], cwd=proyecto, env=ENTORNO, capture_output=True,
                       text=True, stdin=subprocess.DEVNULL, timeout=600)
    cargados = [f for f in ESPEJO.rglob("*.csv") if "respaldo_documentacion_sistema" not in f.parts]
    check("espejo: copia a OneDrive todas las cargas migradas, con el LEEME y la documentación",
          r.returncode == 0 and cargados and (ESPEJO / "LEEME - Respaldo y auditoria.txt").exists()
          and (ESPEJO / "respaldo_documentacion_sistema" / "docs" / "manual.html").exists()
          and (ESPEJO / "respaldo_documentacion_sistema" / "docs" / "esquema" / "03_esquema.sql").exists(), (r.stdout + r.stderr)[-1000:])
    tok_admin = {"Authorization": "Bearer " + login("admin@prueba.local", "clave-migrada-123").json().get("access_token", "")}
    nombre_chart = "regional-ar-weekly-2026-10-15.csv"
    ruta_chart = f"spotify/AR/2026-10-22/123_{nombre_chart}"
    httpx.post(api(f"/storage/upload/csv-uploads/{ruta_chart}"), content=b"rank,track\n1,Tema Espejo\n",
               headers=dict(tok_admin, **{"Content-Type": "text/csv"}), trust_env=False)
    httpx.post(api("/rest/csv_uploads"), json={"filename": nombre_chart, "file_path": ruta_chart, "format": "spotify", "total_rows": 1,
                                               "updated_rows": 1, "created_tracks": 0, "error_count": 0}, headers=tok_admin, trust_env=False)
    en_od = ESPEJO / "Spotify Charts" / "ar" / nombre_chart
    for _ in range(100):
        if en_od.exists():
            break
        time.sleep(0.2)
    check("espejo: la API no puede escribir en la carpeta de OneDrive (como en WSL)...",
          dc("exec", "-T", "api", "sh", "-c", "! touch /espejo/x 2>/dev/null").returncode == 0)
    check("...y el servicio espejo copia sola cada carga nueva a 'Spotify Charts/ar' en OneDrive",
          en_od.exists() and en_od.read_bytes() == b"rank,track\n1,Tema Espejo\n", sorted(str(x) for x in ESPEJO.rglob("*"))[:20])
    estado_base = base_nueva("select (select count(*) from csv_uploads) || '|' || (select count(*) from tracks_master) || '|' || (select count(*) from storage.objects)")
    shutil.rmtree(ESPEJO / "Spotify Charts")
    firma = httpx.post(api(f"/storage/sign/csv-uploads/{ruta_chart}"), json={"expiresIn": 60}, headers=tok_admin, trust_env=False).json()
    check("espejo: borrar archivos en OneDrive no afecta al sistema (base, archivos y API siguen igual)",
          httpx.get(api("/health"), trust_env=False).status_code == 200 and estado_base == base_nueva(
              "select (select count(*) from csv_uploads) || '|' || (select count(*) from tracks_master) || '|' || (select count(*) from storage.objects)")
          and httpx.get(api(firma.get("signedUrl", "")), trust_env=False).content == b"rank,track\n1,Tema Espejo\n")
    r = subprocess.run(["bash", str(proyecto / "ranking.sh"), "espejo"], cwd=proyecto, env=ENTORNO, capture_output=True,
                       text=True, stdin=subprocess.DEVNULL, timeout=600)
    check("espejo: 'ranking.sh espejo' vuelve a copiar lo que falta en OneDrive", r.returncode == 0 and en_od.exists(), (r.stdout + r.stderr)[-600:])
    # Una copia que falla (acá, "Youtube Charts" es un archivo y no una carpeta) no frena nada, y el servicio sigue.
    bloqueo = ESPEJO / "Youtube Charts"
    shutil.rmtree(bloqueo, ignore_errors=True)
    bloqueo.write_text("no es una carpeta")
    try:
        r2 = httpx.post(api("/rest/csv_uploads"), json={"filename": "otra.csv", "file_path": ruta_chart, "format": "youtube", "total_rows": 1,
                                                         "updated_rows": 1, "error_count": 0}, headers=tok_admin, trust_env=False)
        time.sleep(5)
        check("espejo: si la copia a OneDrive falla, la carga se registra igual y queda el motivo en el log",
              r2.status_code == 201 and httpx.get(api("/health"), trust_env=False).status_code == 200
              and "no se pudo copiar otra.csv" in dc("logs", "espejo").stdout + dc("logs", "espejo").stderr, r2.text)
    finally:
        bloqueo.unlink()
    nombre2 = "regional-cl-weekly-2026-10-15.csv"
    httpx.post(api("/rest/csv_uploads"), json={"filename": nombre2, "file_path": ruta_chart, "format": "spotify", "total_rows": 1,
                                               "updated_rows": 1, "error_count": 0}, headers=tok_admin, trust_env=False)
    for _ in range(100):
        if (ESPEJO / "Spotify Charts" / "ar" / nombre2).exists():
            break
        time.sleep(0.2)
    check("espejo: después de una copia fallida, el servicio sigue copiando las cargas nuevas",
          (ESPEJO / "Spotify Charts" / "ar" / nombre2).exists())
    eventos_espejo = base_nueva("select string_agg(nivel || ' ' || mensaje, chr(10) order by id) from panel.eventos where servicio = 'espejo'")
    check("Panel de control: el espejo registra cada copia y cada falla",
          f"ok Copiado {nombre2} a Spotify Charts/ar" in eventos_espejo and "error No se pudo copiar otra.csv" in eventos_espejo,
          eventos_espejo[-800:])
    for _ in range(60):
        latido = base_nueva("select extract(epoch from now() - ultimo_aviso)::int || '|' || (detalle ->> 'onedrive_disponible') "
                            "from panel.servicios where servicio = 'espejo'")
        if latido.endswith("|true"):
            break
        time.sleep(1)
    check("Panel de control: el espejo informa que está funcionando y que OneDrive está disponible",
          latido.endswith("|true") and int(latido.split("|")[0]) < 120, latido)
    # Deja la base como estaba para las pruebas que siguen.
    base_nueva(f"delete from csv_uploads where file_path = '{ruta_chart}'; delete from storage.objects where name = '{ruta_chart}'")
    dc("exec", "-T", "api", "rm", "-f", f"/data/storage/csv-uploads/{ruta_chart}")

    # ================================================================ usuarios
    p = ranking("usuarios")
    p.expect("Opción"); p.sendline("1")
    p.expect("Email"); p.sendline("nueva@prueba.local")
    p.expect("Rol"); p.sendline("auditor")
    p.expect("Oficina"); p.sendline("")
    p.expect("Contraseña nueva"); p.sendline("clave-nueva-1234")
    p.expect("Repetila"); p.sendline("clave-nueva-1234")
    p.expect("Hecho"); p.expect("Opción"); p.sendline("4")
    p.expect("Email"); p.sendline("estandar@prueba.local")
    p.expect("Hecho"); p.expect("Opción"); p.sendline("0")
    fin(p)
    check("usuarios: crear un auditor desde el menú", login("nueva@prueba.local", "clave-nueva-1234").status_code == 200, texto("usuarios.log")[-800:])
    check("usuarios: bloquear desde el menú", base_nueva("select banned_until > now() from auth.users where email='estandar@prueba.local'") == "t")

    # ================================================================ respaldo automático (servicio "respaldo")
    check("respaldo automático: no compite con el arranque (el primero espera unos minutos)",
          not list(respaldos.glob("ranking_auto_*.dump")), sorted(f.name for f in respaldos.iterdir()))
    with config.open("a") as f:   # en la prueba, sin esa espera
        f.write("RESPALDO_DEMORA=0\n")
    dc("up", "-d", "respaldo")
    for _ in range(120):
        auto = sorted(respaldos.glob("ranking_auto_*.dump"))
        if auto and (respaldos / (auto[-1].name[:-5] + "_archivos.tgz")).exists():
            break
        time.sleep(1)
    check("respaldo automático: al arrancar deja un respaldo completo (base y archivos), a nombre del dueño de la carpeta",
          auto and auto[-1].stat().st_size > 0 and auto[-1].stat().st_uid == 1000
          and (respaldos / (auto[-1].name[:-5] + "_archivos.tgz")).stat().st_uid == 1000,
          (dc("logs", "respaldo").stdout[-800:], [(f.name, f.stat().st_uid) for f in respaldos.iterdir()]))
    check("respaldo automático: copia el .dump en OneDrive (respaldo_documentacion_sistema/respaldos/automaticos)",
          auto and (ESPEJO / "respaldo_documentacion_sistema" / "respaldos" / "automaticos" / auto[-1].name).read_bytes()
          == auto[-1].read_bytes(), dc("logs", "respaldo").stdout[-800:])
    # Conserva los últimos 14 automáticos: con 15 viejos (de hace días), al reiniciar hace uno nuevo y borra los sobrantes.
    for f in respaldos.glob("ranking_auto_*"):
        f.unlink()
    viejos = [f"ranking_auto_202501{d:02d}_030000" for d in range(1, 16)]
    for n in viejos:
        for ext in (".dump", "_archivos.tgz"):
            (respaldos / (n + ext)).write_text("viejo")
            os.utime(respaldos / (n + ext), (time.time() - 3 * 86400, time.time() - 3 * 86400))
    (respaldos / "ranking_20250101_030000.dump").write_text("manual")   # los manuales no se tocan
    dc("restart", "respaldo")
    for _ in range(120):
        auto = sorted(respaldos.glob("ranking_auto_*.dump"))
        if auto and auto[-1].name[:-5] not in viejos and (respaldos / (auto[-1].name[:-5] + "_archivos.tgz")).exists():
            break
        time.sleep(1)
    quedan_auto = sorted(f.name[:-5] for f in respaldos.glob("ranking_auto_*.dump"))
    check("respaldo automático: conserva los últimos 14 (los manuales no se tocan)",
          len(quedan_auto) == 14 and quedan_auto[:13] == viejos[2:] and quedan_auto[-1] not in viejos
          and not (respaldos / f"{viejos[0]}_archivos.tgz").exists() and (respaldos / "ranking_20250101_030000.dump").exists(),
          (quedan_auto, dc("logs", "respaldo").stdout[-600:]))
    (respaldos / "ranking_20250101_030000.dump").unlink()
    # "Respaldar ahora" del Panel de control: el servicio lo atiende en segundos, con nombre de respaldo manual y copia
    # del .dump y del .tgz en OneDrive.
    manuales_antes = set(respaldos.glob("ranking_2*.dump"))
    pedido = base_nueva("with p as (insert into panel.solicitudes (tipo, pedido_por) values ('respaldo', 'prueba') returning id) "
                        "select id from p")
    for _ in range(120):
        estado_pedido = base_nueva(f"select estado || '|' || coalesce(mensaje, '') from panel.solicitudes where id = {pedido}")
        if estado_pedido.startswith(("listo", "error")):
            break
        time.sleep(1)
    nuevos = sorted(set(respaldos.glob("ranking_2*.dump")) - manuales_antes)
    copia_od = ESPEJO / "respaldo_documentacion_sistema" / "respaldos"
    check("Panel de control: 'Respaldar ahora' hace un respaldo completo y lo copia en OneDrive",
          estado_pedido.startswith("listo|") and "copia en OneDrive" in estado_pedido and len(nuevos) == 1
          and (copia_od / nuevos[0].name).read_bytes() == nuevos[0].read_bytes()
          and (copia_od / (nuevos[0].name[:-5] + "_archivos.tgz")).exists() and nuevos[0].stat().st_uid == 1000,
          (estado_pedido, nuevos, dc("logs", "respaldo").stdout[-800:]))
    eventos_resp = base_nueva("select string_agg(mensaje, chr(10) order by id) from panel.eventos where servicio = 'respaldo'")
    check("Panel de control: los respaldos y sus copias en OneDrive quedan registrados",
          nuevos and f"Respaldo {nuevos[0].name[:-5]}" in eventos_resp and "Copia en OneDrive: ranking_auto_" in eventos_resp, eventos_resp[-800:])
    detalle_resp = base_nueva("select detalle from panel.servicios where servicio = 'respaldo'")
    check("Panel de control: el servicio de respaldos informa su estado", '"cada_horas": 24' in detalle_resp
          and '"conservar": 14' in detalle_resp and '"onedrive": true' in detalle_resp, detalle_resp)
    for f in nuevos:   # para que las cuentas de respaldos manuales que siguen no cambien
        f.unlink(); (respaldos / (f.name[:-5] + "_archivos.tgz")).unlink(missing_ok=True)

    # ================================================================ respaldo y restauración
    antes = {t: base_nueva(f"select count(*) || md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from {t} x")
             for t in ("public.tracks_master", "public.territory_tracks", "public.csv_uploads", "public.audit_logs", "auth.users", "storage.objects")}
    p = ranking("respaldo")
    codigo = fin(p)
    nombre = re.search(r"restaurar (ranking_\d+_\d+)", texto("respaldo.log"))
    check("respaldo: deja la base y los archivos", codigo == 0 and nombre and (respaldos / f"{nombre.group(1)}.dump").stat().st_size > 0, texto("respaldo.log")[-600:])
    copia_od = ESPEJO / "respaldo_documentacion_sistema" / "respaldos"
    check("respaldo: también queda copiado en OneDrive, en respaldo_documentacion_sistema/respaldos (ruta con espacios)",
          (copia_od / f"{nombre.group(1)}.dump").read_bytes() == (respaldos / f"{nombre.group(1)}.dump").read_bytes()
          and (copia_od / f"{nombre.group(1)}_archivos.tgz").exists(), texto("respaldo.log")[-600:])
    base_nueva("update tracks_master set track_name_raw = 'ROTO'; delete from territory_tracks")
    dc("exec", "-T", "api", "sh", "-c", "rm -rf /data/storage/csv-uploads")
    p = ranking("restaurar", nombre.group(1))
    p.expect(r"¿Seguir\? \(S/N\)"); p.sendline("S")
    codigo = fin(p)
    despues = {t: base_nueva(f"select count(*) || md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from {t} x") for t in antes}
    check("restaurar: la base vuelve exactamente al respaldo", codigo == 0 and antes == despues, (texto("restaurar.log")[-800:], antes, despues))
    bajado = httpx.get(api(httpx.post(api(f"/storage/sign/csv-uploads/{registrados[1]}"), json={"expiresIn": 60},
                                      headers={"Authorization": "Bearer " + login("admin@prueba.local", "clave-migrada-123").json().get("access_token", "")},
                                      trust_env=False).json().get("signedUrl", "")), trust_env=False)
    check("restaurar: los archivos del historial también", bajado.status_code == 200 and bajado.content == (STORAGE_ORIGEN / "csv-uploads" / registrados[1]).read_bytes())

    # ================================================================ vaciar el historial (empezar a cargar de cero)
    r = subprocess.run(["bash", str(proyecto / "ranking.sh"), "vaciar-historial", "--automatico"], cwd=proyecto, env=ENTORNO,
                       capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=300)
    check("vaciar-historial --automatico: se niega (lo confirma una persona) y no borra nada",
          r.returncode != 0 and base_nueva("select count(*) from storage.objects") == str(len(registrados)), r.stdout + r.stderr)
    p = ranking("vaciar-historial")
    p.expect(r"¿Vaciar el historial\? .*\(S/N\)"); p.sendline("N")
    check("vaciar-historial: si se contesta que no, no borra nada",
          fin(p) != 0 and base_nueva("select count(*) from storage.objects") == str(len(registrados)))
    obras = base_nueva("select count(*) || md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from tracks_master x")
    territorio = base_nueva("select count(*) || md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from territory_tracks x")
    p = ranking("vaciar-historial")
    p.expect(r"¿Vaciar el historial\? .*\(S/N\)"); p.sendline("S")
    codigo = fin(p)
    log = texto("vaciar-historial.log")
    resp = re.findall(r"restaurar (ranking_\d+_\d+)", log)
    quedan = dc("exec", "-T", "api", "find", "/data/storage/csv-uploads", "-type", "f").stdout.split()
    check("vaciar-historial: borra el bucket y la lista del historial, con respaldo previo",
          codigo == 0 and resp and (respaldos / f"{resp[-1]}_archivos.tgz").exists() and not quedan
          and base_nueva("select (select count(*) from storage.objects) || '|' || (select count(*) from csv_uploads)") == "0|0", (log[-800:], quedan))
    check("vaciar-historial: no toca obras, territorios ni usuarios",
          obras == base_nueva("select count(*) || md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from tracks_master x")
          and territorio == base_nueva("select count(*) || md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from territory_tracks x")
          and login("admin@prueba.local", "clave-migrada-123").status_code == 200)
    tok = {"Authorization": "Bearer " + login("admin@prueba.local", "clave-migrada-123").json().get("access_token", "")}
    subida = httpx.post(api("/storage/upload/csv-uploads/spotify/2026-10-21/nuevo.csv"), content=b"rank\n1\n",
                        headers=dict(tok, **{"Content-Type": "text/csv"}), trust_env=False)
    check("vaciar-historial: después se puede volver a cargar", subida.status_code == 200
          and base_nueva("select count(*) from storage.objects") == "1", subida.text)
    p = ranking("restaurar", resp[-1] if resp else "x")
    p.expect(r"¿Seguir\? \(S/N\)"); p.sendline("S")
    codigo = fin(p)
    check("vaciar-historial: con su respaldo se vuelve atrás", codigo == 0
          and base_nueva("select count(*) from storage.objects") == str(len(registrados)), texto("restaurar.log")[-600:])

    # ================================================================ empezar de cero (todo menos los usuarios)
    base_nueva("select fn_preparar_envio('csv_principal', 'todas')")   # un envío registrado (apunta a las obras)
    conteo = ("select (select count(*) from tracks_master) || '|' || (select count(*) from territory_tracks) || '|' || "
              "(select count(*) from territory_bo_report) || '|' || (select count(*) from territory_tempo_report) || '|' || "
              "(select count(*) from envios) || '|' || (select count(*) from csv_uploads) || '|' || (select count(*) from storage.objects) || '|' || "
              "(select count(*) from auth.users) || '|' || (select counter from bo_export_counter)")
    antes_cero = base_nueva(conteo)
    r = subprocess.run(["bash", str(proyecto / "ranking.sh"), "empezar-de-cero", "--automatico"], cwd=proyecto, env=ENTORNO,
                       capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=300)
    check("empezar-de-cero --automatico: se niega y no borra nada", r.returncode != 0 and base_nueva(conteo) == antes_cero, r.stdout + r.stderr)
    p = ranking("empezar-de-cero")
    p.expect(r"¿Borrar todos los datos y empezar de cero\? .*\(S/N\)"); p.sendline("S")
    codigo = fin(p)
    log = texto("empezar-de-cero.log")
    resp = re.findall(r"restaurar (ranking_\d+_\d+)", log)
    a = antes_cero.split("|")
    quedan = dc("exec", "-T", "api", "find", "/data/storage/csv-uploads", "-type", "f").stdout.split()
    check("empezar-de-cero: vacía obras, territorios, reportes, envíos e historial; quedan usuarios y número de carga",
          codigo == 0 and resp and base_nueva(conteo) == f"0|0|0|0|0|0|0|{a[7]}|{a[8]}" and not quedan
          and int(a[0]) > 0 and int(a[1]) > 0 and int(a[4]) > 0, (antes_cero, base_nueva(conteo), log[-800:]))
    check("empezar-de-cero: los usuarios siguen entrando", login("admin@prueba.local", "clave-migrada-123").status_code == 200)
    p = ranking("restaurar", resp[-1] if resp else "x")
    p.expect(r"¿Seguir\? \(S/N\)"); p.sendline("S")
    codigo = fin(p)
    check("empezar-de-cero: con su respaldo se vuelve atrás (también el seguimiento de envíos)",
          codigo == 0 and base_nueva(conteo) == antes_cero, (antes_cero, base_nueva(conteo), texto("restaurar.log")[-600:]))

    # ================================================================ detener y abrir
    codigo = fin(ranking("detener"))
    check("detener: apaga el sistema", codigo == 0 and login("admin@prueba.local", "clave-migrada-123").status_code == 599)
    # Lo que corre el ícono del escritorio: levanta todo y deja la ventana abierta (mantiene Ubuntu prendido).
    t_abrir = time.time()
    p = ranking("abrir", "--mantener")
    p.expect("Dejá esta ventana abierta", timeout=300)
    t_abrir = time.time() - t_abrir
    print(f"     (abrir con el sistema apagado: {t_abrir:.1f} s)")
    check("abrir con el sistema apagado: listo en menos de 40 s", t_abrir < 40, t_abrir)
    check("abrir: las mejoras de la base ya estaban aplicadas y no se repiten", "Mejoras de la base al día" in dc("logs", "instalador").stdout)
    check("abrir: deja el tiempo de arranque para el Panel de control",
          "Arranque del sistema: " in base_nueva("select mensaje from panel.eventos where servicio = 'ranking.sh' order by id desc limit 1"))
    check("abrir (ícono): vuelve a levantar todo, los datos siguen y la ventana queda abierta",
          p.isalive() and login("admin@prueba.local", "clave-migrada-123").status_code == 200, texto("abrir.log")[-800:])

    # Con el sistema funcionando, otra terminal con otro proxy (la de Ubuntu con ~/.bashrc vs. el lanzador oculto de
    # Windows, sin proxy) no tiene que reiniciar la API: antes cada "abrir" la recreaba y cortaba los pedidos.
    def contenedor_api():
        r = subprocess.run(["docker", "inspect", "-f", "{{.Id}} {{.State.StartedAt}}", f"{PROYECTO_COMPOSE}-api-1"],
                           capture_output=True, text=True)
        return r.stdout.strip()

    def proxy_api():
        r = subprocess.run(["docker", "inspect", "-f", "{{range .Config.Env}}{{println .}}{{end}}", f"{PROYECTO_COMPOSE}-api-1"],
                           capture_output=True, text=True)
        return [l for l in r.stdout.splitlines() if l.startswith("HTTPS_PROXY=")]

    sin_proxy = {k: v for k, v in ENTORNO.items() if "proxy" not in k.lower()}
    proxy_original = valor("HTTPS_PROXY")
    inicial = contenedor_api()
    codigo = fin(ranking("abrir", "--sin-navegador", entorno=sin_proxy))
    check("abrir desde una terminal sin proxy: no reinicia la API que ya funcionaba",
          codigo == 0 and contenedor_api() == inicial, (inicial, contenedor_api()))
    codigo = fin(ranking("abrir", "--sin-navegador", entorno=dict(ENTORNO, HTTPS_PROXY="http://proxy.empresa:8080")))
    con_proxy = contenedor_api()
    check("abrir con un proxy nuevo: lo guarda en la configuración y la API lo toma (se reinicia una sola vez)",
          codigo == 0 and valor("HTTPS_PROXY") == "http://proxy.empresa:8080" and con_proxy != inicial
          and proxy_api() == ["HTTPS_PROXY=http://proxy.empresa:8080"], (proxy_api(), texto("abrir.log")[-500:]))
    for _ in range(2):
        codigo = fin(ranking("abrir", "--sin-navegador", entorno=sin_proxy))
    check("abrir otra vez sin proxy (como el lanzador de Windows): misma API y conserva el proxy guardado",
          codigo == 0 and contenedor_api() == con_proxy and proxy_api() == ["HTTPS_PROXY=http://proxy.empresa:8080"],
          (con_proxy, contenedor_api(), proxy_api()))
    # Vuelve al proxy real del entorno de prueba (lo necesitan los armados de imagen que siguen).
    lineas = [l for l in config.read_text().splitlines() if not l.startswith("HTTPS_PROXY=")]
    if proxy_original is not None:
        lineas.append(f"HTTPS_PROXY='{proxy_original}'")
    config.write_text("\n".join(lineas) + "\n")
    dc("up", "-d")
    p.terminate(force=True)

    # ================================================================ versión nueva del ZIP en otra carpeta
    nueva = base / "proyectos" / "version-nueva" / "sistema_ranking"
    shutil.copytree(proyecto, nueva)
    (nueva / "front" / "index.html").write_text((nueva / "front" / "index.html").read_text() + "<!-- version nueva -->")
    usuarios_antes = base_nueva("select count(*) from auth.users")
    # Una base de antes de las mejoras propias (db/mejoras): la versión nueva se las agrega al arrancar.
    base_nueva("drop table envio_obras, envios cascade; drop function fn_preparar_envio, fn_envio_obras, fn_envios_por_obra")
    codigo = fin(ranking("instalar", carpeta=nueva))
    log = texto("instalar.log").split("1/4 Configuración")[-1]
    check("versión nueva en otra carpeta: conserva claves, datos y usuarios", codigo == 0 and "se mantiene" in log
          and f"Hay {usuarios_antes} usuarios cargados" in log and login("admin@prueba.local", "clave-migrada-123").status_code == 200, log[-1500:])
    check("versión nueva en otra carpeta: el programa se actualiza", "version nueva" in httpx.get(api("/"), trust_env=False).text)
    check("versión nueva: una base ya instalada recibe las mejoras (seguimiento de envíos) sin perder datos",
          base_nueva("select to_regclass('public.envios') is not null and to_regprocedure('fn_envios_por_obra()') is not null") == "t"
          and base_nueva("select count(*) from auth.users") == usuarios_antes)

    # ================================================================ el flujo de Antigravity: clon de git + actualizar
    # "fuente" hace de GitHub: ahí se suben las mejoras; la PC tiene un clon y corre "ranking.sh actualizar".
    git = ["git", "-c", "user.name=Claude", "-c", "user.email=claude@prueba.local", "-c", "init.defaultBranch=main"]
    fuente = base / "fuente"
    shutil.copytree(nueva, fuente / "sistema_ranking", ignore=shutil.ignore_patterns("*.crt"))

    subprocess.run(git + ["init", "-q", str(fuente)], check=True)
    subprocess.run(git + ["-C", str(fuente), "add", "-A"], check=True)
    subprocess.run(git + ["-C", str(fuente), "commit", "-qm", "version 1"], check=True)
    subprocess.run(git + ["clone", "-q", "--bare", str(fuente), str(base / "github.git")], check=True)
    subprocess.run(git + ["-C", str(fuente), "remote", "add", "origin", str(base / "github.git")], check=True)
    clon = base / "proyectos" / "ranking"
    subprocess.run(git + ["clone", "-q", str(base / "github.git"), str(clon)], check=True)
    clon_sr = clon / "sistema_ranking"
    for crt in (proyecto / "certificados").glob("*.crt"):   # lo que deja "ranking.sh certificados" (no se sube a git)
        shutil.copyfile(crt, clon_sr / "certificados" / crt.name)

    def sin_terminal(*a):   # como lo corre un agente: sin terminal y sin nadie que conteste
        return subprocess.run(["bash", str(clon_sr / "ranking.sh"), *a], cwd=clon_sr, env=ENTORNO, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=900)

    r = sin_terminal("instalar", "--automatico")
    check("instalar --automatico: sin terminal ni preguntas, conserva todo", r.returncode == 0 and "(automático)" not in r.stdout.split("4/4")[0]
          and login("admin@prueba.local", "clave-migrada-123").status_code == 200, (r.stdout + r.stderr)[-1500:])
    with config.open("a") as f:   # configuración de antes, con el horario de la carga automática de YouTube
        f.write("YOUTUBE_CRON='0 12 * * 5'\nYOUTUBE_CRON_TZ=UTC\n")
    r = sin_terminal("verificar")
    check("verificar: todo en orden (código 0) con el resumen de la base", r.returncode == 0 and "Todo en orden" in r.stdout
          and "usuarios," in r.stdout and "YouTube" not in r.stdout and "version 1" in r.stdout, r.stdout[-1500:])
    check("verificar: el espejo de OneDrive se puede escribir (servicio espejo corriendo)",
          "Espejo de auditoría en OneDrive: " in r.stdout and "No se puede escribir" not in r.stdout
          and "Contenedor espejo corriendo" in r.stdout, r.stdout[-1500:])
    check("verificar: muestra el último respaldo automático", "Contenedor respaldo corriendo" in r.stdout
          and "Respaldo automático: ranking_auto_" in r.stdout, r.stdout[-1500:])
    check("el horario viejo de YouTube se borra de la configuración", "YOUTUBE_CRON" not in config.read_text())

    def subir(archivo, cambio, mensaje):
        f = fuente / "sistema_ranking" / archivo
        f.write_text(cambio(f.read_text()))
        subprocess.run(git + ["-C", str(fuente), "commit", "-qam", mensaje], check=True)
        subprocess.run(git + ["-C", str(fuente), "push", "-q", "origin", "main"], check=True)

    subir("front/index.html", lambda t: t + "<!-- mejora 2 -->", "mejora 2: nuevo texto en el front")
    respaldos_antes = len(list(respaldos.glob("ranking_2*.dump")))   # los manuales (los automáticos son ranking_auto_*)
    datos_antes = base_nueva("select count(*) || md5(string_agg(x::text, '|' order by x::text)) from tracks_master x")
    r = sin_terminal("actualizar")
    check("actualizar: respaldo, versión nueva y verificación", r.returncode == 0 and "mejora 2: nuevo texto en el front" in r.stdout
          and len(list(respaldos.glob("ranking_2*.dump"))) == respaldos_antes + 1 and "Todo en orden" in r.stdout, (r.stdout + r.stderr)[-2000:])
    check("actualizar: el sistema sirve la versión nueva y los datos siguen iguales",
          "mejora 2" in httpx.get(api("/"), trust_env=False).text
          and base_nueva("select count(*) || md5(string_agg(x::text, '|' order by x::text)) from tracks_master x") == datos_antes)
    r = sin_terminal("actualizar")
    check("actualizar sin novedades: avisa que ya estaba al día", r.returncode == 0 and "Ya estaba en la última versión" in r.stdout, r.stdout[-800:])

    (clon_sr / "api" / "app.py").write_text((clon_sr / "api" / "app.py").read_text() + "\n# cambio a mano\n")
    r = sin_terminal("actualizar")
    check("actualizar con cambios hechos a mano: no los pisa", r.returncode != 0 and "cambios hechos a mano" in r.stderr, r.stderr[-600:])
    subprocess.run(["git", "-C", str(clon), "checkout", "--", "."], check=True)

    subir("api/app.py", lambda t: t + "\nesto rompe la api(\n", "version rota")
    r = sin_terminal("actualizar")
    check("actualizar con una versión rota: vuelve sola a la anterior y sigue funcionando",
          r.returncode != 0 and "Quedó funcionando la versión anterior" in r.stderr
          and "mejora 2" in httpx.get(api("/"), trust_env=False).text and login("admin@prueba.local", "clave-migrada-123").status_code == 200
          and "mejora 2" in subprocess.run(["git", "-C", str(clon), "log", "-1", "--format=%s"], capture_output=True, text=True).stdout,
          (r.stdout + r.stderr)[-2000:])

    # ================================================================ carga única de charts históricos desde OneDrive
    historicos = {
        ESPEJO / "Spotify Charts" / "ar" / "regional-ar-weekly-2021-01-07.csv":
            "rank,uri,artist_names,track_name,source,peak_rank,previous_rank,weeks_on_chart,streams\n1,spotify:track:h,Art H,Tema Historico,S,1,1,1,500\n",
        ESPEJO / "Youtube Charts" / "py" / "youtube-py-weekly-2023-03-09.csv":
            "Rank,Previous Rank,Track Name,Artist Name,Weeks on Chart,Views,Weekly Growth,YouTube URL\n1,--,Video Historico,Art V,1,\"9,000\",1%,https://youtu.be/h\n",
    }
    for f, t in historicos.items():
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(t)
        os.chown(f, 1000, 1000)
        f.chmod(0o600)   # como en OneDrive: solo el dueño los puede leer (el contenedor de herramientas corre como 10001)
    r = sin_terminal("verificar")
    pendientes = re.search(r"(\d+) charts en OneDrive \(Spotify Charts / Youtube Charts\) sin cargar", r.stdout)
    check("verificar: avisa cuántos charts de OneDrive faltan cargar", pendientes and int(pendientes.group(1)) >= 2, r.stdout[-800:])
    p = ranking("cargar-historicos", carpeta=clon_sr)
    p.expect(r"¿Cargar los (\d+) archivos\? .*\(S/N\)", timeout=300); total_od = int(p.match.group(1)); p.sendline("S")
    codigo = fin(p)
    log = texto("cargar-historicos.log")
    check("cargar-historicos: carga los charts de 'Spotify Charts' y 'Youtube Charts' de OneDrive (respaldo previo)",
          codigo == 0 and "Cargados completos: 2" in log and "Copia en OneDrive" in log
          and base_nueva("select string_agg(t.pais_code || ' ' || t.snapshot_date || ' ' || t.platform || ' ' || t.streams, ',' order by t.platform) "
                         "from territory_tracks t join tracks_master m on m.id = t.track_master_id "
                         "where m.track_name_clean in ('Tema Historico', 'Video Historico')") == "AR 2021-01-07 spotify 500,PY 2023-03-09 youtube 9000",
          log[-2000:])
    ya_cargados = re.search(r"ya cargados antes: (\d+)", log)
    check("cargar-historicos: saltea las copias que el espejo ya había dejado en esas carpetas (no las registra de nuevo)",
          total_od > 2 and ya_cargados and int(ya_cargados.group(1)) > 0
          and base_nueva("select count(*) from csv_uploads where uploaded_by = 'importación histórica'") == "2", (total_od, log[-800:]))
    check("cargar-historicos: deja el detalle en un registro", list(respaldos.glob("carga-historicos-*.log")))
    r = sin_terminal("verificar")
    despues = re.search(r"(\d+) charts en OneDrive \(Spotify Charts / Youtube Charts\) sin cargar", r.stdout)
    check("verificar: después de la carga, faltan 2 charts menos", (int(despues.group(1)) if despues else 0) == int(pendientes.group(1)) - 2,
          r.stdout[-800:])
    duenios = dc("exec", "-T", "api", "sh", "-c", "find /data/storage/csv-uploads ! -user ranking | head -5").stdout.strip()
    check("cargar-historicos: lo guardado en el sistema queda a nombre del usuario de la API (no de root)", duenios == "", duenios)
    tok_admin = {"Authorization": "Bearer " + login("admin@prueba.local", "clave-migrada-123").json().get("access_token", "")}
    subida = httpx.post(api("/storage/upload/csv-uploads/spotify/AR/2026-10-23/1_nuevo.csv"), content=b"rank\n1\n",
                        headers=dict(tok_admin, **{"Content-Type": "text/csv"}), trust_env=False)
    check("después de la carga masiva, la aplicación sigue pudiendo cargar archivos en esas carpetas", subida.status_code == 200, subida.text)
    p = ranking("cargar-historicos", carpeta=clon_sr)
    p.expect(r"\(S/N\)", timeout=300); p.sendline("S")
    codigo = fin(p)
    check("cargar-historicos otra vez: no carga nada dos veces", codigo == 0
          and "Cargados completos: 0" in texto("cargar-historicos.log").split("Carga de charts históricos")[-1], texto("cargar-historicos.log")[-800:])

    codigo = fin(ranking("detener"))
    r = sin_terminal("verificar")
    check("verificar con el sistema apagado: avisa (código distinto de 0)", r.returncode != 0 and "FALLA" in r.stdout, r.stdout[-800:])
    exito = not fallas
finally:
    srv.shutdown()
    if config.exists():
        dc("--profile", "herramientas", "down", "-v")
    subprocess.run(["docker", "image", "rm", "-f", IMAGEN], capture_output=True)
    if exito:
        shutil.rmtree(base, ignore_errors=True)
    else:
        print(f"Registros en {base}/*.log")

print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
