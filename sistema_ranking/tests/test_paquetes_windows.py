"""
Revisa que windows/paquetes alcance para instalar la API en Windows sin internet:
- cada requisito de api/requirements.txt y todas sus dependencias (evaluando las condiciones como en Windows con
  Python 3.12, que es lo que pip no hace al bajar desde Linux: así se colaba la falta de colorama) tienen su wheel;
- cada wheel sirve para Windows 64 bits / Python 3.12;
- requisitos.txt nombra exactamente esos wheels con su sha256.

Para regenerar los paquetes (desde cualquier sistema):
    pip download --only-binary=:all: --platform win_amd64 --python-version 3.12 --implementation cp \
        -d windows/paquetes -r api/requirements.txt
  más los que esta prueba diga que faltan (con --no-deps), y luego rehacer requisitos.txt con sus hashes.
"""
import email.parser
import hashlib
import pathlib
import sys
import zipfile

from packaging.markers import default_environment
from packaging.requirements import Requirement
from packaging.utils import canonicalize_name, parse_wheel_filename

RAIZ = pathlib.Path(__file__).resolve().parents[1]
PAQ = RAIZ / "windows" / "paquetes"
WINDOWS = dict(default_environment(), sys_platform="win32", platform_system="Windows", os_name="nt",
               platform_machine="AMD64", python_version="3.12", python_full_version="3.12.10",
               implementation_name="cpython", platform_python_implementation="CPython")
fallas = []


def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + nombre + ("" if cond else f"  -> {extra}"))
    if not cond:
        fallas.append(nombre)


ruedas = {}
for w in sorted(PAQ.glob("*.whl")):
    nombre, version, _, tags = parse_wheel_filename(w.name)
    sirve = any(t.interpreter in ("py3", "py2.py3", "cp312") or t.interpreter.startswith("py3") for t in tags) and \
        any(t.platform in ("any", "win_amd64") for t in tags) and any(t.abi in ("none", "cp312", "abi3") for t in tags)
    check(f"{w.name} sirve para Windows 64 bits / Python 3.12", sirve, [str(t) for t in tags])
    with zipfile.ZipFile(w) as z:
        meta = next(n for n in z.namelist() if n.endswith(".dist-info/METADATA"))
        reqs = email.parser.Parser().parsestr(z.read(meta).decode()).get_all("Requires-Dist") or []
    ruedas[canonicalize_name(nombre)] = (version, reqs, w)

pendientes = [Requirement(l.split("#")[0].strip()) for l in (RAIZ / "api" / "requirements.txt").read_text().splitlines()
              if l.split("#")[0].strip()]
vistos, faltan = set(), []
while pendientes:
    r = pendientes.pop()
    if r.marker and not r.marker.evaluate(dict(WINDOWS, extra="")):
        continue
    clave = (canonicalize_name(r.name), tuple(sorted(r.extras)))
    if clave in vistos:
        continue
    vistos.add(clave)
    if clave[0] not in ruedas:
        faltan.append(str(r))
        continue
    version, reqs, _ = ruedas[clave[0]]
    if not r.specifier.contains(str(version), prereleases=True):
        faltan.append(f"{r} (hay {version})")
    for texto in reqs:
        dep = Requirement(texto)
        # Las dependencias de un extra solo cuentan si ese extra fue pedido.
        if dep.marker and not any(dep.marker.evaluate(dict(WINDOWS, extra=e)) for e in (r.extras or {""})):
            continue
        pendientes.append(Requirement(f"{dep.name}{'[' + ','.join(dep.extras) + ']' if dep.extras else ''}{dep.specifier}"))
check("todas las dependencias para Windows tienen su paquete", not faltan, faltan)

usados = {n for n, _ in vistos}
check("no sobran paquetes", set(ruedas) <= usados, sorted(set(ruedas) - usados))

lineas = [l for l in (PAQ / "requisitos.txt").read_text().splitlines() if l and not l.startswith("#")]
esperado = {f"{n}=={v} --hash=sha256:{hashlib.sha256(w.read_bytes()).hexdigest()}" for n, (v, _, w) in ruedas.items()}
check("requisitos.txt nombra cada paquete con su sha256", set(lineas) == esperado, set(lineas) ^ esperado)

print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
