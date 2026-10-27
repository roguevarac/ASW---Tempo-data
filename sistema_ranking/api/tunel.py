"""
Acceso desde otras computadoras (bash ranking.sh compartir): publica la aplicación con un enlace HTTPS fijo
(https://<tunel>-8000.<región>.devtunnels.ms) mediante Microsoft Dev Tunnels, sin abrir puertos en la PC ni pedir
permisos de administrador. La conexión sale de esta PC hacia Microsoft (como OneDrive o Teams).

    TUNEL_ACCESO=empresa     solo entran personas con cuenta Microsoft de la empresa (el mismo inicio de sesión de
                             Outlook/Teams); después, el usuario y la contraseña del sistema.
    TUNEL_ACCESO=cualquiera  cualquiera con el enlace llega a la pantalla de ingreso del sistema.

Corre en el servicio "tunel" de compose, dentro de la red de la API (network_mode: service:api): el puerto 8000 de la
API es su localhost, así que la API sigue sin escuchar fuera de la PC. Informa al Panel de control (panel.latido).

    python tunel.py --descargar   baja la herramienta de Microsoft (devtunnel) y las librerías ICU al volumen
    python tunel.py --login       inicia sesión con la cuenta de la empresa (código en microsoft.com/devicelogin)
    python tunel.py --servicio    crea el túnel si hace falta y lo mantiene abierto (reintenta solo)
"""
import collections
import json
import logging
import os
import re
import ctypes.util
import shutil
import stat
import subprocess
import sys
import tarfile
import threading
import time
import urllib.request
from pathlib import Path

log = logging.getLogger("tunel")
BIN = Path(os.environ.get("TUNEL_BIN", "/tunel/devtunnel"))
DESCARGA = os.environ.get("TUNEL_DESCARGA", "https://aka.ms/TunnelsCliDownload/linux-x64")
PUERTO = int(os.environ.get("TUNEL_PUERTO", "8000"))
# devtunnel (.NET) necesita las librerías ICU, que la imagen no trae, y su configuración interna ignora el modo sin ICU
# (DOTNET_SYSTEM_GLOBALIZATION_INVARIANT). Se toman, en este orden: las del sistema; las ya bajadas al volumen; las del
# paquete npm de PostgreSQL embebido (el mismo origen que la versión portable de Windows: libicu*.so.60, sin
# dependencias raras); y, si npm está bloqueado, apt-get (Debian).
ICU_DIR = Path(os.environ.get("TUNEL_ICU_DIR", str(BIN.parent / "icu")))
ICU_NPM = os.environ.get("TUNEL_ICU_NPM",
                         "https://registry.npmjs.org/@embedded-postgres/linux-x64/-/linux-x64-17.10.0-beta.17.tgz")
URL_TUNEL = re.compile(r"https://[A-Za-z0-9.-]*devtunnels\.ms[^\s,]*")
SIN_SESION = re.compile(r"login|log in|sign in|unauthorized|not authenticated|expired token|401", re.I)


def tunel_id():
    t = os.environ.get("TUNEL_ID", "").strip()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{2,48}", t):
        sys.exit("Falta TUNEL_ID (se configura con: bash ranking.sh compartir).")
    return t


def descargar():
    """La herramienta devtunnel de Microsoft (un solo archivo) queda en el volumen del servicio."""
    if BIN.exists() and os.access(BIN, os.X_OK):
        return
    BIN.parent.mkdir(parents=True, exist_ok=True)
    tmp = BIN.with_suffix(".descarga")
    with urllib.request.urlopen(DESCARGA, timeout=120) as r, open(tmp, "wb") as f:
        while bloque := r.read(1 << 20):
            f.write(bloque)
    tmp.chmod(tmp.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    tmp.replace(BIN)
    log.info("Herramienta de túneles descargada.")


def icu_lista():
    """Las tres librerías con el nombre que busca .NET (libicuuc.so.60: solo la versión mayor)."""
    return all(any(re.fullmatch(rf"lib{n}\.so\.[0-9]+", f.name) for f in ICU_DIR.glob(f"lib{n}.so.*"))
               for n in ("icuuc", "icui18n", "icudata"))


def preparar_icu():
    """Deja las librerías ICU disponibles para devtunnel. Devuelve el origen (para el registro)."""
    if os.environ.get("TUNEL_SIN_ICU") == "1" or ctypes.util.find_library("icuuc"):
        return "sistema"
    if icu_lista():
        return "volumen"
    ICU_DIR.mkdir(parents=True, exist_ok=True)
    try:
        tmp = ICU_DIR / "paquete.tgz"
        with urllib.request.urlopen(ICU_NPM, timeout=300) as r, open(tmp, "wb") as f:
            while bloque := r.read(1 << 20):
                f.write(bloque)
        with tarfile.open(tmp) as t:
            miembros = [m for m in t.getmembers() if re.search(r"/lib/libicu(uc|i18n|data)\.so\.[0-9.]+$", m.name)]
            for m in sorted(miembros, key=lambda m: m.issym()):   # primero los archivos, después los enlaces
                destino = ICU_DIR / Path(m.name).name
                if m.issym():
                    destino.unlink(missing_ok=True)
                    destino.symlink_to(Path(m.linkname).name)
                elif m.isfile():
                    with t.extractfile(m) as origen, open(destino, "wb") as f:
                        shutil.copyfileobj(origen, f)
        tmp.unlink(missing_ok=True)
        for f in ICU_DIR.glob("libicu*.so.*.*"):   # npm no guarda enlaces: libicuuc.so.60 -> libicuuc.so.60.2
            corto = ICU_DIR / re.sub(r"(\.so\.[0-9]+)\..*$", r"\1", f.name)
            if not corto.exists():
                corto.symlink_to(f.name)
        if icu_lista():
            log.info("Librerías ICU descargadas (npm).")
            return "npm"
    except Exception as e:
        log.warning("No se pudieron bajar las librerías ICU de npm: %s", e)
    r = subprocess.run("apt-get update -qq && apt-get install -y -qq --no-install-recommends "
                       "$(apt-cache --names-only search '^libicu[0-9]+$' | cut -d' ' -f1 | sort -V | tail -n 1)",
                       shell=True, capture_output=True, text=True, timeout=600)
    if r.returncode == 0 and ctypes.util.find_library("icuuc"):
        return "apt"
    raise RuntimeError("No se pudieron conseguir las librerías ICU que necesita la herramienta de Microsoft "
                       "(npm y apt bloqueados por la red).")


def entorno_dt():
    e = dict(os.environ)
    if icu_lista():
        e["LD_LIBRARY_PATH"] = f"{ICU_DIR}:{e['LD_LIBRARY_PATH']}" if e.get("LD_LIBRARY_PATH") else str(ICU_DIR)
    return e


def dt(*args, timeout=120):
    log.info("devtunnel %s", " ".join(args))
    try:
        r = subprocess.run([str(BIN), *args], capture_output=True, text=True, timeout=timeout, env=entorno_dt())
    except subprocess.TimeoutExpired:
        log.warning("devtunnel %s: sin respuesta en %s s", " ".join(args), timeout)
        return 124, f"Sin respuesta de la herramienta de Microsoft en {timeout} s ({' '.join(args)})"
    salida = (r.stdout or "") + (r.stderr or "")
    if r.returncode != 0:
        log.info("  -> código %s: %s", r.returncode, salida.strip()[-500:])
    return r.returncode, salida


def con_sesion():
    codigo, salida = dt("user", "show", timeout=60)
    ok = codigo == 0 and not re.search(r"not logged in|no user|not signed", salida, re.I)
    log.info("Sesión de Microsoft: %s", salida.strip()[-300:] or f"código {codigo}")
    return ok


def preparar(tid, acceso):
    """Crea el túnel (con el mismo nombre, así el enlace no cambia), el puerto de la API y el permiso de acceso."""
    codigo, salida = dt("show", tid)
    if codigo != 0:
        codigo, salida = dt("create", tid, "--expiration", "30d")
        if codigo != 0:
            raise RuntimeError(f"No se pudo crear el túnel {tid}: {salida.strip()[-400:]}")
        log.info("Túnel %s creado.", tid)
    codigo, salida = dt("port", "create", tid, "-p", str(PUERTO), "--protocol", "http")
    if codigo != 0 and not re.search(r"already exists|conflict|ya existe", salida, re.I):
        raise RuntimeError(f"No se pudo publicar el puerto {PUERTO}: {salida.strip()[-400:]}")
    dt("access", "reset", tid)
    codigo, salida = dt("access", "create", tid, "--anonymous" if acceso == "cualquiera" else "--tenant")
    if codigo != 0:
        raise RuntimeError(f"No se pudo configurar quién puede entrar: {salida.strip()[-400:]}")


def elegir_url(texto):
    """El enlace del navegador para el puerto de la API (no el de 'inspect')."""
    urls = [u.rstrip("/.;") for u in URL_TUNEL.findall(texto) if "inspect" not in u]
    if not urls:
        return None
    con_puerto = [u for u in urls if f"-{PUERTO}." in u]
    return (con_puerto or urls)[0] + "/"


class Panel:
    """Avisos para el Panel de control. Si la base no responde, no frena el túnel."""
    def __init__(self, pgurl):
        self.pgurl, self.ultimo = pgurl, None

    def _sql(self, q, params):
        try:
            import psycopg
            with psycopg.connect(self.pgurl, autocommit=True, connect_timeout=5) as con:
                con.execute(q, params)
        except Exception as e:
            log.debug("Panel: %s", e)

    def estado(self, estado, **detalle):
        log.info("Estado: %s %s", estado, detalle.get("mensaje") or detalle.get("url") or "")
        self._sql("SELECT panel.latido('tunel', %s::jsonb)", (json.dumps({"estado": estado, **detalle}),))
        clave = (estado, detalle.get("url"))
        if clave != self.ultimo:
            self.ultimo = clave
            nivel = {"activo": "ok", "iniciando": "ok"}.get(estado, "error")
            texto = {"activo": f"Acceso desde otras computadoras activo: {detalle.get('url')}",
                     "iniciando": "Abriendo el acceso desde otras computadoras",
                     "sin_sesion": "Acceso desde otras computadoras detenido: la sesión de Microsoft venció. "
                                   "Ejecutá en Ubuntu: bash ranking.sh compartir"}.get(estado, detalle.get("mensaje", estado))
            self._sql("SELECT panel.registrar('tunel', %s, %s)", (nivel, texto))


def servicio(pgurl):
    tid, acceso = tunel_id(), os.environ.get("TUNEL_ACCESO", "empresa")
    panel = Panel(pgurl)
    while True:
        try:
            panel.estado("iniciando", acceso=acceso)
            descargar()
            preparar_icu()
            if not con_sesion():
                panel.estado("sin_sesion", acceso=acceso)
                time.sleep(300)
                continue
            preparar(tid, acceso)
        except Exception as e:
            log.warning("Túnel: %s; reintento en 60 s", e)
            panel.estado("error", acceso=acceso, mensaje=f"Acceso desde otras computadoras con error: {e}")
            time.sleep(60)
            continue
        p = subprocess.Popen([str(BIN), "host", tid], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                             bufsize=1, env=entorno_dt())
        ultimas, url = collections.deque(maxlen=30), None
        vivo = threading.Event()

        def latir():   # mientras el túnel está abierto, el Panel lo ve vivo
            while not vivo.wait(60):
                if url:
                    panel.estado("activo", acceso=acceso, url=url)
        threading.Thread(target=latir, daemon=True).start()
        for linea in p.stdout:
            ultimas.append(linea.rstrip())
            log.info("%s", linea.rstrip())
            if url is None and (u := elegir_url(linea)):
                url = u
                panel.estado("activo", acceso=acceso, url=url)
        p.wait()
        vivo.set()
        texto = "\n".join(ultimas)
        if SIN_SESION.search(texto):
            panel.estado("sin_sesion", acceso=acceso)
        else:
            panel.estado("error", acceso=acceso, mensaje="El acceso desde otras computadoras se cerró; se reabre solo. "
                                                         + texto[-300:])
        time.sleep(30)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    accion = sys.argv[1] if len(sys.argv) > 1 else "--servicio"
    if accion == "--descargar":
        try:
            descargar()
        except Exception as e:
            sys.exit(f"No se pudo descargar la herramienta de Microsoft ({DESCARGA}): {e}")
        try:
            print(f"Librerías ICU: {preparar_icu()}")
        except Exception as e:
            sys.exit(str(e))
    elif accion == "--login":
        descargar()
        preparar_icu()
        if con_sesion():
            print("Ya hay una sesión de Microsoft iniciada.")
        else:
            print("Ingresá el código que aparece abajo en https://microsoft.com/devicelogin con tu cuenta de la empresa.")
            sys.exit(subprocess.call([str(BIN), "user", "login", "-d"], env=entorno_dt()))
    elif accion == "--servicio":
        servicio(os.environ["PGURL"])
    else:
        sys.exit(__doc__)
