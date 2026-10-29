"""
Acceso desde otras computadoras: escritorio/tunel.ps1 (lo corre Windows con devtunnel.exe), probado con PowerShell y
la herramienta de Microsoft simulada (tests/devtunnel_simulado.sh). Crea el túnel con el mismo nombre, publica el
puerto del sistema, restringe el acceso a la empresa (o lo abre con "cualquiera"), toma el enlace correcto (no el de
"inspect") y deja el estado en tunel-estado.json; si la sesión de Microsoft venció, lo informa.

Variables: PWSH (PowerShell; si no está, se busca en el PATH o en la caché de pruebas).
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

RAIZ = pathlib.Path(__file__).resolve().parents[1]
PWSH = os.environ.get("PWSH") or shutil.which("pwsh") or "/var/tmp/rk_pruebas_cache/pwsh/pwsh"
if not pathlib.Path(PWSH).exists():
    print("Sin PowerShell: se saltea.")
    sys.exit(0)
fallas = []


def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + nombre + ("" if cond else f"  -> {extra}"))
    if not cond:
        fallas.append(nombre)


carpeta = pathlib.Path(tempfile.mkdtemp())
shutil.copy(RAIZ / "tests" / "devtunnel_simulado.sh", carpeta / "devtunnel.exe")
(carpeta / "devtunnel.exe").chmod(0o755)
simulado = carpeta / ".simulado"


def generar(acceso):
    t = (RAIZ / "escritorio" / "tunel.ps1").read_text(encoding="utf-8")
    t = t.replace("__TUNEL_ID__", "auditor-rankings-prueba").replace("__ACCESO__", acceso).replace("__PUERTO__", "8000")
    (carpeta / "tunel.ps1").write_bytes(b"\xef\xbb\xbf" + t.replace("\n", "\r\n").encode("utf-8"))


def estado():
    try:
        return json.loads((carpeta / "tunel-estado.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def mantener(segundos, condicion):
    (carpeta / "tunel-estado.json").unlink(missing_ok=True)
    p = subprocess.Popen([PWSH, "-NoProfile", "-File", str(carpeta / "tunel.ps1")], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
    fin = time.time() + segundos
    while time.time() < fin and not condicion():
        time.sleep(0.5)
    p.kill()
    p.wait(timeout=10)
    for proc in pathlib.Path("/proc").glob("[0-9]*"):   # el "devtunnel host" simulado (un sleep), solo ese
        try:
            if (proc / "cmdline").read_bytes() == b"sleep\x00100000\x00":
                os.kill(int(proc.name), 9)
        except OSError:
            pass


generar("empresa")
check("el script se genera sin marcadores sin completar", "__" not in (carpeta / "tunel.ps1").read_text(encoding="utf-8-sig"))

# --------------------------------------------------------------- sin sesión de Microsoft
r = subprocess.run([PWSH, "-NoProfile", "-File", str(carpeta / "tunel.ps1"), "-Preparar"], capture_output=True, text=True)
check("-Preparar sin sesión de Microsoft: lo informa y no crea nada",
      r.returncode == 2 and "Sin sesion" in r.stdout and "create" not in (simulado / "comandos").read_text(), r.stdout + r.stderr)
mantener(20, lambda: estado().get("estado") == "sin_sesion")
check("sin sesión, el estado lo indica (lo ve el Panel de control)",
      estado().get("estado") == "sin_sesion" and "bash ranking.sh compartir" in estado().get("mensaje", ""), estado())

# --------------------------------------------------------------- con sesión
(simulado / "sesion").touch()
r = subprocess.run([PWSH, "-NoProfile", "-File", str(carpeta / "tunel.ps1"), "-Preparar"], capture_output=True, text=True)
comandos = (simulado / "comandos").read_text()
check("-Preparar crea el túnel con su nombre, publica el puerto 8000 y deja entrar solo a la empresa",
      r.returncode == 0 and "Tunel preparado" in r.stdout and "create auditor-rankings-prueba --expiration 30d" in comandos
      and "port create auditor-rankings-prueba -p 8000 --protocol http" in comandos
      and (simulado / "acceso").read_text().strip() == "--tenant", r.stdout + comandos)
mantener(30, lambda: estado().get("estado") == "activo")
e = estado()
check("abre el túnel y deja el enlace HTTPS del puerto del sistema (no el de 'inspect')",
      e.get("estado") == "activo" and e.get("url") == "https://auditor-rankings-prueba-8000.brs.devtunnels.ms/"
      and e.get("acceso") == "empresa", e)
registro = (carpeta / "tunel.log").read_text(encoding="utf-8")
check("queda un registro (tunel.log)", "Connect via browser" in registro)
comandos = (simulado / "comandos").read_text()
check("al volver a abrirse reusa el mismo túnel (el enlace no cambia)",
      comandos.count("create auditor-rankings-prueba --expiration") == 1, comandos)

check("el puerto ya publicado (Conflict) no se anota como error en el registro",
      "Conflict" not in (carpeta / "tunel.log").read_text(encoding="utf-8"), (carpeta / "tunel.log").read_text(encoding="utf-8")[-800:])

# --------------------------------------------------------------- cualquiera con el enlace
generar("cualquiera")
mantener(30, lambda: estado().get("estado") == "activo")
check("con 'cualquiera', cualquiera con el enlace llega al ingreso",
      (simulado / "acceso").read_text().strip() == "--anonymous" and estado().get("acceso") == "cualquiera", estado())

shutil.rmtree(carpeta, ignore_errors=True)
print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
