"""
Prueba la versión portable de Windows (windows/*.ps1, los que corren los .bat) de punta a punta, como lo haría una
persona: instalar, migrar desde un Supabase simulado tomando el historial de carpetas tipo OneDrive, poner
contraseñas, administrar usuarios, apagar, volver a abrir y reinstalar encima (actualización).

Corre los scripts reales con PowerShell y PostgreSQL 17 (el mismo paquete que usa Windows, en su versión de Linux),
con un usuario común: PostgreSQL no arranca como administrador, igual que en Windows.
Diferencias con una PC con Windows, solo de esta prueba:
  - los componentes ya vienen preparados (en runtime\\ hay atajos a los programas de Linux con nombre .exe); la
    descarga, verificación y extracción de los componentes reales de Windows la prueba test_componentes_windows.py;
  - sin accesos directos (son de Windows).

Variables: PGHOST_URL, ORIGEN_DB, STORAGE_ORIGEN (como test_migracion.py: la base de origen con datos),
           PWSH (PowerShell; si falta se toma de la imagen de Docker de PowerShell, si existe).
"""
import hashlib
import json
import os
import pathlib
import pwd
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

import httpx
import pexpect

RAIZ = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RAIZ / "tests"))
import supabase_falso  # noqa: E402

SERVIDOR = os.environ["PGHOST_URL"].rstrip("/")
ORIGEN = f"{SERVIDOR}/{os.environ.get('ORIGEN_DB', 'ranking')}"
STORAGE_ORIGEN = pathlib.Path(os.environ["STORAGE_ORIGEN"])
CLAVE = "clave-service-role-secreta-de-prueba-123"
CACHE = pathlib.Path(os.environ.get("CACHE_PRUEBAS", "/var/tmp/rk_pruebas_cache"))
PG17_LINUX = ("https://registry.npmjs.org/@embedded-postgres/linux-x64/-/linux-x64-17.10.0-beta.17.tgz",
              "854e128276b5f62c433ff9773ffce41e143d074243577f6a03ded1373e7941c9e07918c50b9ff51b7e8b663383549f3891524751340c9a5cbb9f358ef23b3c92")
USUARIO = "rktest"
fallas = []


def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + nombre + ("" if cond else f"  -> {extra}"))
    if not cond:
        fallas.append(nombre)


def sql(url, q):
    return subprocess.run(["psql", url, "-At", "-c", q], capture_output=True, text=True, check=True).stdout.strip()


# ------------------------------------------------------------------ herramientas de la prueba
def conseguir_pwsh():
    if os.environ.get("PWSH"):
        return os.environ["PWSH"]
    destino = CACHE / "pwsh"
    if not (destino / "pwsh").exists():
        imagen = "mcr.microsoft.com/powershell:lts-7.4-ubuntu-22.04"
        if subprocess.run(["docker", "image", "inspect", imagen], capture_output=True).returncode:
            sys.exit("Falta PowerShell: definí PWSH o tené la imagen de Docker " + imagen)
        cid = subprocess.run(["docker", "create", imagen], capture_output=True, text=True, check=True).stdout.strip()
        destino.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["docker", "cp", f"{cid}:/opt/microsoft/powershell/7-lts", str(destino)], check=True, capture_output=True)
        subprocess.run(["docker", "rm", cid], capture_output=True)
    return str(destino / "pwsh")


def conseguir_pg17():
    """PostgreSQL 17.10 para Linux, del mismo paquete npm que la versión de Windows (verificado por sha512)."""
    destino = CACHE / "pg17"
    if not (destino / "bin" / "postgres").exists():
        url, sha512 = PG17_LINUX
        datos = urllib.request.urlopen(url, timeout=120).read()
        assert hashlib.sha512(datos).hexdigest() == sha512, "el paquete de PostgreSQL bajado no coincide"
        tmp = CACHE / "pg17.tmp"
        shutil.rmtree(tmp, ignore_errors=True)
        tmp.mkdir(parents=True)
        (tmp / "pg.tgz").write_bytes(datos)
        with tarfile.open(tmp / "pg.tgz") as t:
            t.extractall(tmp, filter="tar")
        pkg = tmp / "package"
        for e in json.loads((pkg / "native" / "pg-symlinks.json").read_text()):
            real, enlace = pkg / e["source"], pkg / e["target"]
            if not enlace.exists():
                enlace.symlink_to(os.path.relpath(real, enlace.parent))
        shutil.rmtree(destino, ignore_errors=True)
        shutil.move(str(pkg / "native"), destino)
        shutil.rmtree(tmp)
    return destino


def conseguir_python():
    """Python con las mismas versiones exactas que windows/paquetes (en su variante para Linux)."""
    venv = CACHE / "venv"
    req = (RAIZ / "windows" / "paquetes" / "requisitos.txt").read_text()
    pins = [l.split()[0] for l in req.splitlines() if l and not l.startswith("#")]
    marca = venv / "requisitos.txt"
    if not marca.exists() or marca.read_text() != req:
        shutil.rmtree(venv, ignore_errors=True)
        subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True)
        subprocess.run([str(venv / "bin" / "pip"), "install", "-q", "--disable-pip-version-check", "--no-deps", *pins], check=True)
        marca.write_text(req)
    return venv / "bin" / "python"


def preparar_usuario():
    if os.geteuid() != 0:
        return None
    try:
        pwd.getpwnam(USUARIO)
    except KeyError:
        subprocess.run(["useradd", "-M", "-s", "/bin/sh", USUARIO], check=True)
    return USUARIO


PWSH = conseguir_pwsh()
PG17 = conseguir_pg17()
PYTHON = conseguir_python()
usuario = preparar_usuario()
subprocess.run(["chmod", "-R", "a+rX", str(CACHE)], check=True)

base = pathlib.Path(tempfile.mkdtemp(prefix="rk_portable_"))
copia = base / "sistema_ranking"            # la carpeta que la persona descomprime del ZIP
perfil = base / "perfil"                    # %USERPROFILE%
localapp = perfil / "AppData" / "Local"     # %LOCALAPPDATA%
inst = localapp / "RankingDigital"
shutil.copytree(RAIZ, copia, ignore=shutil.ignore_patterns(".env", "exportacion", "__pycache__", "tests"))

# Componentes "ya instalados": atajos con nombre .exe a PostgreSQL 17 y al Python de esta máquina.
runtime = inst / "runtime"
(runtime / "pgsql" / "bin").mkdir(parents=True)
(runtime / "python").mkdir(parents=True)
atajos = {runtime / "pgsql" / "bin" / "pg_ctl.exe": f'exec "{PG17}/bin/pg_ctl" "$@"',
          runtime / "pgsql" / "bin" / "initdb.exe": f'exec "{PG17}/bin/initdb" "$@"',
          runtime / "pgsql" / "bin" / "postgres.exe": f'exec "{PG17}/bin/postgres" "$@"',
          runtime / "python" / "python.exe": f'exec "{PYTHON}" "$@"',
          # pythonw.exe (la API, sin ventana): en una sesión propia, para que siga viva al cerrar la consola, como en Windows.
          runtime / "python" / "pythonw.exe": f'exec setsid "{PYTHON}" "$@" < /dev/null > /dev/null 2>&1'}
for ruta, cuerpo in atajos.items():
    ruta.write_text("#!/bin/sh\n" + cuerpo + "\n")
    ruta.chmod(0o755)
comun = (copia / "windows" / "comun.ps1").read_text(encoding="utf-8-sig")
shas = re.findall(r"Sha256 = '([0-9a-f]{64})'", comun)
(runtime / "version.txt").write_text(
    f"{shas[0]} {shas[1]} {hashlib.sha256((copia / 'windows' / 'paquetes' / 'requisitos.txt').read_bytes()).hexdigest()}")

# OneDrive con los CSV del historial por su nombre original, salvo uno (tiene que bajarse del bucket).
backoffice = perfil / "OneDrive - Sony" / "SMP-Administration Argentina - Documents" / "Latam" / "Backoffice"
carpetas = [backoffice / "Charts historicos Youtube", backoffice / "Charts historicos_spotify"]
for c in carpetas:
    c.mkdir(parents=True)
registrados = sql(ORIGEN, "select string_agg(name, chr(10) order by name) from storage.objects").splitlines()
originales = dict(l.split("|", 1) for l in sql(ORIGEN, "select file_path || '|' || filename from csv_uploads where file_path is not null").splitlines())
for i, n in enumerate(registrados[1:]):
    shutil.copyfile(STORAGE_ORIGEN / "csv-uploads" / n, carpetas[i % 2] / originales.get(n, n.rsplit("/", 1)[-1]))
if usuario:
    subprocess.run(["chown", "-R", usuario, str(base)], check=True)
    base.chmod(0o755)

srv, pedidos = supabase_falso.iniciar(ORIGEN, STORAGE_ORIGEN, CLAVE)
URL_SB = f"http://127.0.0.1:{srv.server_port}"


def powershell(script, *argumentos, timeout=300):
    # Sin las variables del proxy de este entorno de pruebas (su certificado solo lo lee root).
    entorno = (f"env -u SSL_CERT_FILE -u REQUESTS_CA_BUNDLE -u CURL_CA_BUNDLE -u NODE_EXTRA_CA_CERTS "
               f"LOCALAPPDATA='{localapp}' USERPROFILE='{perfil}' HOME='{perfil}'")
    cmd = f"cd '{copia}' && exec {entorno} '{PWSH}' -NoProfile -File '{copia}/windows/{script}' {' '.join(argumentos)}"
    argv = ["su", usuario, "-s", "/bin/sh", "-c", cmd] if usuario else ["/bin/sh", "-c", cmd]
    p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", timeout=timeout, dimensions=(50, 250))
    p.logfile_read = open(base / f"{script}.log", "a", encoding="utf-8")
    return p


def esperar(p, patrones):
    """Como p.expect, pero contesta la consulta de posición del cursor (ESC[6n) que hace PowerShell en Linux
    (en Windows la contesta la consola sola)."""
    lista = patrones if isinstance(patrones, list) else [patrones]
    while True:
        i = p.expect(lista + ["\x1b\\[6n"])
        if i == len(lista):
            p.send("\x1b[1;1R")
            continue
        return i


def config():
    return dict(l.split("=", 1) for l in (inst / "config.env").read_text().splitlines() if "=" in l)


def url_nueva():
    c = config()
    return f"postgresql://postgres:{c['POSTGRES_PASSWORD']}@127.0.0.1:{c['PUERTO_BASE']}/ranking"


def api(ruta=""):
    return f"http://localhost:{config()['PUERTO']}{ruta}"


def login(email, clave):
    try:
        return httpx.post(api("/auth/login"), json={"email": email, "password": clave})
    except httpx.HTTPError as e:
        return httpx.Response(599, text=str(e))


def texto(nombre):
    return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[=>]", "", (base / nombre).read_text())


def pg_funcionando():
    r = subprocess.run(["su", usuario, "-s", "/bin/sh", "-c", f"'{PG17}/bin/pg_ctl' status -D '{inst}/datos/pg'"] if usuario
                       else [f"{PG17}/bin/pg_ctl", "status", "-D", str(inst / "datos" / "pg")], capture_output=True)
    return r.returncode == 0


exito = False
try:
    # ================================================================ 1_INSTALAR.bat
    p = powershell("instalar.ps1")
    esperar(p, r"Crear ahora un usuario administrador nuevo\? \(S/N\)"); p.sendline("S")
    esperar(p, "Email"); p.sendline("jefe@nuevo.local")
    esperar(p, "Oficina"); p.sendline("AR")
    esperar(p, "Contraseña nueva"); p.sendline("clave-jefe-12345")
    esperar(p, "Repetila"); p.sendline("clave-jefe-12345")
    esperar(p, "Presiona Enter para cerrar"); p.sendline("")
    esperar(p, pexpect.EOF)
    log = texto("instalar.ps1.log")
    c = config()
    check("instalar: claves internas al azar y puertos libres", all(len(c[k]) == 64 for k in ("POSTGRES_PASSWORD", "AUTHENTICATOR_PASSWORD", "JWT_SECRET"))
          and c["PUERTO"].isdigit() and c["PUERTO_BASE"].isdigit(), log[-1500:])
    check("instalar: la base usa C.UTF-8 (como Supabase)", sql(url_nueva(), "select datlocprovider::text || datlocale from pg_database where datname = 'ranking'") == "bC.UTF-8")
    check("instalar: la base escucha solo en esta PC", sql(url_nueva(), "show listen_addresses") == "127.0.0.1")
    r = subprocess.run([sys.executable, str(RAIZ / "tests" / "comparar_con_supabase.py")], capture_output=True, text=True,
                       env=dict(os.environ, PGURL=url_nueva()))
    check("instalar: estructura idéntica a la de Supabase (151 objetos)", r.returncode == 0 and "idénticos en la base propia: 151" in r.stdout,
          r.stdout[-600:] + r.stderr[-300:])
    check("instalar: el sistema responde", httpx.get(api("/health")).status_code == 200, log[-1500:])
    check("instalar: el admin creado entra", login("jefe@nuevo.local", "clave-jefe-12345").status_code == 200, log[-1500:])
    check("instalar: sirve el front", "tempo-client.js" in httpx.get(api("/")).text)
    check("instalar: el programa quedó copiado fuera de la carpeta del ZIP", (inst / "app" / "api" / "app.py").exists()
          and not (inst / "app" / "tests").exists())

    # ================================================================ 2_MIGRAR_DESDE_SUPABASE.bat
    p = powershell("migrar.ps1")
    esperar(p, "URL del proyecto"); p.sendline(URL_SB)
    esperar(p, "service_role key"); p.sendline(CLAVE)
    esperar(p, "Agregar otra carpeta"); p.sendline("")
    esperar(p, r"Borrarlos y cargar lo de Supabase\? \(S/N\)"); p.sendline("S")
    esperar(p, "1 archivos del historial no estan en esas carpetas")
    esperar(p, "Opcion"); p.sendline("1")
    while esperar(p, [r"Poner contrasena a (\S+) ahora\? \(S/N\)", "Migracion completa"]) == 0:
        if p.match.group(1) == "admin@prueba.local":
            p.sendline("S")
            esperar(p, "Contraseña nueva"); p.sendline("clave-migrada-123")
            esperar(p, "Repetila"); p.sendline("clave-migrada-123")
        else:
            p.sendline("N")
    esperar(p, "Presiona Enter para cerrar"); p.sendline("")
    esperar(p, pexpect.EOF)
    log = texto("migrar.ps1.log")
    check("migrar: termina con 'Migracion completa'", "Migracion completa" in log, log[-2500:])
    for t in sql(ORIGEN, "select string_agg(tablename, ' ') from pg_tables where schemaname='public' and tablename not in ('envios', 'envio_obras')").split():
        q = f"select count(*) || ':' || coalesce(md5(string_agg(x::text, '|' order by x::text)), '') from public.{t} x"
        check(f"migrar: tabla {t} idéntica", sql(ORIGEN, q) == sql(url_nueva(), q))
    check("migrar: los usuarios de Supabase reemplazan al creado en la instalación",
          sql(url_nueva(), "select string_agg(email, ',' order by email) from auth.users") ==
          sql(ORIGEN, "select string_agg(email, ',' order by email) from auth.users"))
    r = login("admin@prueba.local", "clave-migrada-123")
    check("migrar: el usuario entra con la contraseña nueva", r.status_code == 200, r.text)
    tok = {"Authorization": "Bearer " + r.json().get("access_token", "")}
    r2 = httpx.get(api("/rest/app_users"), params={"select": "app_role", "user_id": "eq." + r.json()["user"]["id"]}, headers=tok)
    check("migrar: conserva su rol", r2.json() == [{"app_role": "admin"}], r2.text)
    almacen = inst / "datos" / "archivos" / "csv-uploads"
    check("migrar: todo el historial de archivos (OneDrive + 1 del bucket), idéntico",
          {str(f.relative_to(almacen)): hashlib.sha256(f.read_bytes()).hexdigest() for f in almacen.rglob("*") if f.is_file()} ==
          {n: hashlib.sha256((STORAGE_ORIGEN / "csv-uploads" / n).read_bytes()).hexdigest() for n in registrados})
    bajadas = [x for x in pedidos if x.startswith("/storage/v1/object/csv-uploads/")]
    check("migrar: del bucket bajó solo el que faltaba", bajadas and all(registrados[0].split("/")[-1] in x for x in bajadas), bajadas)
    firma = httpx.post(api(f"/storage/sign/csv-uploads/{registrados[1]}"), json={"expiresIn": 60}, headers=tok).json()
    bajado = httpx.get(api(firma.get("signedUrl", "")))
    check("migrar: desde el historial se descarga el archivo original",
          bajado.status_code == 200 and bajado.content == (STORAGE_ORIGEN / "csv-uploads" / registrados[1]).read_bytes(), (firma, bajado.status_code))
    check("migrar: sin carga automática de YouTube (los charts se cargan a mano)", "YOUTUBE_CRON" not in config()
          and "Horario" not in log and "YouTube" not in (inst / "logs" / "api.log").read_text(encoding="utf-8"), config())
    filtrada = [str(f) for f in base.rglob("*") if f.is_file() and not f.name.endswith(".log") and CLAVE.encode() in f.read_bytes()]
    check("migrar: la service_role key no quedó guardada en ningún archivo", not filtrada, filtrada)

    # ================================================================ USUARIOS.bat
    p = powershell("usuarios.ps1")
    esperar(p, "Opcion"); p.sendline("1")
    esperar(p, "Email"); p.sendline("nueva@prueba.local")
    esperar(p, "Rol"); p.sendline("auditor")
    esperar(p, "Oficina"); p.sendline("")
    esperar(p, "Contraseña nueva"); p.sendline("clave-nueva-1234")
    esperar(p, "Repetila"); p.sendline("clave-nueva-1234")
    esperar(p, "Hecho"); esperar(p, "Opcion"); p.sendline("4")
    esperar(p, "Email"); p.sendline("estandar@prueba.local")
    esperar(p, "Hecho"); esperar(p, "Opcion"); p.sendline("0")
    esperar(p, pexpect.EOF)
    log = texto("usuarios.ps1.log")
    check("usuarios: el listado muestra los usuarios migrados", "admin@prueba.local" in log and "auditor@prueba.local" in log, log[-1500:])
    check("usuarios: crear un auditor desde el menú", login("nueva@prueba.local", "clave-nueva-1234").status_code == 200)
    check("usuarios: bloquear desde el menú", sql(url_nueva(), "select banned_until > now() from auth.users where email='estandar@prueba.local'") == "t")

    # ================================================================ DETENER.bat
    p = powershell("detener.ps1")
    esperar(p, "Presiona Enter para cerrar"); p.sendline(""); esperar(p, pexpect.EOF)
    check("detener: apaga la API y la base", login("admin@prueba.local", "clave-migrada-123").status_code == 599 and not pg_funcionando(),
          texto("detener.ps1.log")[-800:])

    # ================================================================ ABRIR_SISTEMA.bat (y el arranque automático)
    p = powershell("abrir.ps1", "-SinNavegador"); esperar(p, pexpect.EOF)
    check("abrir: vuelve a levantar todo y los datos siguen", login("admin@prueba.local", "clave-migrada-123").status_code == 200,
          texto("abrir.ps1.log")[-800:])

    # ================================================================ 1_INSTALAR.bat de nuevo (ZIP nuevo = actualización)
    (copia / "front" / "index.html").write_text((copia / "front" / "index.html").read_text() + "<!-- version nueva -->")
    clave_antes = config()["POSTGRES_PASSWORD"]
    usuarios_antes = sql(url_nueva(), "select count(*) from auth.users")
    p = powershell("instalar.ps1")
    esperar(p, "Presiona Enter para cerrar"); p.sendline(""); esperar(p, pexpect.EOF)
    log = texto("instalar.ps1.log")
    check("reinstalar: conserva claves, datos y usuarios sin preguntar",
          config()["POSTGRES_PASSWORD"] == clave_antes and f"Hay {usuarios_antes} usuarios cargados" in log.split("1/5")[-1]
          and login("admin@prueba.local", "clave-migrada-123").status_code == 200, log[-1500:])
    check("reinstalar: actualiza el programa", "version nueva" in httpx.get(api("/")).text)
    exito = not fallas
finally:
    srv.shutdown()
    try:
        powershell("detener.ps1").sendline("")
    except Exception:  # noqa: BLE001
        pass
    subprocess.run(["pkill", "-u", usuario or str(os.getuid()), "-f", "servir.py"], capture_output=True)
    if pg_funcionando():
        subprocess.run(["su", usuario, "-s", "/bin/sh", "-c", f"'{PG17}/bin/pg_ctl' stop -D '{inst}/datos/pg' -m immediate"] if usuario
                       else [f"{PG17}/bin/pg_ctl", "stop", "-D", str(inst / "datos" / "pg"), "-m", "immediate"], capture_output=True)
    if exito:
        shutil.rmtree(base, ignore_errors=True)
    else:
        print(f"Registros de la consola en {base}/*.log y {inst}/logs")

print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
