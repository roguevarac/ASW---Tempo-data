"""
Exporta lo de Supabase a una carpeta local, para importarlo en el sistema propio con importar.py.

Dos formas (elegí una):
  python exportar_supabase.py [carpeta]              por la API de Supabase (HTTPS, puerto 443).
        Funciona desde la red de la empresa. Pide la URL del proyecto y la service_role key.
        Los usuarios se migran con su mismo id y rol, pero SIN contraseña (Supabase no la entrega por la API):
        después de importar se les pone una con admin/usuarios.py (MIGRAR.bat lo pide solo).
  python exportar_supabase.py [carpeta] --via-db     por conexión directa a la base (puerto 5432).
        Conserva las contraseñas y saca una foto exacta de un mismo instante. Pide la cadena de conexión
        (Dashboard > Connect > Session pooler). Suele estar bloqueado en redes corporativas.
Opciones:
  --sin-archivos     no baja el bucket; importar.py toma los archivos de tus carpetas (--archivos-desde).
  --bajar-faltantes  baja del bucket solo los que importar.py listó en archivos_faltantes.txt (no relee tablas).

Qué deja en la carpeta: tablas/*.csv (11 tablas, usuarios y registro de archivos), archivos/ (si se bajan),
cron_jobs.csv (solo --via-db) y manifiesto.json (filas por tabla, tamaño y sha256 de cada archivo).
Las claves no se guardan en disco. Si se corta, se puede volver a correr: los archivos ya bajados no se repiten.
Requisitos si se corre fuera de Docker: pip install "psycopg[binary]" httpx
"""
import decimal
import getpass
import hashlib
import json
import os
import pathlib
import sys
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed

import httpx

_pos = [a for a in sys.argv[1:] if not a.startswith("--")]
SALIDA = pathlib.Path(_pos[0] if _pos else "exportacion").resolve()
SIN_ARCHIVOS = "--sin-archivos" in sys.argv
VIA_DB = "--via-db" in sys.argv
BAJAR_FALTANTES = "--bajar-faltantes" in sys.argv
BUCKET = "csv-uploads"
# Orden de carga (respeta las claves foráneas) y clave primaria (para paginar en orden estable).
TABLAS = {
    "app_users": "user_id", "tracks_master": "id", "territory_tracks": "id", "territory_control": "id",
    "territory_bo_report": "id", "territory_tempo_report": "id", "csv_uploads": "id", "audit_logs": "id",
    "bo_export_counter": "id", "staging_tempo_historico": "fila", "resultado_tempo_historico": "fila",
}
COLS_USUARIOS = ["id", "email", "encrypted_password", "created_at", "last_sign_in_at", "banned_until"]
COLS_OBJETOS = ["bucket_id", "name", "owner", "metadata", "created_at"]
POR_PAGINA = int(os.environ.get("POR_PAGINA", "1000"))  # máximo que devuelve la API de Supabase por pedido


def dato(nombre, texto, secreto=False):
    v = os.environ.get(nombre, "").strip()
    if not v:
        v = (getpass.getpass if secreto else input)(f"{texto}: ").strip()
    if not v:
        sys.exit(f"Falta {nombre}")
    return v


def sha256(ruta):
    h = hashlib.sha256()
    with open(ruta, "rb") as f:
        for bloque in iter(lambda: f.read(1 << 20), b""):
            h.update(bloque)
    return h.hexdigest()


def a_json(v):
    """JSON que conserva los números tal como vinieron (2.50 sigue siendo 2.50, no 2.5 ni "2.50")."""
    if isinstance(v, dict):
        return "{" + ", ".join(json.dumps(k, ensure_ascii=False) + ": " + a_json(x) for k, x in v.items()) + "}"
    if isinstance(v, list):
        return "[" + ", ".join(a_json(x) for x in v) + "]"
    if isinstance(v, decimal.Decimal):
        return str(v)
    return json.dumps(v, ensure_ascii=False)


def celda(v):
    """Formato CSV de COPY: vacío sin comillas = NULL; todo lo demás entre comillas (así "" = texto vacío)."""
    if v is None:
        return ""
    if isinstance(v, (dict, list)):
        v = a_json(v)
    elif isinstance(v, bool):
        v = "true" if v else "false"
    return '"' + str(v).replace('"', '""') + '"'


class EscritorCsv:
    def __init__(self, ruta, columnas):
        self.f = open(ruta, "w", encoding="utf-8", newline="")
        self.columnas = columnas
        self.n = 0
        if columnas:
            self.f.write(",".join(columnas) + "\n")

    def fila(self, d):
        self.f.write(",".join(celda(d.get(c)) for c in self.columnas) + "\n")
        self.n += 1

    def cerrar(self):
        self.f.close()


# ------------------------------------------------------------------ por la API (HTTPS)
def exportar_via_api(cli, manifiesto):
    for t, pk in TABLAS.items():
        r = cli.get(f"/rest/v1/{t}", params={"select": "*", "limit": 1}, headers={"Prefer": "count=exact"})
        r.raise_for_status()
        total = int(r.headers["content-range"].split("/")[1])
        esc = None
        offset = 0
        while True:
            r = cli.get(f"/rest/v1/{t}", params={"select": "*", "order": f"{pk}.asc", "limit": POR_PAGINA, "offset": offset})
            r.raise_for_status()
            filas = r.json(parse_float=decimal.Decimal)
            if esc is None:
                esc = EscritorCsv(SALIDA / "tablas" / f"{t}.csv", list(filas[0].keys()) if filas else [])
            for f in filas:
                esc.fila(f)
            offset += len(filas)
            if len(filas) < POR_PAGINA:
                break
        esc.cerrar()
        if esc.n != total:
            sys.exit(f"{t}: se leyeron {esc.n} filas pero Supabase informa {total}. "
                     f"¿Alguien está cargando datos? Volvé a correr con el sistema quieto.")
        manifiesto["tablas"][t] = total
        print(f"  {t}: {total} filas")

    esc = EscritorCsv(SALIDA / "tablas" / "auth_users.csv", COLS_USUARIOS)
    pagina = 1
    while True:
        r = cli.get("/auth/v1/admin/users", params={"page": pagina, "per_page": 1000})
        r.raise_for_status()
        usuarios = r.json().get("users", [])
        for u in usuarios:
            if u.get("email"):
                esc.fila({**u, "encrypted_password": None})
        if len(usuarios) < 1000:
            break
        pagina += 1
    esc.cerrar()
    manifiesto["tablas"]["auth.users"] = esc.n
    print(f"  auth.users: {esc.n} usuarios (sin contraseña: se pone una nueva al importar)")

    # Registro de archivos del bucket (nombre, tamaño, fecha), recorriendo las carpetas.
    esc = EscritorCsv(SALIDA / "tablas" / "storage_objects.csv", COLS_OBJETOS)
    objetos, pendientes = [], [""]
    while pendientes:
        prefijo = pendientes.pop()
        offset = 0
        while True:
            r = cli.post(f"/storage/v1/object/list/{BUCKET}", json={
                "prefix": prefijo, "limit": POR_PAGINA, "offset": offset, "sortBy": {"column": "name", "order": "asc"}})
            r.raise_for_status()
            items = r.json()
            for it in items:
                nombre = f"{prefijo}/{it['name']}" if prefijo else it["name"]
                if it.get("id") is None:  # carpeta
                    pendientes.append(nombre)
                elif it["name"] != ".emptyFolderPlaceholder":
                    esc.fila({"bucket_id": BUCKET, "name": nombre, "owner": it.get("owner"),
                              "metadata": it.get("metadata"), "created_at": it.get("created_at")})
                    objetos.append((nombre, int((it.get("metadata") or {}).get("size", -1))))
            offset += len(items)
            if len(items) < POR_PAGINA:
                break
    esc.cerrar()
    manifiesto["tablas"]["storage.objects"] = len(objetos)
    print(f"  storage.objects: {len(objetos)} archivos registrados")
    return objetos


# ------------------------------------------------------------------ por conexión directa
def copiar_a_csv(cur, consulta, destino):
    with open(destino, "wb") as f, cur.copy(f"COPY ({consulta}) TO STDOUT WITH (FORMAT csv, HEADER true)") as cp:
        for bloque in cp:
            f.write(bloque)


def exportar_via_db(db_url, manifiesto):
    import psycopg
    with psycopg.connect(db_url, autocommit=False) as con, con.cursor() as cur:
        # Foto consistente de toda la base: todas las tablas salen del mismo instante.
        cur.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
        for t in TABLAS:
            copiar_a_csv(cur, f"SELECT * FROM public.{t}", SALIDA / "tablas" / f"{t}.csv")
            cur.execute(f"SELECT count(*) FROM public.{t}")
            manifiesto["tablas"][t] = cur.fetchone()[0]
            print(f"  {t}: {manifiesto['tablas'][t]} filas")

        copiar_a_csv(cur, f"SELECT {', '.join(COLS_USUARIOS)} FROM auth.users WHERE email IS NOT NULL ORDER BY created_at",
                     SALIDA / "tablas" / "auth_users.csv")
        cur.execute("SELECT count(*) FROM auth.users WHERE email IS NOT NULL")
        manifiesto["tablas"]["auth.users"] = cur.fetchone()[0]
        print(f"  auth.users: {manifiesto['tablas']['auth.users']} usuarios")

        copiar_a_csv(cur, f"SELECT {', '.join(COLS_OBJETOS)} FROM storage.objects WHERE bucket_id = '{BUCKET}' ORDER BY name",
                     SALIDA / "tablas" / "storage_objects.csv")
        cur.execute("SELECT name, coalesce((metadata->>'size')::bigint, -1) FROM storage.objects WHERE bucket_id = %s",
                    (BUCKET,))
        objetos = cur.fetchall()
        manifiesto["tablas"]["storage.objects"] = len(objetos)

        try:
            cur.execute("SAVEPOINT cron")
            copiar_a_csv(cur, "SELECT jobname, schedule, command, active FROM cron.job ORDER BY jobid",
                         SALIDA / "cron_jobs.csv")
            print("  tareas de pg_cron guardadas en cron_jobs.csv")
        except psycopg.Error:
            cur.execute("ROLLBACK TO SAVEPOINT cron")
            print("  (no se pudieron leer las tareas de pg_cron)")
    return objetos


def bajar_archivos(sb_url, clave, objetos, manifiesto):
    print(f"Bajando {len(objetos)} archivos del bucket {BUCKET}...")
    cabeceras = {"Authorization": f"Bearer {clave}", "apikey": clave}
    errores = []

    def bajar(nombre, tam):
        destino = SALIDA / "archivos" / BUCKET / nombre
        if destino.exists() and (tam < 0 or destino.stat().st_size == tam):
            return nombre, sha256(destino)
        destino.parent.mkdir(parents=True, exist_ok=True)
        ruta = "/".join(urllib.parse.quote(p, safe="") for p in nombre.split("/"))
        with httpx.Client(timeout=120, headers=cabeceras) as cli:
            r = cli.get(f"{sb_url}/storage/v1/object/{BUCKET}/{ruta}")
        if r.status_code != 200:
            raise RuntimeError(f"HTTP {r.status_code}: {r.text[:200]}")
        if tam >= 0 and len(r.content) != tam:
            raise RuntimeError(f"tamaño {len(r.content)} distinto del registrado {tam}")
        tmp = destino.with_name(destino.name + ".parcial")
        tmp.write_bytes(r.content)
        tmp.replace(destino)
        return nombre, hashlib.sha256(r.content).hexdigest()

    with ThreadPoolExecutor(max_workers=8) as pool:
        tareas = {pool.submit(bajar, n, t): n for n, t in objetos}
        for i, fut in enumerate(as_completed(tareas), 1):
            try:
                nombre, h = fut.result()
                manifiesto["archivos"][nombre] = {"sha256": h, "bytes": (SALIDA / "archivos" / BUCKET / nombre).stat().st_size}
            except Exception as e:  # noqa: BLE001 - se informa y se sigue con los demás
                errores.append(f"{tareas[fut]}: {e}")
            if i % 200 == 0 or i == len(tareas):
                print(f"  {i}/{len(tareas)}")
    return errores


def bajar_solo_faltantes():
    import csv
    manifiesto = json.loads((SALIDA / "manifiesto.json").read_text(encoding="utf-8"))
    nombres = [l.split("\t", 1)[0] for l in (SALIDA / "archivos_faltantes.txt").read_text(encoding="utf-8").splitlines() if l]
    with open(SALIDA / "tablas" / "storage_objects.csv", encoding="utf-8", newline="") as f:
        tam = {o["name"]: int((json.loads(o["metadata"]) if o["metadata"] else {}).get("size", -1)) for o in csv.DictReader(f)}
    sb_url = dato("SUPABASE_URL", "URL del proyecto (https://xxxx.supabase.co)").rstrip("/")
    clave = dato("SUPABASE_SERVICE_KEY", "service_role key (Project Settings > API Keys)", secreto=True)
    errores = bajar_archivos(sb_url, clave, [(n, tam.get(n, -1)) for n in nombres], manifiesto)
    (SALIDA / "manifiesto.json").write_text(json.dumps(manifiesto, indent=1, ensure_ascii=False), encoding="utf-8")
    if errores:
        (SALIDA / "errores_archivos.txt").write_text("\n".join(errores), encoding="utf-8")
        sys.exit(f"ATENCIÓN: {len(errores)} archivos no se pudieron bajar (ver errores_archivos.txt).")
    print(f"Listo: {len(nombres)} archivos bajados del bucket.")


def main():
    if BAJAR_FALTANTES:
        return bajar_solo_faltantes()
    (SALIDA / "tablas").mkdir(parents=True, exist_ok=True)
    (SALIDA / "archivos" / BUCKET).mkdir(parents=True, exist_ok=True)
    manifiesto = {"modo": "db" if VIA_DB else "api", "tablas": {}, "archivos": {}}
    sb_url = clave = ""
    if VIA_DB:
        objetos = exportar_via_db(dato("SUPABASE_DB_URL", "Cadena de conexión de Supabase (Session pooler)", secreto=True),
                                  manifiesto)
    if not VIA_DB or not SIN_ARCHIVOS:
        sb_url = dato("SUPABASE_URL", "URL del proyecto (https://xxxx.supabase.co)").rstrip("/")
        clave = dato("SUPABASE_SERVICE_KEY", "service_role key (Project Settings > API Keys)", secreto=True)
    if not VIA_DB:
        with httpx.Client(base_url=sb_url, timeout=120,
                          headers={"Authorization": f"Bearer {clave}", "apikey": clave}) as cli:
            try:
                objetos = exportar_via_api(cli, manifiesto)
            except httpx.HTTPStatusError as e:
                sys.exit(f"Supabase respondió {e.response.status_code} en {e.request.url.path}: {e.response.text[:300]}\n"
                         f"Revisá que la clave sea la service_role (no la anon).")
            except httpx.HTTPError as e:
                sys.exit(f"No se pudo conectar con {sb_url}: {e}")

    errores = []
    if SIN_ARCHIVOS:
        print("Sin bajar el bucket (--sin-archivos): los archivos se toman de tus carpetas al importar.")
    else:
        errores = bajar_archivos(sb_url, clave, objetos, manifiesto)

    (SALIDA / "manifiesto.json").write_text(json.dumps(manifiesto, indent=1, ensure_ascii=False), encoding="utf-8")
    if errores:
        (SALIDA / "errores_archivos.txt").write_text("\n".join(errores), encoding="utf-8")
        print(f"ATENCIÓN: {len(errores)} archivos no se pudieron bajar (ver errores_archivos.txt). "
              f"Volvé a correr el script para reintentar solo esos.")
        sys.exit(1)
    print(f"Listo. Todo quedó en {SALIDA}.")


if __name__ == "__main__":
    main()
