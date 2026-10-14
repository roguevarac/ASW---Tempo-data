"""
Prueba los scripts de Windows (windows/*.ps1, los que corren los .bat) de punta a punta con PowerShell real,
como lo haría una persona: instalar, migrar desde un Supabase simulado tomando el historial de carpetas tipo
OneDrive, poner contraseñas, programar YouTube, administrar usuarios y entrar al sistema.

PowerShell corre en un contenedor que usa el Docker de esta máquina; las respuestas se escriben en su consola.
Diferencias con una PC con Windows, solo de esta prueba: rutas de Linux, otro puerto, y la imagen de la API se arma
antes, desde afuera (en el entorno de pruebas hay un proxy con certificado propio).

Variables: PGHOST_URL, ORIGEN_DB, STORAGE_ORIGEN (como test_migracion.py; la base de origen con datos).
"""
import hashlib
import os
import pathlib
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
PUERTO = "8791"
IMAGEN_PS = "mcr.microsoft.com/powershell:lts-7.4-ubuntu-22.04"
fallas = []


def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + nombre + ("" if cond else f"  -> {extra}"))
    if not cond:
        fallas.append(nombre)


def sql(url, q):
    return subprocess.run(["psql", url, "-At", "-c", q], capture_output=True, text=True, check=True).stdout.strip()


base = pathlib.Path(tempfile.mkdtemp(prefix="rk_win_"))
copia = base / "rk_prueba_windows"          # la carpeta que la persona descomprime del ZIP
perfil = base / "perfil"                     # %USERPROFILE%
shutil.copytree(RAIZ, copia, ignore=shutil.ignore_patterns(".env", "exportacion", "__pycache__"))
# Solo para este entorno: otro puerto y confiar en el proxy al armar la imagen.
(copia / ".env.example").write_text((copia / ".env.example").read_text().replace("PUERTO=8000", f"PUERTO={PUERTO}"))
# Imagen de la API para la prueba. Si hay una imagen local con las dependencias (IMAGEN_BASE), se le copia encima el
# código actual sin bajar nada; si no, se arma el Dockerfile confiando en el certificado del proxy del entorno.
IMAGEN_BASE = os.environ.get("IMAGEN_BASE", "sistema_ranking-api:latest")
if subprocess.run(["docker", "image", "inspect", IMAGEN_BASE], capture_output=True).returncode == 0:
    (copia / "Dockerfile.sandbox").write_text(
        f"FROM {IMAGEN_BASE}\nUSER root\nCOPY api/ /app/api/\nCOPY admin/ /app/admin/\nCOPY migracion/ /app/migracion/\n"
        "COPY front/index.html front/tempo-client.js front/papaparse.min.js /app/front/\nUSER ranking\n")
    armar = ["docker", "build", "-q"]
    entorno_armado = dict(os.environ, DOCKER_BUILDKIT="0")
else:
    (copia / "Dockerfile.sandbox").write_text((copia / "Dockerfile").read_text().replace(
        "RUN pip install", "COPY --from=ca ca-bundle.crt /tmp/ca.crt\nRUN PIP_CERT=/tmp/ca.crt pip install"))
    armar = ["docker", "build", "-q", "--build-context", "ca=/root/.ccr"]
    entorno_armado = os.environ
# La imagen se arma desde afuera (el cliente de Docker dentro del contenedor de PowerShell no tiene el certificado del
# proxy de este entorno) y el docker compose del script la usa ya armada.
r = subprocess.run(armar + ["-f", str(copia / "Dockerfile.sandbox"), "-t", "rk-prueba-api:sandbox", str(copia)],
                   capture_output=True, text=True, env=entorno_armado)
if r.returncode:
    sys.exit("No se pudo armar la imagen de prueba:\n" + r.stdout[-1000:] + r.stderr[-1000:])
(copia / "docker-compose.yml").write_text((copia / "docker-compose.yml").read_text().replace(
    "    build: .\n", "    image: rk-prueba-api:sandbox\n    pull_policy: never\n"))

# OneDrive con los CSV del historial por su nombre original, salvo uno (tiene que bajarse del bucket).
backoffice = perfil / "OneDrive - Sony" / "SMP-Administration Argentina - Documents" / "Latam" / "Backoffice"
carpetas = [backoffice / "Charts historicos Youtube", backoffice / "Charts historicos_spotify"]
for c in carpetas:
    c.mkdir(parents=True)
registrados = sql(ORIGEN, "select string_agg(name, chr(10) order by name) from storage.objects").splitlines()
originales = dict(l.split("|", 1) for l in sql(ORIGEN, "select file_path || '|' || filename from csv_uploads where file_path is not null").splitlines())
for i, n in enumerate(registrados[1:]):
    shutil.copyfile(STORAGE_ORIGEN / "csv-uploads" / n, carpetas[i % 2] / originales.get(n, n.rsplit("/", 1)[-1]))

srv, pedidos = supabase_falso.iniciar(ORIGEN, STORAGE_ORIGEN, CLAVE, host="0.0.0.0")
gateway = subprocess.run(["docker", "network", "inspect", "bridge", "-f", "{{(index .IPAM.Config 0).Gateway}}"],
                         capture_output=True, text=True, check=True).stdout.strip()
URL_SB = f"http://{gateway}:{srv.server_port}"


def powershell(script, timeout=900):
    cmd = (f"docker run --rm -it --network host -v /var/run/docker.sock:/var/run/docker.sock "
           f"-v /usr/bin/docker:/usr/bin/docker:ro -v /usr/libexec/docker/cli-plugins:/usr/libexec/docker/cli-plugins:ro "
           f"-v /root/.ccr:/root/.ccr:ro -v {base}:{base} -e USERPROFILE={perfil} -w {copia} {IMAGEN_PS} "
           # umask 000: en Windows, Docker Desktop deja escribir en las carpetas montadas a cualquier usuario.
           f"sh -c 'umask 000 && exec pwsh -NoProfile -File {copia}/windows/{script}'")
    p = pexpect.spawn(cmd, encoding="utf-8", timeout=timeout, dimensions=(50, 250))
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


def compose(*a):
    return subprocess.run(["docker", "compose", *a], cwd=copia, capture_output=True, text=True)


def base_nueva(q):
    return compose("exec", "-T", "db", "psql", "-U", "postgres", "-d", "ranking", "-At", "-c", q).stdout.strip()


def login(email, clave):
    return httpx.post(f"http://localhost:{PUERTO}/auth/login", json={"email": email, "password": clave})


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
    log = (base / "instalar.ps1.log").read_text()
    print(log[-600:])
    check("instalar: crea la configuración con claves al azar", (copia / ".env").exists() and
          all(len(l.split("=", 1)[1]) == 64 for l in (copia / ".env").read_text().splitlines()
              if l.split("=")[0] in ("POSTGRES_PASSWORD", "AUTHENTICATOR_PASSWORD", "JWT_SECRET")), log[-1500:])
    check("instalar: el sistema responde", httpx.get(f"http://localhost:{PUERTO}/health").status_code == 200, log[-1500:])
    check("instalar: el admin creado entra", login("jefe@nuevo.local", "clave-jefe-12345").status_code == 200, log[-1500:])
    check("instalar: sirve el front", "tempo-client.js" in httpx.get(f"http://localhost:{PUERTO}/").text)

    # ================================================================ 2_MIGRAR_DESDE_SUPABASE.bat
    p = powershell("migrar.ps1")
    esperar(p, "URL del proyecto"); p.sendline(URL_SB)
    esperar(p, "service_role key"); p.sendline(CLAVE)
    esperar(p, "Agregar otra carpeta"); p.sendline("")
    esperar(p, r"Borrarlos y cargar lo de Supabase\? \(S/N\)"); p.sendline("S")
    esperar(p, "1 archivos del historial no estan en esas carpetas")
    esperar(p, "Opcion"); p.sendline("1")
    puestas = []
    while True:
        i = esperar(p, [r"Poner contrasena a (\S+) ahora\? \(S/N\)", "Horario:"])
        if i == 1:
            break
        email = p.match.group(1)
        if email == "admin@prueba.local":
            p.sendline("S")
            esperar(p, "Contraseña nueva"); p.sendline("clave-migrada-123")
            esperar(p, "Repetila"); p.sendline("clave-migrada-123")
            puestas.append(email)
        else:
            p.sendline("N")
    p.sendline("0 12 * * 5")
    esperar(p, "Presiona Enter para cerrar"); p.sendline("")
    esperar(p, pexpect.EOF)
    log = (base / "migrar.ps1.log").read_text()
    check("migrar: termina con 'Migracion completa'", "Migracion completa" in log, log[-2000:])

    for t in sql(ORIGEN, "select string_agg(tablename, ' ') from pg_tables where schemaname='public'").split():
        q = f"select count(*) || ':' || coalesce(md5(string_agg(x::text, '|' order by x::text)), '') from public.{t} x"
        check(f"migrar: tabla {t} idéntica", sql(ORIGEN, q) == base_nueva(q))
    check("migrar: los usuarios de Supabase reemplazan al creado en la instalación",
          base_nueva("select string_agg(email, ',' order by email) from auth.users") ==
          sql(ORIGEN, "select string_agg(email, ',' order by email) from auth.users"))
    r = login("admin@prueba.local", "clave-migrada-123")
    check("migrar: el usuario entra con la contraseña nueva", r.status_code == 200, r.text)
    tok = {"Authorization": "Bearer " + r.json().get("access_token", "")}
    r2 = httpx.get(f"http://localhost:{PUERTO}/rest/app_users", params={"select": "app_role", "user_id": "eq." + r.json()["user"]["id"]}, headers=tok)
    check("migrar: conserva su rol", r2.json() == [{"app_role": "admin"}], r2.text)
    hashes = compose("exec", "-T", "api", "sh", "-c", "cd /data/storage/csv-uploads && find . -type f -exec sha256sum {} +").stdout
    en_nueva = {l.split("  ", 1)[1][2:]: l.split()[0] for l in hashes.splitlines()}
    check("migrar: todo el historial de archivos (OneDrive + 1 del bucket), idéntico",
          en_nueva == {n: hashlib.sha256((STORAGE_ORIGEN / "csv-uploads" / n).read_bytes()).hexdigest() for n in registrados}, en_nueva)
    check("migrar: del bucket bajó solo el que faltaba",
          [x for x in pedidos if x.startswith("/storage/v1/object/csv-uploads/")] and
          all(registrados[0].split("/")[-1] in x for x in pedidos if x.startswith("/storage/v1/object/csv-uploads/")), pedidos)
    hist = httpx.get(f"http://localhost:{PUERTO}/rest/csv_uploads", params={"select": "file_path", "limit": "1",
                     "file_path": f"eq.{registrados[1]}"}, headers=tok).json()
    firma = httpx.post(f"http://localhost:{PUERTO}/storage/sign/csv-uploads/{registrados[1]}", json={"expiresIn": 60}, headers=tok).json()
    bajado = httpx.get(f"http://localhost:{PUERTO}{firma.get('signedUrl', '')}")
    check("migrar: desde el historial se descarga el archivo original",
          bajado.status_code == 200 and bajado.content == (STORAGE_ORIGEN / "csv-uploads" / registrados[1]).read_bytes(), (hist, firma, bajado.status_code))
    check("migrar: carga de YouTube programada en el sistema",
          compose("exec", "-T", "api", "printenv", "YOUTUBE_CRON", "YOUTUBE_CRON_TZ").stdout.split("\n")[:2] == ["0 12 * * 5", "UTC"])
    filtrada = [str(f) for f in base.rglob("*") if f.is_file() and not f.name.endswith(".log")
                and (copia / "tests") not in f.parents and CLAVE.encode() in f.read_bytes()]
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
    log = (base / "usuarios.ps1.log").read_text()
    check("usuarios: el listado muestra los usuarios migrados", "admin@prueba.local" in log and "auditor@prueba.local" in log, log[-1500:])
    check("usuarios: crear un auditor desde el menú", login("nueva@prueba.local", "clave-nueva-1234").status_code == 200)
    check("usuarios: bloquear desde el menú", base_nueva("select banned_until > now() from auth.users where email='estandar@prueba.local'") == "t")

    # ================================================================ DETENER.bat + ABRIR_SISTEMA.bat
    compose("stop")
    p = powershell("abrir.ps1"); esperar(p, pexpect.EOF); p.close()
    check("abrir: vuelve a levantar el sistema apagado y los datos siguen",
          login("admin@prueba.local", "clave-migrada-123").status_code == 200, (base / "abrir.ps1.log").read_text()[-800:])
    exito = not fallas
finally:
    srv.shutdown()
    compose("down", "-v")
    subprocess.run(["docker", "image", "rm", "-f", "rk-prueba-api:sandbox"], capture_output=True)
    if exito:
        shutil.rmtree(base, ignore_errors=True)
    else:
        print(f"Registros de la consola en {base}/*.log")

print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
