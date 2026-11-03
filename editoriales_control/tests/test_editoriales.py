"""
Prueba editoriales_controladas_v1.sql con DuckDB (transpilado con sqlglot desde Redshift).
Verifica la logica (estados, sumas por grupo IP, listas), no el rendimiento.
Uso:  python3 editoriales_control/tests/test_editoriales.py
"""
import pathlib, sys
import duckdb, sqlglot

SQL = pathlib.Path(__file__).resolve().parent.parent / "editoriales_controladas_v1.sql"

con = duckdb.connect()
for s in ("dp_song_metadata", "dp_writer_data"):
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
con.execute("create table dp_writer_data.publisher_v(publisher_id bigint, cae_num bigint)")
# 10 y 20 con IPI; 21 sin fila en publisher_v (IPI vacio, no se pierde la fila); 99 no controlada
con.executemany("insert into dp_writer_data.publisher_v values (?,?)", [(10, 123456789), (20, 987654321), (99, 555)])
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
check("obra 1: writers representados", r.get("writers_representados") == "ANA (100) | BETO (101)", r.get("writers_representados"))
check("obra 1: editorial no controlada no aparece", (1, 99) not in by)
check("obra 1: columnas pedidas", (r.get("song_title"), r.get("editorial_controlada"), r.get("ipi_editorial")) == ("OBRA UNO", "SMP ARG", 123456789), r)
check("primeras columnas: tempo_id, song_title, editorial_controlada, ipi_editorial", cols[:4] == ["tempo_id", "song_title", "editorial_controlada", "ipi_editorial"], cols[:4])
check("obra 2: segunda editorial SMP", by.get((2, 21), {}).get("capacidad") == "SE", by.get((2, 21)))
check("obra 2: editorial sin IPI sale con IPI vacio", (2, 21) in by and by[(2, 21)]["ipi_editorial"] is None, by.get((2, 21)))
r = by.get((3, None), {})
check("sin columnas de contratos, grupos ni porcentajes", not any(c in cols for c in ("contratos_asociados", "cant_grupos_ip", "detalle_por_grupo_ip", "perf_pc_min", "sync_pc_max")), cols)
check("obra 1: sin duplicar por fila repetida", sum(1 for k in by if k[0] == 1) == 1)
check("obra 3: SIN EDITORIAL CONTROLADA, sin IPI de la no controlada", r.get("estado") == "SIN EDITORIAL CONTROLADA" and r.get("song_title") == "OBRA TRES" and r.get("ipi_editorial") is None, r)
check("obra 5 no pedida no aparece", all(k[0] != 5 for k in by))
print("\nTodo OK" if not fallas else f"\n{fallas} fallas")
sys.exit(1 if fallas else 0)
