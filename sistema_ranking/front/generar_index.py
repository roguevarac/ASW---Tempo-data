"""
Genera front/index.html (sistema propio) desde frontend_ranking_digital.html (versión Supabase).
Solo cambia dos cosas; TODA la lógica del front queda igual:
  1. La librería supabase-js se reemplaza por tempo-client.js (mismos métodos), y
     PapaParse se sirve desde el propio sistema en vez de un CDN.
  2. La configuración (URL y clave de Supabase) se reemplaza por la URL de la API propia.
Si el HTML original cambia, volver a correr: python3 sistema_ranking/front/generar_index.py
"""
import pathlib, re, sys

RAIZ = pathlib.Path(__file__).resolve().parents[2]
ORIGEN = RAIZ / "frontend_ranking_digital.html"
DESTINO = pathlib.Path(__file__).resolve().parent / "index.html"

html = ORIGEN.read_text(encoding="utf-8")
lib = '<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js"></script>'
if lib not in html:
    sys.exit("No encontré la línea que carga supabase-js: revisar el HTML original")
html = html.replace(lib, '<script src="tempo-client.js"></script>')

papa = '<script src="https://cdnjs.cloudflare.com/ajax/libs/PapaParse/5.4.1/papaparse.min.js"></script>'
if papa in html:   # PapaParse incluida en el sistema (verificada con el hash de npm), sin depender de internet
    html = html.replace(papa, '<script src="papaparse.min.js"></script>')

conf = re.compile(r"const SUPABASE_URL = '[^']*';\s*const SUPABASE_ANON_KEY = '[^']*';")
if not conf.search(html):
    sys.exit("No encontré la configuración SUPABASE_URL / SUPABASE_ANON_KEY")
html = conf.sub("// API propia: vacío = mismo servidor que sirve esta página.\n"
                "const SUPABASE_URL = '';\nconst SUPABASE_ANON_KEY = '';", html)
html = html.replace("CONFIGURACIÓN — completar con los datos de tu proyecto Supabase\n  (Settings > API). Usar siempre la anon public key acá.",
                    "CONFIGURACIÓN — sistema propio (sin Supabase). La URL de la API va\n  vacía cuando el front lo sirve la misma API.")
if "supabase.co" in html or "eyJ" in html:
    sys.exit("Quedó una referencia a Supabase o una clave en el HTML")
DESTINO.write_text(html, encoding="utf-8")
print("OK", DESTINO)
