"""
Prueba la obtención de los componentes de la versión portable de Windows con los archivos REALES (Python 3.12 de
NuGet y PostgreSQL 17 de npm), usando las funciones de windows/comun.ps1 en PowerShell:
- usa un archivo ya bajado (windows\\paquetes, Descargas) solo si su sha256 coincide; si no, lo baja;
- rechaza una descarga alterada y no deja restos; si no se puede bajar, explica de dónde bajarlo a mano;
- al descomprimir, deja PostgreSQL y Python con los programas y extensiones que el sistema necesita.
Las descargas salen de un servidor local que sirve los archivos reales (bajados y verificados una vez, en caché).

Variables: PWSH (PowerShell), CACHE_PRUEBAS (caché de descargas).
"""
import hashlib
import http.server
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.request

RAIZ = pathlib.Path(__file__).resolve().parents[1]
CACHE = pathlib.Path(os.environ.get("CACHE_PRUEBAS", "/var/tmp/rk_pruebas_cache"))
PWSH = os.environ.get("PWSH") or str(CACHE / "pwsh" / "pwsh")
fallas = []


def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + nombre + ("" if cond else f"  -> {extra}"))
    if not cond:
        fallas.append(nombre)


comun = (RAIZ / "windows" / "comun.ps1").read_text(encoding="utf-8-sig")
componentes = {}
for nombre, archivo, sha, url in re.findall(
        r"(\w+)\s*= @\{ Archivo = '([^']+)'; Sha256 = '([0-9a-f]{64})'\s*Url = '([^']+)'", comun.replace("\r", "")):
    componentes[nombre] = {"archivo": archivo, "sha": sha, "url": url}
check("comun.ps1 declara Python y PostgreSQL con su sha256", set(componentes) == {"python", "pgsql"}, componentes)

reales = CACHE / "componentes"
reales.mkdir(parents=True, exist_ok=True)
for c in componentes.values():
    f = reales / c["archivo"]
    if not f.exists() or hashlib.sha256(f.read_bytes()).hexdigest() != c["sha"]:
        datos = urllib.request.urlopen(c["url"], timeout=300).read()
        check(f"el archivo publicado {c['archivo']} coincide con el sha256 fijado", hashlib.sha256(datos).hexdigest() == c["sha"])
        f.write_bytes(datos)

pedidos = []
modo = {"alterar": set(), "caido": set()}


class Servidor(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        nombre = self.path.lstrip("/")
        pedidos.append(nombre)
        if nombre in modo["caido"] or not (reales / nombre).exists():
            self.send_response(404); self.end_headers(); return
        datos = (reales / nombre).read_bytes()
        if nombre in modo["alterar"]:
            datos = datos[:-1] + bytes([datos[-1] ^ 1])
        self.send_response(200); self.send_header("Content-Length", str(len(datos))); self.end_headers()
        self.wfile.write(datos)

    def log_message(self, *a):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Servidor)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = pathlib.Path(tempfile.mkdtemp(prefix="rk_comp_"))
copia = base / "sistema_ranking"
shutil.copytree(RAIZ, copia, ignore=shutil.ignore_patterns("tests", "__pycache__", ".env", "exportacion"))
descargas_usuario = base / "perfil" / "Downloads"
descargas_usuario.mkdir(parents=True)


def powershell(cuerpo):
    script = f"""
$env:LOCALAPPDATA = '{base / "local"}'; $env:USERPROFILE = '{base / "perfil"}'
. '{copia / "windows" / "comun.ps1"}'
function Fallar($t) {{ throw "FALLAR: $t" }}
$Componentes.python.Url = 'http://127.0.0.1:{srv.server_port}/{componentes["python"]["archivo"]}'
$Componentes.pgsql.Url = 'http://127.0.0.1:{srv.server_port}/{componentes["pgsql"]["archivo"]}'
{cuerpo}
"""
    r = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-Command", script], capture_output=True, text=True, timeout=600)
    return r.returncode, r.stdout + r.stderr


py, pg = componentes["python"]["archivo"], componentes["pgsql"]["archivo"]
# 1) Python ya bajado con el navegador (Descargas, correcto); PostgreSQL con una copia alterada en Descargas.
shutil.copyfile(reales / py, descargas_usuario / py)
(descargas_usuario / pg).write_bytes(b"no es el archivo")
codigo, salida = powershell("""
$a = Obtener-Componente $Componentes.python; $b = Obtener-Componente $Componentes.pgsql
Write-Output "PY=$a"; Write-Output "PG=$b"
""")
check("usa el archivo de Descargas si su sha256 coincide, sin bajarlo", codigo == 0 and f"PY={descargas_usuario / py}" in salida and py not in pedidos, salida[-800:])
check("descarta la copia alterada de Descargas y lo baja", f"PG={base / 'local' / 'RankingDigital' / 'descargas' / pg}" in salida and pg in pedidos, salida[-800:])

# 2) Descomprimir los componentes reales y revisar que esté lo que el sistema usa.
codigo, salida = powershell("Instalar-Componente 'pgsql'; Instalar-Componente 'python'; Write-Output 'LISTO'")
rt = base / "local" / "RankingDigital" / "runtime"
necesarios = ["pgsql/bin/pg_ctl.exe", "pgsql/bin/initdb.exe", "pgsql/bin/postgres.exe", "pgsql/lib/pgcrypto.dll",
              "pgsql/lib/unaccent.dll", "pgsql/lib/uuid-ossp.dll", "pgsql/lib/plpgsql.dll", "pgsql/share/extension/pgcrypto.control",
              "pgsql/share/extension/unaccent.control", "pgsql/share/extension/uuid-ossp.control", "pgsql/share/tsearch_data/unaccent.rules",
              "python/python.exe", "python/pythonw.exe", "python/Lib/ensurepip/__init__.py", "python/Lib/site-packages"]
faltan = [n for n in necesarios if not (rt / n).exists()]
check("PostgreSQL y Python quedan con todo lo necesario", codigo == 0 and "LISTO" in salida and not faltan, (faltan, salida[-800:]))
check("no quedan carpetas temporales", not list(rt.glob("*.tmp")), list(rt.glob("*")))

# 2b) Si Windows no deja correr los programas (directiva de la empresa), el aviso dice qué pedirle a IT.
#     Acá los .exe reales de Windows no corren (estamos en Linux): es el mismo caso que un bloqueo.
codigo, salida = powershell("Probar-Programas; Write-Output 'NO DEBERIA LLEGAR'")
check("si Windows bloquea los programas, lo explica y dice qué pedirle a IT", codigo != 0 and "Windows no deja correr Python" in salida
      and "directiva de grupo" in salida and "NO DEBERIA LLEGAR" not in salida, salida[-600:])

# 3) Descarga alterada en el camino: se rechaza, no queda el archivo y se explica cómo bajarlo a mano.
shutil.rmtree(base / "local" / "RankingDigital" / "descargas")
(descargas_usuario / pg).unlink()
modo["alterar"].add(pg)
codigo, salida = powershell("Obtener-Componente $Componentes.pgsql")
check("una descarga alterada se rechaza y explica de dónde bajarlo", codigo != 0 and "FALLAR: No se pudo bajar" in salida
      and "no coincide con el esperado" in salida and componentes["pgsql"]["archivo"] in salida, salida[-800:])
check("y no deja el archivo alterado", not (base / "local" / "RankingDigital" / "descargas" / pg).exists())

# 4) Sin conexión: mismo aviso, con el link.
modo["caido"].add(pg)
codigo, salida = powershell("Obtener-Componente $Componentes.pgsql")
check("sin conexión avisa con el link para bajarlo con el navegador", codigo != 0 and f"/{pg}" in salida, salida[-500:])

srv.shutdown()
if not fallas:
    shutil.rmtree(base, ignore_errors=True)
print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
