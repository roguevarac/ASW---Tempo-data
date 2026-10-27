"""
Acceso desde otras computadoras (api/tunel.py), con la herramienta de Microsoft simulada (tests/devtunnel_simulado.sh):
crea el túnel con el mismo nombre, publica el puerto de la API, restringe el acceso a la empresa (o lo abre con
--cualquiera), toma el enlace correcto (no el de "inspect") y lo informa al Panel de control; si la sesión de
Microsoft venció, lo avisa. También el inicio de sesión (--login).

Variables: PGURL (base con el esquema panel).
"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

PGURL = os.environ["PGURL"]
RAIZ = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RAIZ / "api"))
import tunel  # noqa: E402

fallas = []


def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + nombre + ("" if cond else f"  -> {extra}"))
    if not cond:
        fallas.append(nombre)


def sqlq(q):
    return subprocess.run(["psql", PGURL, "-At", "-c", q], capture_output=True, text=True).stdout.strip()


check("elige el enlace del puerto de la API, no el de 'inspect'",
      tunel.elegir_url("Connect via browser: https://abc-8000.brs.devtunnels.ms, https://abc.brs.devtunnels.ms") ==
      "https://abc-8000.brs.devtunnels.ms/"
      and tunel.elegir_url("Inspect network activity: https://abc-8000-inspect.brs.devtunnels.ms") is None
      and tunel.elegir_url("Hosting port: 8000") is None)

casa = pathlib.Path(tempfile.mkdtemp())
binario = casa / "devtunnel"
shutil.copy(RAIZ / "tests" / "devtunnel_simulado.sh", binario)
binario.chmod(0o755)
entorno = dict(os.environ, HOME=str(casa), TUNEL_BIN=str(binario), TUNEL_ID="auditor-rankings-prueba",
               TUNEL_ACCESO="empresa", PGURL=PGURL)


def servicio(segundos, condicion):
    sqlq("delete from panel.servicios where servicio = 'tunel'")
    p = subprocess.Popen([sys.executable, str(RAIZ / "api" / "tunel.py"), "--servicio"], env=entorno,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    fin = time.time() + segundos
    while time.time() < fin and not condicion():
        time.sleep(0.5)
    p.terminate()
    salida = p.communicate(timeout=10)[0]
    subprocess.run(["pkill", "-f", "sleep 100000"], capture_output=True)
    return salida


# --------------------------------------------------------------- sin sesión de Microsoft
salida = servicio(20, lambda: sqlq("select detalle->>'estado' from panel.servicios where servicio = 'tunel'") == "sin_sesion")
check("sin sesión de Microsoft: el Panel lo informa y no abre el túnel",
      sqlq("select detalle->>'estado' from panel.servicios where servicio = 'tunel'") == "sin_sesion"
      and "host" not in (casa / ".simulado" / "comandos").read_text()
      and "bash ranking.sh compartir" in sqlq("select mensaje from panel.eventos where servicio = 'tunel' order by id desc limit 1"),
      salida[-500:])

# --------------------------------------------------------------- inicio de sesión
r = subprocess.run([sys.executable, str(RAIZ / "api" / "tunel.py"), "--login"], env=entorno, capture_output=True, text=True)
check("--login: indica dónde ingresar el código y deja la sesión iniciada",
      r.returncode == 0 and "microsoft.com/devicelogin" in r.stdout and (casa / ".simulado" / "sesion").exists(), r.stdout + r.stderr)
r = subprocess.run([sys.executable, str(RAIZ / "api" / "tunel.py"), "--login"], env=entorno, capture_output=True, text=True)
check("--login con la sesión ya iniciada no vuelve a pedirla", r.returncode == 0 and "Ya hay una sesión" in r.stdout, r.stdout)

# --------------------------------------------------------------- túnel activo (solo cuentas de la empresa)
activo = lambda: sqlq("select detalle->>'estado' from panel.servicios where servicio = 'tunel'") == "activo"
salida = servicio(30, activo)
url = sqlq("select detalle->>'url' from panel.servicios where servicio = 'tunel'")
comandos = (casa / ".simulado" / "comandos").read_text()
check("crea el túnel con su nombre, publica el puerto 8000 de la API y lo abre",
      "create auditor-rankings-prueba --expiration 30d" in comandos and "port create auditor-rankings-prueba -p 8000 --protocol http" in comandos
      and "host auditor-rankings-prueba" in comandos, comandos)
check("el Panel recibe el enlace HTTPS del puerto de la API", url == "https://auditor-rankings-prueba-8000.brs.devtunnels.ms/", (url, salida[-500:]))
check("por defecto solo entran cuentas de la empresa", (casa / ".simulado" / "acceso").read_text().strip() == "--tenant")
check("queda registrado en la actividad del Panel",
      f"Acceso desde otras computadoras activo: {url}" in sqlq("select string_agg(mensaje, '|') from panel.eventos where servicio = 'tunel'"))

# --------------------------------------------------------------- de nuevo, con --cualquiera: mismo enlace, otro acceso
entorno["TUNEL_ACCESO"] = "cualquiera"
servicio(30, activo)
comandos = (casa / ".simulado" / "comandos").read_text()
check("al volver a abrirse reusa el mismo túnel (el enlace no cambia)",
      comandos.count("create auditor-rankings-prueba --expiration") == 1
      and sqlq("select detalle->>'url' from panel.servicios where servicio = 'tunel'") == url, comandos)
check("con --cualquiera, cualquiera con el enlace llega al ingreso", (casa / ".simulado" / "acceso").read_text().strip() == "--anonymous")

sqlq("delete from panel.servicios where servicio = 'tunel'; delete from panel.eventos where servicio = 'tunel'")
shutil.rmtree(casa, ignore_errors=True)
print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
