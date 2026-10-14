"""
Exporta TODO lo de Supabase a una carpeta local, para importarlo en el sistema propio.

Qué baja:
  - Las 11 tablas de public (CSV con encabezado, vía COPY: no depende de la versión de pg_dump).
  - Los usuarios (auth.users: email y hash bcrypt -> todos conservan su contraseña).
  - El registro de archivos (storage.objects) y los archivos del bucket csv-uploads.
  - Las tareas de pg_cron (para copiar el horario de YouTube a YOUTUBE_CRON).
  - manifiesto.json con la cantidad de filas y el tamaño y sha256 de cada archivo.

Se corre en TU computadora (Windows, Mac o Linux):
    pip install "psycopg[binary]" httpx
    python exportar_supabase.py            (pide los datos de conexión sin mostrarlos)

Datos que pide (o se pasan como variables de entorno):
  SUPABASE_DB_URL       Dashboard > Connect > "Session pooler" (postgresql://postgres.xxxx:CLAVE@...:5432/postgres)
  SUPABASE_URL          https://<proyecto>.supabase.co
  SUPABASE_SERVICE_KEY  Dashboard > Project Settings > API Keys > service_role (secret)
Nada de eso se guarda en disco. Se puede volver a correr: los archivos ya bajados y verificados no se bajan de nuevo.
"""
import csv
import getpass
import hashlib
import json
import os
import pathlib
import sys
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed

import httpx
import psycopg

SALIDA = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "exportacion").resolve()
BUCKET = "csv-uploads"
# Orden de carga (respeta las claves foráneas).
TABLAS = [
    "app_users", "tracks_master", "territory_tracks", "territory_control", "territory_bo_report",
    "territory_tempo_report", "csv_uploads", "audit_logs", "bo_export_counter",
    "staging_tempo_historico", "resultado_tempo_historico",
]


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


def copiar_a_csv(cur, consulta, destino):
    with open(destino, "wb") as f, cur.copy(f"COPY ({consulta}) TO STDOUT WITH (FORMAT csv, HEADER true)") as cp:
        for bloque in cp:
            f.write(bloque)


def main():
    db_url = dato("SUPABASE_DB_URL", "Cadena de conexión de Supabase (Session pooler)", secreto=True)
    sb_url = dato("SUPABASE_URL", "URL del proyecto (https://xxxx.supabase.co)").rstrip("/")
    clave = dato("SUPABASE_SERVICE_KEY", "service_role key", secreto=True)

    (SALIDA / "tablas").mkdir(parents=True, exist_ok=True)
    (SALIDA / "archivos" / BUCKET).mkdir(parents=True, exist_ok=True)
    manifiesto = {"tablas": {}, "archivos": {}}

    with psycopg.connect(db_url, autocommit=False) as con, con.cursor() as cur:
        # Foto consistente de toda la base: todas las tablas salen del mismo instante.
        cur.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
        for t in TABLAS:
            copiar_a_csv(cur, f"SELECT * FROM public.{t}", SALIDA / "tablas" / f"{t}.csv")
            cur.execute(f"SELECT count(*) FROM public.{t}")
            manifiesto["tablas"][t] = cur.fetchone()[0]
            print(f"  {t}: {manifiesto['tablas'][t]} filas")

        copiar_a_csv(cur, "SELECT id, email, encrypted_password, created_at, last_sign_in_at, banned_until "
                          "FROM auth.users WHERE email IS NOT NULL ORDER BY created_at",
                     SALIDA / "tablas" / "auth_users.csv")
        cur.execute("SELECT count(*) FROM auth.users WHERE email IS NOT NULL")
        manifiesto["tablas"]["auth.users"] = cur.fetchone()[0]
        print(f"  auth.users: {manifiesto['tablas']['auth.users']} usuarios")

        copiar_a_csv(cur, f"SELECT bucket_id, name, owner, metadata, created_at FROM storage.objects "
                          f"WHERE bucket_id = '{BUCKET}' ORDER BY name", SALIDA / "tablas" / "storage_objects.csv")
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
            print("  (no se pudieron leer las tareas de pg_cron; ver README)")

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

    (SALIDA / "manifiesto.json").write_text(json.dumps(manifiesto, indent=1, ensure_ascii=False), encoding="utf-8")
    if errores:
        (SALIDA / "errores_archivos.txt").write_text("\n".join(errores), encoding="utf-8")
        print(f"ATENCIÓN: {len(errores)} archivos no se pudieron bajar (ver errores_archivos.txt). "
              f"Volvé a correr el script para reintentar solo esos.")
        sys.exit(1)
    print(f"Listo. Todo quedó en {SALIDA}. Llevá esa carpeta al servidor y corré importar.py.")


if __name__ == "__main__":
    main()
