"""
Prueba exportar_supabase.py + importar.py de punta a punta, sin salir a internet:
la base de prueba hace de "Supabase" (mismas tablas, auth.users y storage.objects) y un servidor local
imita la API de Storage. Se importa en una base nueva y se compara todo fila por fila y archivo por archivo.

Variables: PGHOST_URL (superusuario sin base, ej. postgresql://postgres@localhost:54340),
           ORIGEN_DB (base con datos, ej. ranking), STORAGE_ORIGEN (carpeta de archivos de esa base).
"""
import hashlib
import http.server
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import urllib.parse

RAIZ = pathlib.Path(__file__).resolve().parents[1]
SERVIDOR = os.environ["PGHOST_URL"].rstrip("/")
ORIGEN = f"{SERVIDOR}/{os.environ.get('ORIGEN_DB', 'ranking')}"
DESTINO = f"{SERVIDOR}/ranking_destino"
STORAGE_ORIGEN = pathlib.Path(os.environ["STORAGE_ORIGEN"])
CLAVE = "clave-service-role-de-prueba"
fallas = []


def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + nombre + ("" if cond else f"  -> {extra}"))
    if not cond:
        fallas.append(nombre)


def sql(url, q):
    return subprocess.run(["psql", url, "-At", "-c", q], capture_output=True, text=True, check=True).stdout.strip()


class StorageFalso(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        prefijo = "/storage/v1/object/csv-uploads/"
        if self.headers.get("Authorization") != f"Bearer {CLAVE}" or not self.path.startswith(prefijo):
            self.send_response(403); self.end_headers(); return
        ruta = STORAGE_ORIGEN / "csv-uploads" / urllib.parse.unquote(self.path[len(prefijo):])
        if not ruta.is_file():
            self.send_response(404); self.end_headers(); return
        datos = ruta.read_bytes()
        self.send_response(200); self.send_header("Content-Length", str(len(datos))); self.end_headers()
        self.wfile.write(datos)

    def log_message(self, *a):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), StorageFalso)
threading.Thread(target=srv.serve_forever, daemon=True).start()

# Un usuario sin contraseña (como los invitados de Supabase) también tiene que migrar.
sql(ORIGEN, "INSERT INTO auth.users (email, encrypted_password) VALUES ('invitado@prueba.local', NULL) ON CONFLICT DO NOTHING")

tmp = pathlib.Path(tempfile.mkdtemp())
expo, storage_destino = tmp / "exportacion", tmp / "storage_destino"
env = dict(os.environ, SUPABASE_DB_URL=ORIGEN, SUPABASE_URL=f"http://127.0.0.1:{srv.server_port}",
           SUPABASE_SERVICE_KEY=CLAVE)
r = subprocess.run([sys.executable, str(RAIZ / "migracion" / "exportar_supabase.py"), str(expo)],
                   env=env, capture_output=True, text=True)
check("la exportación termina bien", r.returncode == 0, r.stdout[-800:] + r.stderr[-800:])

n_archivos = int(sql(ORIGEN, "select count(*) from storage.objects"))
check("se bajaron todos los archivos", len([p for p in (expo / "archivos").rglob("*") if p.is_file()]) == n_archivos > 0)
r2 = subprocess.run([sys.executable, str(RAIZ / "migracion" / "exportar_supabase.py"), str(expo)],
                    env=env, capture_output=True, text=True)
check("se puede volver a correr la exportación", r2.returncode == 0, r2.stderr[-500:])

sql(f"{SERVIDOR}/postgres", "DROP DATABASE IF EXISTS ranking_destino WITH (FORCE)")
sql(f"{SERVIDOR}/postgres", "CREATE DATABASE ranking_destino")
subprocess.run([str(RAIZ / "db" / "instalar.sh")], env=dict(os.environ, PGURL=DESTINO, AUTHENTICATOR_PASSWORD="prueba_local_123"),
               check=True, capture_output=True)
envi = dict(os.environ, PGURL=DESTINO, STORAGE_DIR=str(storage_destino))
imp = [sys.executable, str(RAIZ / "migracion" / "importar.py"), str(expo)]
r = subprocess.run(imp, env=envi, capture_output=True, text=True)
check("la importación termina bien", r.returncode == 0, r.stdout[-800:] + r.stderr[-800:])

tablas = sql(ORIGEN, "select string_agg(tablename, ' ') from pg_tables where schemaname='public'").split()
for t in sorted(tablas):
    q = f"select count(*) || ':' || coalesce(md5(string_agg(x::text, '|' order by x::text)), '') from public.{t} x"
    a, b = sql(ORIGEN, q), sql(DESTINO, q)
    check(f"tabla {t} idéntica ({a.split(':')[0]} filas)", a == b, (a, b))
for q in ["select md5(string_agg(id || email || coalesce(encrypted_password,'') || created_at, '|' order by id)) from auth.users",
          "select md5(string_agg(name || coalesce(owner::text,'') || metadata::text || created_at, '|' order by name)) from storage.objects"]:
    check("idéntico: " + q.split(" from ")[1], sql(ORIGEN, q) == sql(DESTINO, q))

registrados = sql(ORIGEN, "select string_agg(name, chr(10)) from storage.objects").splitlines()
iguales = all(hashlib.sha256((STORAGE_ORIGEN / "csv-uploads" / n).read_bytes()).digest() ==
              hashlib.sha256((storage_destino / "csv-uploads" / n).read_bytes()).digest() for n in registrados)
check("archivos idénticos en el disco nuevo", iguales)
check("los usuarios entran con su misma contraseña",
      sql(DESTINO, "select auth.login('admin@prueba.local', 'clave-admin-123') is not null") == "t")
check("el usuario sin contraseña no entra",
      sql(DESTINO, "select auth.login('invitado@prueba.local', '') is null") == "t")
check("las secuencias siguen después del máximo importado",
      sql(DESTINO, "select nextval(pg_get_serial_sequence('public.csv_uploads','id')) > coalesce(max(id),0) from csv_uploads") == "t")
check("los triggers no generaron auditoría extra",
      sql(ORIGEN, "select count(*) from audit_logs") == sql(DESTINO, "select count(*) from audit_logs"))

r = subprocess.run(imp, env=envi, capture_output=True, text=True)
check("sin --reemplazar no pisa una base con datos", r.returncode != 0 and "ya tiene datos" in (r.stdout + r.stderr), r.stderr[-300:])
r = subprocess.run(imp + ["--reemplazar"], env=envi, capture_output=True, text=True)
check("con --reemplazar vuelve a cargar igual", r.returncode == 0 and
      sql(ORIGEN, "select count(*) from territory_tracks") == sql(DESTINO, "select count(*) from territory_tracks"), r.stderr[-300:])

archivo = next(p for p in (expo / "archivos").rglob("*") if p.is_file())
archivo.write_bytes(archivo.read_bytes() + b"x")
r = subprocess.run(imp + ["--reemplazar"], env=envi, capture_output=True, text=True)
check("un archivo alterado en la exportación frena la importación", r.returncode != 0 and "alterado" in (r.stdout + r.stderr))

sql(ORIGEN, "DELETE FROM auth.users WHERE email = 'invitado@prueba.local'")
srv.shutdown()
print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
