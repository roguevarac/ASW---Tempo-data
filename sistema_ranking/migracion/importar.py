"""
Importa en el sistema propio la carpeta generada por exportar_supabase.py.

    PGURL=postgresql://postgres:CLAVE@localhost:5432/ranking STORAGE_DIR=/data/storage \
        python importar.py exportacion [--reemplazar] [--archivos-desde CARPETA ...] [--permitir-faltantes]

- PGURL es el superusuario de la base NUEVA (ya instalada con db/instalar.sh).
- Todo entra en una sola transacción: si algo falla no queda nada a medias.
- Los triggers no se disparan durante la carga (no se generan auditorías ni fechas nuevas:
  los datos quedan exactamente como estaban en Supabase).
- Compara filas contra manifiesto.json; ante cualquier diferencia no importa nada.
- Sin --reemplazar se niega a cargar sobre una base que ya tiene datos.

Archivos del historial de cargas (los que se descargan desde la pestaña Historial):
- Se usan los bajados del bucket, verificados con su sha256.
- Los que no se bajaron se buscan en las carpetas de --archivos-desde (ej. las de OneDrive con los charts):
  por el nombre original del archivo y el mismo tamaño en bytes que tenía en Supabase.
- Si alguno no aparece, se frena y lo lista en archivos_faltantes.txt. Con --permitir-faltantes se importa igual:
  la carga sigue en el historial, pero su botón de descarga avisa que el archivo no está.
"""
import csv
import hashlib
import json
import os
import pathlib
import re
import shutil
import sys

import psycopg

args = sys.argv[1:]
if not args or args[0].startswith("--"):
    sys.exit(__doc__)
ORIGEN = pathlib.Path(args[0]).resolve()
REEMPLAZAR = "--reemplazar" in args
PERMITIR_FALTANTES = "--permitir-faltantes" in args
CARPETAS = [pathlib.Path(args[i + 1]) for i, a in enumerate(args) if a == "--archivos-desde" and i + 1 < len(args)]
PGURL = os.environ.get("PGURL") or sys.exit("Falta PGURL")
STORAGE_DIR = pathlib.Path(os.environ.get("STORAGE_DIR") or sys.exit("Falta STORAGE_DIR")).resolve()
BUCKET = "csv-uploads"
TABLAS = [
    "app_users", "tracks_master", "territory_tracks", "territory_control", "territory_bo_report",
    "territory_tempo_report", "csv_uploads", "audit_logs", "bo_export_counter",
    "staging_tempo_historico", "resultado_tempo_historico",
]
manifiesto = json.loads((ORIGEN / "manifiesto.json").read_text(encoding="utf-8"))
csv.field_size_limit(1 << 30)


def sha256(ruta):
    h = hashlib.sha256()
    with open(ruta, "rb") as f:
        for bloque in iter(lambda: f.read(1 << 20), b""):
            h.update(bloque)
    return h.hexdigest()


def leer_csv(nombre):
    ruta = ORIGEN / "tablas" / nombre
    if not ruta.exists() or ruta.stat().st_size == 0:
        return []
    with open(ruta, encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


# ------------------------------------------------------------------ plan de archivos (antes de tocar la base)
def planear_archivos():
    """Devuelve {nombre en el bucket: archivo de origen} y la lista de faltantes con el motivo."""
    plan, faltantes = {}, []
    for nombre, info in manifiesto["archivos"].items():
        ruta = ORIGEN / "archivos" / BUCKET / nombre
        if not ruta.exists() or sha256(ruta) != info["sha256"]:
            sys.exit(f"Archivo faltante o alterado en la exportación: {nombre}\nCorregí la exportación antes de importar.")
        plan[nombre] = ruta

    pendientes = [o for o in leer_csv("storage_objects.csv") if o["name"] not in plan]
    if not pendientes:
        return plan, faltantes
    original = {u["file_path"]: u["filename"] for u in leer_csv("csv_uploads.csv") if u.get("file_path")}
    indice = {}
    for carpeta in CARPETAS:
        if not carpeta.is_dir():
            sys.exit(f"No existe la carpeta {carpeta}")
        for p in carpeta.rglob("*"):
            if p.is_file():
                indice.setdefault(p.name.lower(), []).append(p)
    print(f"Buscando {len(pendientes)} archivos en {len(CARPETAS)} carpetas ({sum(map(len, indice.values()))} archivos)...")

    for o in pendientes:
        nombre = o["name"]
        tam = int((json.loads(o["metadata"]) if o.get("metadata") else {}).get("size", -1))
        base = nombre.rsplit("/", 1)[-1]
        nombres = {n.lower() for n in (original.get(nombre), base, re.sub(r"^\d+_", "", base)) if n}
        candidatos = [p for n in nombres for p in indice.get(n, [])]
        if tam >= 0:
            candidatos = [p for p in candidatos if p.stat().st_size == tam]
        distintos = {sha256(p): p for p in candidatos}
        if len(distintos) == 1:
            plan[nombre] = next(iter(distintos.values()))
        elif not distintos:
            faltantes.append(f"{nombre}\tno encontrado (buscado como: {', '.join(sorted(nombres))}; {tam} bytes)")
        elif tam < 0:
            faltantes.append(f"{nombre}\tvarios archivos con ese nombre y sin tamaño para elegir: "
                             + ", ".join(str(p) for p in distintos.values()))
        else:
            # Mismo nombre y tamaño pero distinto contenido: no hay forma segura de elegir.
            faltantes.append(f"{nombre}\tambiguo: " + ", ".join(str(p) for p in distintos.values()))
    return plan, faltantes


# ------------------------------------------------------------------ carga
def columnas_destino(cur, esquema, tabla):
    cur.execute("""SELECT a.attname FROM pg_attribute a
                   WHERE a.attrelid = %s::regclass AND a.attnum > 0 AND NOT a.attisdropped""",
                (f"{esquema}.{tabla}",))
    return {r[0] for r in cur.fetchall()}


def cargar(cur, esquema, tabla, archivo):
    if archivo.exists() and archivo.stat().st_size > 0:
        with open(archivo, encoding="utf-8", newline="") as f:
            encabezado = next(csv.reader(f))
        sobran = set(encabezado) - columnas_destino(cur, esquema, tabla)
        if sobran:
            sys.exit(f"{esquema}.{tabla}: columnas que no existen en la base nueva: {sorted(sobran)}")
        cols = ", ".join(f'"{c}"' for c in encabezado)
        with open(archivo, "rb") as f, cur.copy(
                f"COPY {esquema}.{tabla} ({cols}) FROM STDIN WITH (FORMAT csv, HEADER true)") as cp:
            while bloque := f.read(1 << 20):
                cp.write(bloque)
    cur.execute(f"SELECT count(*) FROM {esquema}.{tabla}")
    return cur.fetchone()[0]


def _definicion_fk(cur, tabla, fk):
    cur.execute("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = %s AND conrelid = %s::regclass",
                (fk, tabla))
    return cur.fetchone()[0]


def main():
    plan, faltantes = planear_archivos()
    if faltantes:
        try:
            (ORIGEN / "archivos_faltantes.txt").write_text("\n".join(faltantes) + "\n", encoding="utf-8")
            donde = f" (lista completa en {ORIGEN / 'archivos_faltantes.txt'})"
        except OSError:
            donde = ""
        print(f"ATENCIÓN: {len(faltantes)} archivos del historial no se encontraron{donde}. Ejemplos:")
        for f in faltantes[:10]:
            print("  " + f)
        if not PERMITIR_FALTANTES:
            sys.exit("No se importó nada. Agregá más carpetas con --archivos-desde, o --permitir-faltantes "
                     "para importar igual (esas cargas quedan en el historial sin archivo para descargar).")

    diferencias = []
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
        # El seguimiento de envíos (mejora propia, db/mejoras) apunta a las obras: se vacía con ellas.
        propias = [t for t in ("envio_identificadas", "envio_obras", "envios")
                   if cur.execute("SELECT to_regclass(%s) IS NOT NULL", (f"public.{t}",)).fetchone()[0]]
        propias_auth = "".join(f", auth.{t}" for t in ("sesiones", "codigos_clave")
                               if cur.execute("SELECT to_regclass(%s) IS NOT NULL", (f"auth.{t}",)).fetchone()[0])
        cur.execute("TRUNCATE " + ", ".join(f"public.{t}" for t in propias + TABLAS) + propias_auth + ", auth.users, storage.objects")

        n = cargar(cur, "auth", "users", ORIGEN / "tablas" / "auth_users.csv")
        print("auth.users:", n)
        if n != manifiesto["tablas"]["auth.users"]:
            diferencias.append(f"auth.users: {n}, Supabase tenía {manifiesto['tablas']['auth.users']}")
        for t in TABLAS:
            n = cargar(cur, "public", t, ORIGEN / "tablas" / f"{t}.csv")
            print(f"{t}: {n}")
            if n != manifiesto["tablas"][t]:
                diferencias.append(f"{t}: {n} filas, Supabase tenía {manifiesto['tablas'][t]}")
        n = cargar(cur, "storage", "objects", ORIGEN / "tablas" / "storage_objects.csv")
        print("storage.objects:", n)
        if n != manifiesto["tablas"]["storage.objects"]:
            diferencias.append(f"storage.objects: {n}, Supabase tenía {manifiesto['tablas']['storage.objects']}")
        cur.execute("SELECT count(*) FROM public.bo_export_counter")
        if cur.fetchone()[0] == 0:  # el contador del reporte BO tiene que tener su fila
            cur.execute("INSERT INTO public.bo_export_counter (id, counter) VALUES (true, 0)")

        # Las secuencias siguen desde el máximo importado (si no, la próxima carga chocaría con un id existente).
        cur.execute("""SELECT n.nspname, c.relname, a.attname FROM pg_attribute a
                       JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                       WHERE n.nspname = 'public' AND a.attidentity <> '' """)
        for esquema, tabla, col in cur.fetchall():
            cur.execute(f"SELECT setval(pg_get_serial_sequence('{esquema}.{tabla}', '{col}'), "
                        f"coalesce(max({col}), 0) + 1, false) FROM {esquema}.{tabla}")

        # Integridad: se re-crean las claves foráneas, lo que las valida contra todas las filas importadas.
        cur.execute("SET session_replication_role = origin")
        cur.execute("""SELECT conrelid::regclass::text, conname FROM pg_constraint
                       WHERE contype = 'f' AND connamespace IN ('public'::regnamespace, 'storage'::regnamespace)""")
        for tabla, fk in cur.fetchall():
            definicion = _definicion_fk(cur, tabla, fk)
            try:
                cur.execute(f"ALTER TABLE {tabla} DROP CONSTRAINT {fk}, ADD CONSTRAINT {fk} {definicion}")
            except psycopg.errors.ForeignKeyViolation as e:
                con.rollback()
                sys.exit(f"NO se importó nada: datos que no cumplen {fk} ({e.diag.message_detail})")
        if diferencias:
            con.rollback()
            sys.exit("NO se importó nada por estas diferencias:\n  " + "\n  ".join(diferencias))

        # Archivos al disco de la API; recién después se confirma la base.
        destino_bucket = (STORAGE_DIR / BUCKET).resolve()
        for nombre, origen in plan.items():
            destino = (destino_bucket / nombre).resolve()
            if destino_bucket not in destino.parents:
                sys.exit(f"Ruta de archivo inválida: {nombre}")
            destino.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(origen, destino)
        con.commit()
    sin_clave = 0
    with psycopg.connect(PGURL) as con:
        sin_clave = con.execute("SELECT count(*) FROM auth.users WHERE encrypted_password IS NULL").fetchone()[0]
    print(f"Importación completa: {sum(manifiesto['tablas'].values())} filas y {len(plan)} archivos"
          + (f" ({len(faltantes)} archivos del historial no encontrados)." if faltantes else "."))
    if sin_clave:
        print(f"{sin_clave} usuarios sin contraseña: ponésela con admin/usuarios.py clave <email>.")


if __name__ == "__main__":
    main()
