"""
Prueba que Ranking Digital se pueda instalar como aplicación (PWA) y se comporte bien sin servidor, en Chromium:
- manifiesto, íconos y service worker servidos con el tipo correcto;
- Chromium la considera instalable (Page.getInstallabilityErrors sin errores, como Edge);
- con el servidor caído muestra la pantalla "iniciando o apagado" y entra sola cuando el servidor vuelve;
- nunca guarda en caché datos de la API.
Variables: BASE (URL de la API corriendo).
"""
import json
import os
import pathlib
import shutil
import struct
import sys
import tempfile

import httpx
from playwright.sync_api import sync_playwright

BASE = os.environ.get("BASE", "http://localhost:8787").rstrip("/")
fallas = []


def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + nombre + ("" if cond else f"  -> {extra}"))
    if not cond:
        fallas.append(nombre)


r = httpx.get(f"{BASE}/manifest.webmanifest")
m = r.json() if r.status_code == 200 else {}
check("manifiesto servido como application/manifest+json", r.headers.get("content-type", "").startswith("application/manifest+json"), r.headers)
check("manifiesto: abre en ventana propia, desde la raíz", m.get("display") == "standalone" and m.get("start_url") == "/" and m.get("scope") == "/", m)
for ic in m.get("icons", []):
    i = httpx.get(f"{BASE}/{ic['src']}")
    ancho, alto = struct.unpack(">II", i.content[16:24]) if i.content[:8] == b"\x89PNG\r\n\x1a\n" else (0, 0)
    check(f"ícono {ic['src']} ({ic['sizes']}, {ic.get('purpose')})", i.status_code == 200 and f"{ancho}x{alto}" == ic["sizes"])
r = httpx.get(f"{BASE}/listo.png")
check("listo.png: imagen cuando la aplicación y la base están listas (la usa la pantalla 'iniciando')",
      r.status_code == 200 and r.content[:8] == b"\x89PNG\r\n\x1a\n" and r.headers.get("cache-control") == "no-store", r.status_code)
r = httpx.get(f"{BASE}/sw.js")
check("service worker servido como JavaScript", r.status_code == 200 and "javascript" in r.headers.get("content-type", ""), r.headers)
check("los generadores (.py) de la carpeta del front no se publican", "import" not in httpx.get(f"{BASE}/generar_index.py").text[:200])

with sync_playwright() as p:
    # Perfil normal (no incógnito, que nunca deja instalar aplicaciones), como el Edge del usuario.
    perfil = tempfile.mkdtemp(prefix="rk_perfil_")
    # Como el Edge de Windows (la pantalla de espera ofrece encender el servidor solo en Windows).
    ctx = p.chromium.launch_persistent_context(perfil, executable_path="/opt/pw-browsers/chromium-1194/chrome-linux/chrome",
                                               user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                                                          "(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0")
    nav = ctx
    pag = ctx.pages[0] if ctx.pages else ctx.new_page()
    pag.goto(BASE + "/")
    pag.wait_for_selector("#loginEmail")
    activo = pag.evaluate("navigator.serviceWorker.ready.then(r => !!r.active)")
    check("service worker activo", activo)
    cdp = ctx.new_cdp_session(pag)
    errores = cdp.send("Page.getInstallabilityErrors").get("installabilityErrors", [])
    check("Chromium la considera instalable como aplicación (sin errores)", errores == [], errores)
    manifiesto = cdp.send("Page.getAppManifest")
    check("Chromium lee el manifiesto sin errores", not manifiesto.get("errors"), manifiesto.get("errors"))

    # Servidor caído (o arrancando): en lugar de un error del navegador, la pantalla propia, que se reintenta sola.
    pag.reload(); pag.wait_for_selector("#loginEmail")   # ya controlada por el service worker
    ctx.set_offline(True)
    pag.reload()
    pag.wait_for_selector("text=Auditor de Rankings Digitales está iniciando o apagado", timeout=10000)
    check("sin servidor: muestra 'Auditor de Rankings Digitales está iniciando o apagado'", True)
    pag.wait_for_selector("#botonEncender", state="visible", timeout=10000)
    check("sin servidor: ofrece encenderlo (enlace auditor-rankings:// del acceso de Windows) y sigue esperando",
          "auditor-rankings://encender" in pag.content() and "está iniciando o apagado" in pag.content())
    pag.wait_for_timeout(5000)   # pasa el intento automático de encenderlo: la pantalla sigue esperando
    check("después del intento automático de encender el servidor, la pantalla sigue esperando",
          "está iniciando o apagado" in pag.content() and pag.url.rstrip("/") == BASE, pag.url)
    ctx.set_offline(False)
    pag.wait_for_selector("#loginEmail", timeout=15000)
    check("cuando el servidor vuelve, entra solo al sistema", pag.url.rstrip("/") == BASE)

    claves = pag.evaluate("caches.keys().then(ks => Promise.all(ks.map(k => caches.open(k).then(c => c.keys()))))"
                          ".then(ls => ls.flat().map(r => new URL(r.url).pathname))")
    check("la caché tiene solo la pantalla de apagado y los íconos (ningún dato de la API)",
          claves and not any(c.startswith(("/rest", "/rpc", "/auth", "/storage", "/health")) for c in claves), json.dumps(claves))
    # Pantalla "iniciando" del lanzador de Windows (archivo local): espera mientras no hay servidor, y entra sola.
    from urllib.parse import urlparse
    puerto = urlparse(BASE).port
    plantilla = (pathlib.Path(__file__).resolve().parents[1] / "escritorio" / "iniciando.html").read_text()
    archivo = pathlib.Path(perfil) / "iniciando.html"
    archivo.write_text(plantilla.replace("__PUERTO__", "1"))   # puerto donde no hay nadie
    pag.goto(archivo.as_uri()); pag.wait_for_timeout(3500)
    check("pantalla 'iniciando': sin servidor, espera", "Iniciando Auditor de Rankings Digitales" in pag.content() and pag.url.startswith("file://"))
    archivo.write_text(plantilla.replace("__PUERTO__", str(puerto)))
    pag.goto(archivo.as_uri())
    pag.wait_for_url(lambda u: u.startswith(BASE.replace("127.0.0.1", "localhost")), timeout=15000)
    pag.wait_for_selector("#loginEmail", timeout=15000)
    check("pantalla 'iniciando': cuando el servidor responde, entra sola a la aplicación", True)
    nav.close()
    shutil.rmtree(perfil, ignore_errors=True)

print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
