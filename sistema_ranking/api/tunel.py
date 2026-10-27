"""
Acceso desde otras computadoras (bash ranking.sh compartir): publica la aplicación con un enlace HTTPS fijo
(https://<tunel>-8000.<región>.devtunnels.ms) mediante Microsoft Dev Tunnels, sin abrir puertos en la PC ni pedir
permisos de administrador. La conexión sale de esta PC hacia Microsoft (como OneDrive o Teams).

    TUNEL_ACCESO=empresa     solo entran personas con cuenta Microsoft de la empresa (el mismo inicio de sesión de
                             Outlook/Teams); después, el usuario y la contraseña del sistema.
    TUNEL_ACCESO=cualquiera  cualquiera con el enlace llega a la pantalla de ingreso del sistema.

Corre en el servicio "tunel" de compose, dentro de la red de la API (network_mode: service:api): el puerto 8000 de la
API es su localhost, así que la API sigue sin escuchar fuera de la PC. Informa al Panel de control (panel.latido).

    python tunel.py --descargar   baja la herramienta de Microsoft (devtunnel) al volumen del servicio
    python tunel.py --login       inicia sesión con la cuenta de la empresa (código en microsoft.com/devicelogin)
    python tunel.py --servicio    crea el túnel si hace falta y lo mantiene abierto (reintenta solo)
"""
import collections
import json
import logging
import os
import re
import stat
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

log = logging.getLogger("tunel")
BIN = Path(os.environ.get("TUNEL_BIN", "/tunel/devtunnel"))
DESCARGA = os.environ.get("TUNEL_DESCARGA", "https://aka.ms/TunnelsCliDownload/linux-x64")
PUERTO = int(os.environ.get("TUNEL_PUERTO", "8000"))
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


def dt(*args, timeout=120):
    r = subprocess.run([str(BIN), *args], capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def con_sesion():
    codigo, salida = dt("user", "show")
    return codigo == 0 and not re.search(r"not logged in|no user|not signed", salida, re.I)


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
                             bufsize=1)
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
    elif accion == "--login":
        descargar()
        if con_sesion():
            print("Ya hay una sesión de Microsoft iniciada.")
        else:
            print("Ingresá el código que aparece abajo en https://microsoft.com/devicelogin con tu cuenta de la empresa.")
            sys.exit(subprocess.call([str(BIN), "user", "login", "-d"]))
    elif accion == "--servicio":
        servicio(os.environ["PGURL"])
    else:
        sys.exit(__doc__)
