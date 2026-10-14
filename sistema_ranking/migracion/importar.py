"""
Importa en el sistema propio la carpeta generada por exportar_supabase.py.

    PGURL=postgresql://postgres:CLAVE@localhost:5432/ranking STORAGE_DIR=/data/storage \
        python importar.py exportacion [--reemplazar]

- PGURL es el superusuario de la base NUEVA (ya instalada con db/instalar.sh).
- Todo entra en una sola transacción: si algo falla no queda nada a medias.
- Los triggers no se disparan durante la carga (no se generan auditorías ni fechas nuevas:
  los datos quedan exactamente como estaban en Supabase).
- Al final compara filas y archivos contra manifiesto.json y avisa cualquier diferencia.
- Sin --reemplazar se niega a cargar sobre una base que ya tiene datos.
"""
import csv
import hashlib
import json
import os
import pathlib
import shutil
import sys

import psycopg

if len(sys.argv) < 2:
    sys.exit(__doc__)
ORIGEN = pathlib.Path(sys.argv[1]).resolve()
REEMPLAZAR = "--reemplazar" in sys.argv
PGURL = os.environ.get("PGURL") or sys.exit("Falta PGURL")
STORAGE_DIR = pathlib.Path(os.environ.get("STORAGE_DIR") or sys.exit("Falta STORAGE_DIR")).resolve()
BUCKET = "csv-uploads"
TABLAS = [
    "app_users", "tracks_master", "territory_tracks", "territory_control", "territory_bo_report",
    "territory_tempo_report", "csv_uploads", "audit_logs", "bo_export_counter",
    "staging_tempo_historico", "resultado_tempo_historico",
]
manifiesto = json.loads((ORIGEN / "manifiesto.json").read_text(encoding="utf-8"))


def sha256(ruta):
    h = hashlib.sha256()
    with open(ruta, "rb") as f:
        for bloque in iter(lambda: f.read(1 << 20), b""):
            h.update(bloque)
    return h.hexdigest()


def columnas_destino(cur, esquema, tabla):
    cur.execute("""SELECT a.attname FROM pg_attribute a
                   WHERE a.attrelid = %s::regclass AND a.attnum > 0 AND NOT a.attisdropped""",
                (f"{esquema}.{tabla}",))
    return {r[0] for r in cur.fetchall()}


def cargar(cur, esquema, tabla, archivo):
    with open(archivo, encoding="utf-8", newline="") as f:
        encabezado = next(csv.reader(f))
    sobran = set(encabezado) - columnas_destino(cur, esquema, tabla)
    if sobran:
        raise SystemExit(f"{esquema}.{tabla}: columnas que no existen en la base nueva: {sorted(sobran)}")
    cols = ", ".join(f'"{c}"' for c in encabezado)
    with open(archivo, "rb") as f, cur.copy(
            f"COPY {esquema}.{tabla} ({cols}) FROM STDIN WITH (FORMAT csv, HEADER true)") as cp:
        while bloque := f.read(1 << 20):
            cp.write(bloque)
    cur.execute(f"SELECT count(*) FROM {esquema}.{tabla}")
    return cur.fetchone()[0]


def main():
    diferencias = []
    # 1) Archivos primero (fuera de la transacción; se copian a una carpeta temporal y se mueven al final).
    archivos = manifiesto["archivos"]
    for nombre, info in archivos.items():
        ruta = ORIGEN / "archivos" / BUCKET / nombre
        if not ruta.exists() or sha256(ruta) != info["sha256"]:
            diferencias.append(f"archivo faltante o alterado en la exportación: {nombre}")
    if diferencias:
        sys.exit("\n".join(diferencias[:20]) + "\nCorregí la exportación antes de importar.")

    with psycopg.connect(PGURL) as con, con.cursor() as cur:
        cur.execute("SET session_replication_role = replica")  # sin triggers ni chequeo de FK durante la carga
        ocupadas = []
        for t in TABLAS:
            cur.execute(f"SELECT count(*) FROM public.{t}")
            n = cur.fetchone()[0]
            if n and t != "bo_export_counter":
                ocupadas.append(f"{t} ({n})")
        cur.execute("SELECT count(*) FROM auth.users")
        if cur.fetchone()[0]:
            ocupadas.append("auth.users")
        if ocupadas and not REEMPLAZAR:
            sys.exit("La base ya tiene datos: " + ", ".join(ocupadas) + ". Usá --reemplazar para borrarlos y cargar.")
        cur.execute("TRUNCATE " + ", ".join(f"public.{t}" for t in TABLAS) + ", auth.users, storage.objects")

        print("auth.users:", cargar(cur, "auth", "users", ORIGEN / "tablas" / "auth_users.csv"))
        for t in TABLAS:
            n = cargar(cur, "public", t, ORIGEN / "tablas" / f"{t}.csv")
            print(f"{t}: {n}")
            if n != manifiesto["tablas"][t]:
                diferencias.append(f"{t}: {n} filas, Supabase tenía {manifiesto['tablas'][t]}")
        n = cargar(cur, "storage", "objects", ORIGEN / "tablas" / "storage_objects.csv")
        print("storage.objects:", n)
        if n != manifiesto["tablas"]["storage.objects"]:
            diferencias.append(f"storage.objects: {n}, Supabase tenía {manifiesto['tablas']['storage.objects']}")

        # Las secuencias siguen desde el máximo importado (si no, la próxima carga chocaría con un id existente).
        cur.execute("""SELECT n.nspname, c.relname, a.attname FROM pg_attribute a
                       JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                       WHERE n.nspname = 'public' AND a.attidentity <> '' """)
        for esquema, tabla, col in cur.fetchall():
            cur.execute(f"SELECT setval(pg_get_serial_sequence('{esquema}.{tabla}', '{col}'), "
                        f"coalesce(max({col}), 0) + 1, false) FROM {esquema}.{tabla}")

        # Integridad: se verifican a mano las claves foráneas que la carga no chequeó.
        cur.execute("SET session_replication_role = origin")
        cur.execute("""SELECT conrelid::regclass::text, conname FROM pg_constraint
                       WHERE contype = 'f' AND connamespace IN ('public'::regnamespace, 'storage'::regnamespace)""")
        for tabla, fk in cur.fetchall():
            cur.execute(f"ALTER TABLE {tabla} DROP CONSTRAINT {fk}, ADD CONSTRAINT {fk} "
                        f"{_definicion_fk(con, tabla, fk)}")  # re-crear la FK la valida contra todas las filas
        cur.execute("SELECT name FROM storage.objects WHERE bucket_id = %s", (BUCKET,))
        registrados = {r[0] for r in cur.fetchall()}
        faltan = registrados - set(archivos)
        if faltan:
            diferencias.append(f"{len(faltan)} archivos registrados sin contenido (ej. {sorted(faltan)[:3]})")
        if diferencias:
            con.rollback()
            sys.exit("NO se importó nada por estas diferencias:\n  " + "\n  ".join(diferencias))

        # 2) Archivos al disco de la API; recién después se confirma la base.
        destino_bucket = STORAGE_DIR / BUCKET
        for nombre in archivos:
            destino = (destino_bucket / nombre).resolve()
            if destino_bucket.resolve() not in destino.parents:
                sys.exit(f"Ruta de archivo inválida: {nombre}")
            destino.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ORIGEN / "archivos" / BUCKET / nombre, destino)
        con.commit()
    print(f"Importación completa: {sum(manifiesto['tablas'].values())} filas y {len(archivos)} archivos verificados.")


_cache_fk = {}


def _definicion_fk(con, tabla, fk):
    if (tabla, fk) not in _cache_fk:
        with con.cursor() as c:
            c.execute("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = %s AND conrelid = %s::regclass",
                      (fk, tabla))
            _cache_fk[(tabla, fk)] = c.fetchone()[0]
    return _cache_fk[(tabla, fk)]


if __name__ == "__main__":
    main()
