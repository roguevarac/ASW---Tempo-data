"""
Compara la base propia contra la estructura extraída de Supabase (esquema_supabase.csv).
Corre extraer_esquema.sql (secciones 1-12: base de datos) sobre la base propia y lista,
objeto por objeto, lo que coincide, lo que falta y lo nuevo.

Uso: PGURL=postgresql://postgres@localhost:54340/ranking python3 sistema_ranking/tests/comparar_con_supabase.py
Sale con error si falta algún objeto de Supabase que no esté en la lista de cambios a propósito.
"""
import csv, io, os, pathlib, subprocess, sys, collections
RAIZ = pathlib.Path(__file__).resolve().parents[2]
sql = (RAIZ / "migracion_supabase/extraer_esquema.sql").read_text(encoding="utf-8")
sql = sql.split("UNION ALL\n-- 13.")[0]
sql = "\n".join(l for l in sql.split("\n") if not l.strip().startswith("--")).strip().rstrip(";")
out = subprocess.run(["psql", os.environ["PGURL"], "-At", "-c", f"COPY ({sql}) TO STDOUT WITH CSV HEADER"],
                     capture_output=True, text=True)
if out.returncode:
    sys.exit(out.stderr)
nuevo = list(csv.DictReader(io.StringIO(out.stdout)))
viejo = list(csv.DictReader(open(RAIZ / "migracion_supabase/origen/esquema_supabase.csv", encoding="utf-8")))
IGNORAR = {"permiso", "tamano", "bucket", "bucket_contenido", "auth_total", "auth_proveedor", "politica_storage"}
# Cambios hechos a propósito (ver README): no cuentan como pérdida.
A_PROPOSITO = {("extension", "pg_cron"), ("extension", "pg_net"), ("extension", "supabase_vault"),
               ("extension", "pg_stat_statements"),  # estadísticas: opcional, no la usa ninguna función
               # Tempo ID: los marcadores (UNCONTROLLED, COMPILADO) se repiten; solo el número es único
               # (db/mejoras/07_marcadores.sql: índice único parcial y trigger que no copia marcadores a territory_control).
               ("restriccion UNIQUE", "public.tracks_master.uq_tracks_master_tempo_id"),
               ("restriccion FK", "public.territory_tracks.fk_territory_tempo_id"),
               ("funcion", "public.trg_sync_tempo_id_to_territory"),
               # Limpieza y fusión real (db/mejoras/04 y 09): tildes mal codificadas y "…"; las cargas de charts y de
               # Tempo IDs usan los alias de las obras unificadas, suman streams y solo admiten los valores estándar.
               ("funcion", "public.fn_normalize_text"), ("funcion", "public.fn_upsert_ranking_row"),
               ("funcion", "public.fn_upsert_master_tempo_batch"),
               # Descarga de la tabla por territorio con el orden nuevo y Ticket/Fecha (db/mejoras/04).
               ("funcion", "public.fn_territory_exportar"),
               # Estado de trabajo con RECLAMO ACTIVO, REVISAR NOT WORK y REVISAR % (db/mejoras/10_estado_trabajo.sql).
               ("funcion", "public.trg_bo_report_auto_revisar")}
k = lambda r: (r["tipo"], r["objeto"], r["definicion"])
V = {k(r) for r in viejo if r["tipo"] not in IGNORAR}
N = {k(r) for r in nuevo if r["tipo"] not in IGNORAR}
print("objetos de Supabase:", len(V), dict(collections.Counter(t for t, _, _ in V)))
print("idénticos en la base propia:", len(V & N))
faltan = sorted(x for x in V - N if (x[0], x[1]) not in A_PROPOSITO)
print("faltan o cambiaron:")
for t, o, d in faltan:
    print("  -", t, o)
print("cambios a propósito:", sorted(o for t, o, d in V - N if (t, o) in A_PROPOSITO))
print("nuevos en la base propia:")
for t, o, d in sorted(N - V):
    print("  +", t, o)
sys.exit(1 if faltan else 0)
