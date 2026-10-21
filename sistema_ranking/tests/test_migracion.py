"""
Prueba exportar_supabase.py + importar.py de punta a punta, sin salir a internet.
La base de prueba hace de "Supabase" (mismas tablas, auth.users y storage.objects) y un servidor local imita
sus APIs: tablas (/rest/v1), usuarios (/auth/v1/admin/users) y bucket (/storage/v1). Se importa en una base
nueva y se compara todo fila por fila y archivo por archivo, en los dos modos:
  - por la API (HTTPS; el que funciona desde la red de la empresa), con los archivos tomados de carpetas
    locales como las de OneDrive;
  - por conexión directa a la base (--via-db), bajando el bucket.

Variables: PGHOST_URL (superusuario sin base, ej. postgresql://postgres@localhost:54340),
           ORIGEN_DB (base con datos, ej. ranking), STORAGE_ORIGEN (carpeta de archivos de esa base).
"""
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile


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


# ------------------------------------------------------------------ "Supabase" falso (tests/supabase_falso.py)
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import supabase_falso  # noqa: E402

srv, pedidos = supabase_falso.iniciar(ORIGEN, STORAGE_ORIGEN, CLAVE)

# Datos difíciles: usuario sin contraseña (como los invitados de Supabase), texto con comillas, comas,
# saltos de línea, texto vacío (distinto de NULL) y JSON anidado.
sql(ORIGEN, "INSERT INTO auth.users (email, encrypted_password) VALUES ('invitado@prueba.local', NULL) ON CONFLICT DO NOTHING")
sql(ORIGEN, """INSERT INTO audit_logs (table_name, row_id, operation, old_data, new_data)
               VALUES ('prueba', gen_random_uuid(), 'UPDATE', '{"a": "x,\\"y\\"\\nz", "b": [1, 2.50, null]}', '{"c": ""}')""")
sql(ORIGEN, """UPDATE tracks_master SET track_name_raw = 'Tema "con" comillas, coma
y salto' WHERE id = (SELECT id FROM tracks_master ORDER BY id LIMIT 1)""")
sql(ORIGEN, "UPDATE csv_uploads SET format = '' WHERE id = (SELECT min(id) FROM csv_uploads)")

tmp = pathlib.Path(tempfile.mkdtemp())
storage_destino = tmp / "storage_destino"
env_sb = dict(os.environ, SUPABASE_URL=f"http://127.0.0.1:{srv.server_port}", SUPABASE_SERVICE_KEY=CLAVE,
              SUPABASE_DB_URL=ORIGEN, POR_PAGINA="2")
envi = dict(os.environ, PGURL=DESTINO, STORAGE_DIR=str(storage_destino))
exportar = [sys.executable, str(RAIZ / "migracion" / "exportar_supabase.py")]
importar = [sys.executable, str(RAIZ / "migracion" / "importar.py")]
tablas = sql(ORIGEN, "select string_agg(tablename, ' ') from pg_tables where schemaname='public' and tablename not in ('envios', 'envio_obras')").split()
registrados = sql(ORIGEN, "select string_agg(name, chr(10)) from storage.objects").splitlines()


def correr(cmd, env):
    return subprocess.run(cmd, env=env, capture_output=True, text=True)


def base_destino_nueva():
    shutil.rmtree(storage_destino, ignore_errors=True)
    sql(f"{SERVIDOR}/postgres", "DROP DATABASE IF EXISTS ranking_destino WITH (FORCE)")
    sql(f"{SERVIDOR}/postgres", "CREATE DATABASE ranking_destino")
    subprocess.run([str(RAIZ / "db" / "instalar.sh")], env=dict(os.environ, PGURL=DESTINO, AUTHENTICATOR_PASSWORD="prueba_local_123"),
                   check=True, capture_output=True)


def comparar(modo, con_claves):
    for t in sorted(tablas):
        q = f"select count(*) || ':' || coalesce(md5(string_agg(x::text, '|' order by x::text)), '') from public.{t} x"
        a, b = sql(ORIGEN, q), sql(DESTINO, q)
        extra = ""
        if a != b:
            filas = f"select x::text from public.{t} x"
            o, d = set(sql(ORIGEN, filas).splitlines()), set(sql(DESTINO, filas).splitlines())
            extra = f"solo en Supabase: {sorted(o - d)[:2]} | solo en la nueva: {sorted(d - o)[:2]}"
        check(f"[{modo}] tabla {t} idéntica ({a.split(':')[0]} filas)", a == b, extra)
    clave = "coalesce(encrypted_password,'') ||" if con_claves else ""
    q = f"select md5(string_agg(id || email || {clave} created_at || coalesce(last_sign_in_at::text,''), '|' order by id)) from auth.users"
    check(f"[{modo}] usuarios idénticos (mismo id, email y fechas)", sql(ORIGEN, q) == sql(DESTINO, q))
    q = "select md5(string_agg(name || metadata::text || created_at, '|' order by name)) from storage.objects"
    check(f"[{modo}] registro de archivos idéntico", sql(ORIGEN, q) == sql(DESTINO, q))
    check(f"[{modo}] las secuencias siguen después del máximo importado",
          sql(DESTINO, "select nextval(pg_get_serial_sequence('public.audit_logs','id')) > coalesce(max(id),0) from audit_logs") == "t")


def archivos_iguales(nombres):
    return all((storage_destino / "csv-uploads" / n).is_file() and
               hashlib.sha256((STORAGE_ORIGEN / "csv-uploads" / n).read_bytes()).digest() ==
               hashlib.sha256((storage_destino / "csv-uploads" / n).read_bytes()).digest() for n in nombres)


# ================================================================== modo API + archivos de OneDrive
expo = tmp / "expo_api"
r = correr(exportar + [str(expo), "--sin-archivos"], env_sb)
check("[api] la exportación termina bien", r.returncode == 0, r.stdout[-800:] + r.stderr[-800:])
check("[api] se recorrieron varias páginas", sum("offset=2" in p for p in pedidos) >= 2, pedidos[:5])
check("[api] no bajó archivos del bucket", not any(p.startswith("/storage/v1/object/csv-uploads/") for p in pedidos))
r = correr(exportar + [str(tmp / "expo_mal"), "--sin-archivos"], dict(env_sb, SUPABASE_SERVICE_KEY="anon"))
check("[api] con una clave equivocada avisa y no deja nada a medias", r.returncode != 0 and "service_role" in (r.stdout + r.stderr), r.stderr[-300:])

# Carpetas "OneDrive": los archivos con su nombre original, en subcarpetas, más un señuelo con el mismo nombre y otro tamaño.
onedrive = [tmp / "Charts historicos Youtube", tmp / "Charts historicos_spotify"]
for c in onedrive:
    (c / "2026" / "octubre").mkdir(parents=True)
originales = dict(line.split("|", 1) for line in sql(ORIGEN, "select file_path || '|' || filename from csv_uploads where file_path is not null").splitlines())
for i, n in enumerate(registrados):
    destino = onedrive[i % 2] / "2026" / "octubre" / originales.get(n, n.rsplit("/", 1)[-1])
    shutil.copyfile(STORAGE_ORIGEN / "csv-uploads" / n, destino)
    (onedrive[(i + 1) % 2] / destino.name).write_text("señuelo: mismo nombre, otro contenido y tamaño\n")
desde = sum((["--archivos-desde", str(c)] for c in onedrive), [])

base_destino_nueva()
falta = onedrive[0] / "2026" / "octubre" / originales.get(registrados[0], registrados[0].rsplit("/", 1)[-1])
guardado = falta.read_bytes(); falta.unlink()
r = correr(importar + [str(expo)] + desde, envi)
check("[api] si falta un archivo del historial frena y lo lista", r.returncode != 0 and (expo / "archivos_faltantes.txt").read_text().startswith(registrados[0]),
      r.stdout[-500:] + r.stderr[-500:])
check("[api] y no importó nada", sql(DESTINO, "select count(*) from tracks_master") == "0")
r = correr(importar + [str(expo), "--permitir-faltantes"] + desde, envi)
check("[api] con --permitir-faltantes importa igual", r.returncode == 0 and "1 archivos del historial no encontrados" in r.stdout, r.stdout[-500:] + r.stderr[-500:])
check("[api] la carga sin archivo sigue en el historial", sql(DESTINO, f"select count(*) from storage.objects where name = '{registrados[0]}'") == "1"
      and not (storage_destino / "csv-uploads" / registrados[0]).exists())
r = correr(exportar + [str(expo), "--bajar-faltantes"], env_sb)
check("[api] --bajar-faltantes baja del bucket solo el que faltaba", r.returncode == 0 and
      list(json.loads((expo / "manifiesto.json").read_text())["archivos"]) == [registrados[0]], r.stdout[-300:] + r.stderr[-300:])
r = correr(importar + [str(expo), "--reemplazar"] + desde, envi)
check("[api] con ese archivo bajado y el resto de OneDrive importa sin faltantes", r.returncode == 0 and "no encontrados" not in r.stdout
      and archivos_iguales(registrados), r.stdout[-300:] + r.stderr[-300:])
(expo / "manifiesto.json").write_text(json.dumps({**json.loads((expo / "manifiesto.json").read_text()), "archivos": {}}))
falta.write_bytes(guardado)

r = correr(importar + [str(expo), "--reemplazar"] + desde, envi)
check("[api] con todos los archivos importa completo", r.returncode == 0 and "usuarios sin contraseña" in r.stdout, r.stdout[-500:] + r.stderr[-500:])
comparar("api", con_claves=False)
check("[api] archivos del historial tomados de OneDrive, idénticos (el señuelo se descarta por tamaño)", archivos_iguales(registrados))
check("[api] los usuarios quedan sin contraseña hasta que se les pone una",
      sql(DESTINO, "select count(*) from auth.users where encrypted_password is not null") == "0")
sql(DESTINO, "select auth.set_password('admin@prueba.local', 'clave-nueva-123')")
check("[api] con la contraseña nueva entra, con el mismo id y rol",
      sql(DESTINO, "select a.app_role from auth.users u join app_users a on a.user_id = u.id "
                   "where u.id = auth.login('admin@prueba.local', 'clave-nueva-123')") == "admin")
check("[api] los triggers no generaron auditoría extra",
      sql(ORIGEN, "select count(*) from audit_logs") == sql(DESTINO, "select count(*) from audit_logs"))

# ================================================================== modo conexión directa + bucket
expo = tmp / "expo_db"
r = correr(exportar + [str(expo), "--via-db"], env_sb)
check("[db] la exportación termina bien", r.returncode == 0, r.stdout[-800:] + r.stderr[-800:])
check("[db] se bajaron todos los archivos", len([p for p in (expo / "archivos").rglob("*") if p.is_file()]) == len(registrados) > 0)
check("[db] se puede volver a correr la exportación", correr(exportar + [str(expo), "--via-db"], env_sb).returncode == 0)
base_destino_nueva()
r = correr(importar + [str(expo)], envi)
check("[db] la importación termina bien", r.returncode == 0, r.stdout[-800:] + r.stderr[-800:])
comparar("db", con_claves=True)
check("[db] archivos idénticos en el disco nuevo", archivos_iguales(registrados))
check("[db] los usuarios entran con su misma contraseña",
      sql(DESTINO, "select auth.login('admin@prueba.local', 'clave-admin-123') is not null") == "t")
check("[db] el usuario sin contraseña no entra", sql(DESTINO, "select auth.login('invitado@prueba.local', '') is null") == "t")
r = correr(importar + [str(expo)], envi)
check("[db] sin --reemplazar no pisa una base con datos", r.returncode != 0 and "ya tiene datos" in (r.stdout + r.stderr), r.stderr[-300:])
archivo = next(p for p in (expo / "archivos").rglob("*") if p.is_file())
archivo.write_bytes(archivo.read_bytes() + b"x")
r = correr(importar + [str(expo), "--reemplazar"], envi)
check("[db] un archivo alterado en la exportación frena la importación", r.returncode != 0 and "alterado" in (r.stdout + r.stderr))

sql(ORIGEN, "DELETE FROM auth.users WHERE email = 'invitado@prueba.local'")
srv.shutdown()
print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
