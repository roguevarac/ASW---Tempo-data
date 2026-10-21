"""
Prueba "bash ranking.sh ..." de punta a punta con Docker Engine (Linux / WSL2), como lo usa una persona en la terminal:
instalar (detrás de un proxy que inspecciona HTTPS: primero falla y explica qué hacer; con los certificados de la
empresa anda), migrar desde un Supabase simulado tomando el historial de carpetas tipo OneDrive, poner contraseñas,
programar YouTube, usuarios, respaldo y restauración, detener, abrir, y una versión nueva del proyecto en otra
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
               RK_BACKOFFICE=str(base / "onedrive" / "Backoffice"),
               COMPOSE_PROJECT_NAME=PROYECTO_COMPOSE, IMAGEN_API=IMAGEN)
subprocess.run(["docker", "compose", "-p", PROYECTO_COMPOSE, "--profile", "herramientas", "down", "-v"], capture_output=True)

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
                          capture_output=True, text=True, input=entrada, env=ENTORNO)


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
    while p.expect([r"Poner contraseña a (\S+) ahora\? \(S/N\)", "Horario:"]) == 0:
        if p.match.group(1) == "admin@prueba.local":
            p.sendline("S")
            p.expect("Contraseña nueva"); p.sendline("clave-migrada-123")
            p.expect("Repetila"); p.sendline("clave-migrada-123")
        else:
            p.sendline("N")
    p.sendline("0 12 * * 5")
    codigo = fin(p)
    log = texto("migrar.log")
    check("migrar: termina bien", codigo == 0 and "Migración completa" in log, log[-2500:])
    for t in sql(ORIGEN, "select string_agg(tablename, ' ') from pg_tables where schemaname='public'").split():
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
    check("migrar: YouTube programado en el sistema (UTC, como en Supabase)",
          dc("exec", "-T", "api", "printenv", "YOUTUBE_CRON", "YOUTUBE_CRON_TZ").stdout.split("\n")[:2] == ["0 12 * * 5", "UTC"]
          and "YouTube: próxima carga" in dc("logs", "api").stdout + dc("logs", "api").stderr)
    filtrada = [str(f) for f in [config, *proyecto.rglob("*")] if f.is_file() and CLAVE.encode() in f.read_bytes()]
    filtrada += ["volumen exportacion"] if CLAVE in dc("run", "--rm", "--no-deps", "-T", "herramientas", "sh", "-c",
                                                     "cat /exportacion/* /exportacion/*/* 2>/dev/null").stdout else []
    check("migrar: la service_role key no quedó guardada en ningún lado", not filtrada, filtrada)

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

    # ================================================================ respaldo y restauración
    antes = {t: base_nueva(f"select count(*) || md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from {t} x")
             for t in ("public.tracks_master", "public.territory_tracks", "public.csv_uploads", "public.audit_logs", "auth.users", "storage.objects")}
    p = ranking("respaldo")
    codigo = fin(p)
    nombre = re.search(r"restaurar (ranking_\d+_\d+)", texto("respaldo.log"))
    check("respaldo: deja la base y los archivos", codigo == 0 and nombre and (respaldos / f"{nombre.group(1)}.dump").stat().st_size > 0, texto("respaldo.log")[-600:])
    copia_od = onedrive / "RANKING DIGITAL REGIONAL" / "respaldos"
    check("respaldo: también queda copiado en OneDrive (ruta con espacios)",
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

    # ================================================================ detener y abrir
    codigo = fin(ranking("detener"))
    check("detener: apaga el sistema", codigo == 0 and login("admin@prueba.local", "clave-migrada-123").status_code == 599)
    # Lo que corre el ícono del escritorio: levanta todo y deja la ventana abierta (mantiene Ubuntu prendido).
    p = ranking("abrir", "--mantener")
    p.expect("Dejá esta ventana abierta", timeout=300)
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
    codigo = fin(ranking("instalar", carpeta=nueva))
    log = texto("instalar.log").split("1/4 Configuración")[-1]
    check("versión nueva en otra carpeta: conserva claves, datos y usuarios", codigo == 0 and "se mantiene" in log
          and f"Hay {usuarios_antes} usuarios cargados" in log and login("admin@prueba.local", "clave-migrada-123").status_code == 200, log[-1500:])
    check("versión nueva en otra carpeta: el programa se actualiza", "version nueva" in httpx.get(api("/"), trust_env=False).text)

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
    r = sin_terminal("verificar")
    check("verificar: todo en orden (código 0) con el resumen de la base", r.returncode == 0 and "Todo en orden" in r.stdout
          and "usuarios," in r.stdout and "Carga de YouTube programada: 0 12 * * 5" in r.stdout and "version 1" in r.stdout, r.stdout[-1500:])

    def subir(archivo, cambio, mensaje):
        f = fuente / "sistema_ranking" / archivo
        f.write_text(cambio(f.read_text()))
        subprocess.run(git + ["-C", str(fuente), "commit", "-qam", mensaje], check=True)
        subprocess.run(git + ["-C", str(fuente), "push", "-q", "origin", "main"], check=True)

    subir("front/index.html", lambda t: t + "<!-- mejora 2 -->", "mejora 2: nuevo texto en el front")
    respaldos_antes = len(list(respaldos.glob("*.dump")))
    datos_antes = base_nueva("select count(*) || md5(string_agg(x::text, '|' order by x::text)) from tracks_master x")
    r = sin_terminal("actualizar")
    check("actualizar: respaldo, versión nueva y verificación", r.returncode == 0 and "mejora 2: nuevo texto en el front" in r.stdout
          and len(list(respaldos.glob("*.dump"))) == respaldos_antes + 1 and "Todo en orden" in r.stdout, (r.stdout + r.stderr)[-2000:])
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
