"""
Prueba editoriales_controladas_v1.sql con DuckDB (transpilado con sqlglot desde Redshift).
Verifica la logica (estados, sumas por grupo IP, listas), no el rendimiento.
Uso:  python3 editoriales_control/tests/test_editoriales.py
"""
import pathlib, sys
import duckdb, sqlglot

SQL = pathlib.Path(__file__).resolve().parent.parent / "editoriales_controladas_v1.sql"

con = duckdb.connect()
for s in ("dp_song_metadata", "public"):
    con.execute(f"create schema {s}")
con.execute("""create table dp_song_metadata.song_share_detail_mv(song_id bigint, song_title_tx varchar,
    smp_controlled_ind varchar, publisher_id bigint, publisher_name_tx varchar, publisher_capacity_type_cd varchar,
    writer_id bigint, writer_nm varchar, associated_contract_id bigint, associated_contract_nm varchar,
    song_ip_territory_nm varchar, publisher_performance_pc double, publisher_mechanical_pc double, publisher_sync_pc double)""")

rows = [
    # 1) Dos writers con la misma editorial SMP en World: 25 + 25 = 50. Tercero no controlado.
    (1, "OBRA UNO", "Y", 10, "SMP ARG", "OP", 100, "ANA", 500, "C ANA", "World", 25, 50, 50),
    (1, "OBRA UNO", "Y", 10, "SMP ARG", "OP", 101, "BETO", 501, "C BETO", "World", 25, 50, 50),
    (1, "OBRA UNO", "N", 99, "OTRA", "OP", 102, "CARLA", None, None, "World", 50, 0, 0),
    # fila duplicada (otro nivel de la jerarquia): no debe sumar dos veces
    (1, "OBRA UNO", "Y", 10, "SMP ARG", "OP", 100, "ANA", 500, "C ANA", "World", 25, 50, 50),
    # 2) Editorial con grupo propio de Mexico distinto al World; y una segunda editorial SMP (SE)
    (2, "OBRA DOS", "Y", 20, "SMP MX", "OP", 200, "DANI", 600, "C DANI", "World", 50, 100, 100),
    (2, "OBRA DOS", "Y", 20, "SMP MX", "OP", 200, "DANI", 600, "C DANI", "Mexico", 25, 50, 50),
    (2, "OBRA DOS", "Y", 21, "SMP US", "SE", 201, "EVA", 601, "C EVA", "World", 10, 10, 10),
    # 3) Obra sin editorial controlada
    (3, "OBRA TRES", "N", 99, "OTRA", "OP", 300, "FER", None, None, "World", 100, 100, 100),
    (3, "OBRA TRES", "N", 98, "OTRA 2", "SE", 300, "FER", None, None, "World", 0, 0, 0),
    # 5) Obra no pedida
    (5, "OBRA CINCO", "Y", 10, "SMP ARG", "OP", 500, "GIL", 700, "C GIL", "World", 50, 50, 50),
]
con.executemany("insert into dp_song_metadata.song_share_detail_mv values (" + ",".join("?" * 14) + ")", rows)

texto = SQL.read_text(encoding="utf-8")
assert "s.song_id IN (111111, 222222, 333333)" in texto, "no se encontro el IN editable"
# obra 5 existe en la MV pero no se pide: no debe salir; obra 4 no existe: no sale
texto = texto.replace("s.song_id IN (111111, 222222, 333333)", "s.song_id IN (1, 2, 3, 4)")
tree = sqlglot.parse_one(texto, read="redshift")
cur = con.execute(tree.sql(dialect="duckdb"))
cols = [d[0] for d in cur.description]
res = [dict(zip(cols, r)) for r in cur.fetchall()]

fallas = 0
def check(nombre, cond, extra=""):
    global fallas
    print(("OK   " if cond else "FALLA") + " " + nombre + ("" if cond else f"  -> {extra}"))
    fallas += 0 if cond else 1

by = {(r["tempo_id"], r["publisher_id"]): r for r in res}
check("cantidad de filas (1:1, 2:2, 3:1; 4 sin datos y 5 no pedida no salen)", len(res) == 4, res)
r = by.get((1, 10), {})
check("obra 1: suma por grupo entre writers = 50, sin duplicar", (r.get("perf_pc_max"), r.get("mech_pc_max")) == (50, 100), r)
check("obra 1: writers representados", r.get("writers_representados") == "ANA (100) | BETO (101)", r.get("writers_representados"))
check("obra 1: contratos", r.get("contratos_asociados") == "C ANA (500) | C BETO (501)", r.get("contratos_asociados"))
check("obra 1: editorial no controlada no aparece", (1, 99) not in by)
r = by.get((2, 20), {})
check("obra 2: min/max entre grupos", (r.get("perf_pc_min"), r.get("perf_pc_max")) == (25, 50), r)
check("obra 2: detalle por grupo", r.get("detalle_por_grupo_ip") == "MEXICO: P 25.00 / M 50.00 / S 50.00 | WORLD: P 50.00 / M 100.00 / S 100.00", r.get("detalle_por_grupo_ip"))
check("obra 2: segunda editorial SMP", by.get((2, 21), {}).get("capacidad") == "SE", by.get((2, 21)))
r = by.get((3, None), {})
check("obra 3: SIN EDITORIAL CONTROLADA", r.get("estado") == "SIN EDITORIAL CONTROLADA" and r.get("titulo") == "OBRA TRES", r)
check("obra 5 no pedida no aparece", all(k[0] != 5 for k in by))
print("\nTodo OK" if not fallas else f"\n{fallas} fallas")
sys.exit(1 if fallas else 0)
