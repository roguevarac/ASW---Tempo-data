"""
Prueba editoriales_controladas_v1.sql con DuckDB (transpilado con sqlglot desde Redshift).
Verifica la logica (territorios, lineas de control, estados, listas), no el rendimiento.
El caso 2701309 usa los datos reales de reporte_cwr/casos/baba_oriley.
Uso:  python3 editoriales_control/tests/test_editoriales.py
"""
import pathlib, sys
import duckdb, sqlglot

SQL = pathlib.Path(__file__).resolve().parent.parent / "editoriales_controladas_v1.sql"
IN_EDITABLE = "u.song_id IN (111111, 222222, 333333)"

con = duckdb.connect()
for s in ("dp_song_metadata", "dp_writer_data"):
    con.execute(f"create schema {s}")
con.execute("""create table dp_song_metadata.song_share_detail_mv(song_id bigint, song_title_tx varchar,
    smp_controlled_ind varchar, publisher_id bigint, publisher_name_tx varchar,
    writer_id bigint, writer_nm varchar, associated_contract_id bigint, associated_contract_nm varchar,
    song_ip_territory_nm varchar)""")
con.execute("create table dp_song_metadata.contract_territories(song_id bigint, contract_id bigint, contract_nm varchar, inclusions varchar, exclusions varchar)")
con.execute("create table dp_writer_data.publisher_v(publisher_id bigint, cae_num bigint)")

EXCL = "Exclude: AFGHANISTAN;ALGERIA;AUSTRALASIA"
mv = [
    # Baba O'Riley (datos reales)
    (2701309, "BABA O'RILEY", "Y", 1063009, "WESTMINSTER MUSIC LTD", 10, "PETE TOWNSHEND", 1525818, "WESTMINSTER MUSIC LTD. (ex. Philippines)", "All Other Contractual Territories"),
    (2701309, "BABA O'RILEY", "Y", 1055780, "TOWSER TUNES LTD.", 10, "PETE TOWNSHEND", 1551999, "ABKCO (Mexico & Phillipines Only)", "MEXICO, PHILIPPINES (REG)"),
    (2701309, "BABA O'RILEY", "N", 2295, "Unknown Publisher", None, None, None, None, "MEXICO, PHILIPPINES (REG)"),
    # Obra con dos writers en la misma editorial, contrato sin linea de control activa, fila repetida
    (1, "OBRA UNO", "Y", 10, "SMP ARG", 100, "ANA", 500, "C ANA", "World"),
    (1, "OBRA UNO", "Y", 10, "SMP ARG", 101, "BETO", 501, "C BETO", "World"),
    (1, "OBRA UNO", "Y", 10, "SMP ARG", 100, "ANA", 500, "C ANA", "World"),
    (1, "OBRA UNO", "N", 99, "OTRA", 102, "CARLA", None, None, "World"),
    # Obra sin editorial controlada
    (3, "OBRA TRES", "N", 99, "OTRA", 300, "FER", None, None, "World"),
    # Obra no pedida
    (5, "OBRA CINCO", "Y", 10, "SMP ARG", 500, "GIL", 700, "C GIL", "World"),
]
ct = [
    (2701309, 1146885, "WESTMINSTER MUSIC LTD. Admin Gen (2000)", "Include: ARGENTINA;BRAZIL;CHILE", None),
    (2701309, 1525818, "WESTMINSTER MUSIC LTD. (ex. Philippines)", "Include: CHINA;HONG KONG;PHILIPPINES", None),
    (2701309, 1551025, "ABKCO Music International Limited", "Include: World", EXCL),
    (2701309, 1551025, "ABKCO Music International Limited (v. anterior)", "Include: World", EXCL),  # repetida
    (2701309, 1551999, "ABKCO (Mexico & Phillipines Only)", "Include: MEXICO;PHILIPPINES", None),
    (1, 500, "C ANA", "Include: World", None),
    (3, 900, "C OTRA", "Include: ARGENTINA", None),
    (5, 700, "C GIL", "Include: World", None),
]
con.executemany("insert into dp_song_metadata.song_share_detail_mv values (" + ",".join("?" * 10) + ")", mv)
con.executemany("insert into dp_song_metadata.contract_territories values (?,?,?,?,?)", ct)
con.executemany("insert into dp_writer_data.publisher_v values (?,?)", [(1063009, 57432381), (10, 123456789), (99, 555)])

texto = SQL.read_text(encoding="utf-8")
assert texto.count("IN (") == 1 and IN_EDITABLE in texto, "tiene que haber un solo IN editable"
texto = texto.replace(IN_EDITABLE, "u.song_id IN (2701309, 1, 3, 4)")
cur = con.execute(sqlglot.parse_one(texto, read="redshift").sql(dialect="duckdb"))
cols = [d[0] for d in cur.description]
res = [dict(zip(cols, r)) for r in cur.fetchall()]

fallas = 0
def check(nombre, cond, extra=""):
    global fallas
    print(("OK   " if cond else "FALLA") + " " + nombre + ("" if cond else f"  -> {extra}"))
    fallas += 0 if cond else 1

by = {(r["tempo_id"], r["territorio_ip"], r["publisher_id"]): r for r in res}
check("columnas", cols == ["tempo_id", "song_title", "territorio_ip", "editorial_controlada", "ipi_editorial",
                           "publisher_id", "writers_representados", "contrato_asociado", "lineas_control_obra"], cols)
check("filas: Baba 2, obra 1 1; obra 3 (no controlada), 4 y 5 no salen", len(res) == 3, [(r["tempo_id"], r["territorio_ip"]) for r in res])

w = by.get((2701309, "All Other Contractual Territories", 1063009), {})
m = by.get((2701309, "MEXICO, PHILIPPINES (REG)", 1055780), {})
check("Baba: Westminster en All Other Contractual Territories", w.get("editorial_controlada") == "WESTMINSTER MUSIC LTD" and w.get("ipi_editorial") == 57432381, w)
check("Baba: Towser en MEXICO, PHILIPPINES (REG), sin IPI", m.get("editorial_controlada") == "TOWSER TUNES LTD." and m.get("ipi_editorial") is None, m)
check("Baba: contrato asociado con su territorio", w.get("contrato_asociado") == "WESTMINSTER MUSIC LTD. (ex. Philippines) (Include: CHINA;HONG KONG;PHILIPPINES)", w.get("contrato_asociado"))
lineas = w.get("lineas_control_obra") or ""
check("Baba: lineas de control incluyen ABKCO World con Exclude", f"(Include: World / {EXCL})" in lineas, lineas)
check("Baba: 4 lineas de control (la repetida una sola vez)", lineas.count(" | ") == 3, lineas)
check("Baba: mismas lineas en las dos filas", lineas == m.get("lineas_control_obra"), m.get("lineas_control_obra"))
check("Baba: Unknown Publisher no aparece", all(k[2] != 2295 for k in by))

u = by.get((1, "World", 10), {})
check("obra 1: writers sin repetir", u.get("writers_representados") == "ANA (100) | BETO (101)", u.get("writers_representados"))
check("obra 1: contrato sin linea de control activa", u.get("contrato_asociado") == "C ANA (Include: World) | C BETO (sin línea de control activa)", u.get("contrato_asociado"))
check("obra 1: editorial no controlada no aparece", (1, "World", 99) not in by)

check("obra 3 (sin editorial controlada) no aparece", all(k[0] != 3 for k in by))
check("obra 5 no pedida no aparece", all(k[0] != 5 for k in by))
print("\nTodo OK" if not fallas else f"\n{fallas} fallas")
sys.exit(1 if fallas else 0)
