"""
Prueba recaudacion_emmac_smp_latin_v1.sql con DuckDB (transpilado desde Redshift).
Caso SMP Latin: obra 6101269 con los montos del front (34.636,78 / 2.183,33 / 3.705,94 / 29.067,78).
Uso:  python3 financials/tests/test_recaudacion_emmac_smp_latin.py
"""
import pathlib, sys
import duckdb, sqlglot

SQL = pathlib.Path(__file__).resolve().parent.parent / "recaudacion_emmac_smp_latin_v1.sql"
con = duckdb.connect()
for esq in ("public", "dp_statement_lines", "dp_earnings_lines", "dp_song_metadata"):
    con.execute(f"create schema if not exists {esq}")
con.execute("create table public.obras_controladas_pais_resultado(song_id bigint, song_title_tx varchar, pais varchar)")
con.executemany("insert into public.obras_controladas_pais_resultado values (?,?,?)", [
    (6101269, "BAILANDO BACHATA", "CHILE"), (6101269, "BAILANDO BACHATA", "COLOMBIA"),
    (274220, "YOU ARE MY HEART", "CHILE"), (1, "SIN IMPORTES", "CHILE")])
con.execute("""create table dp_statement_lines.statement_lines_v(song_id bigint, processing_office_name varchar, source_name varchar,
    sub_source_name varchar, statement_line_status varchar, semiannual_statement_period date, lc_gross_stmt_am double,
    converted_net_am double, exchange_to_us_currency double)""")
con.executemany("insert into dp_statement_lines.statement_lines_v values (?,?,?,?,?,?,?,?,?)", [
    (274220, "Mexico", "EMMAC", "EMMAC A EN P", "Finalized", "2025-06-30", 1850.0, 1500.0, 18.5),
    (274220, "Mexico", "EMMAC", "EMMAC A EN P", "Finalized", "2025-12-31", 925.0, 750.0, 0.054054054),
    (274220, "Mexico", "EMMAC", "EMMAC A EN P", "Pending", "2025-12-31", 99999.0, 99999.0, 18.5),      # no finalizada
    (274220, "Mexico", "SACM", "SACM", "Finalized", "2025-12-31", 5000.0, 4000.0, 18.5),           # otra fuente
    (274220, "United States", "SMP Mexico", "EMMAC", "Finalized", "2025-12-31", 7777.0, 7777.0, 1.0),     # otra oficina
    (999, "Mexico", "EMMAC", "EMMAC", "Finalized", "2025-12-31", 100.0, 80.0, 18.5),                 # obra no controlada
])
con.execute("""create table dp_earnings_lines.earnings_lines_v(song_id bigint, processing_office_name varchar, source_name varchar,
    accounting_period_dt date, statement_header_id bigint, processing_office_id bigint, statement_line_id bigint,
    earnings_line_id bigint, gross_client_share_of_income_amt double, foreign_nps_am double, gross_nps double,
    gross_royalty_payable double, converted_net_am double)""")
# 6101269 SMP Latin: dos lineas de statement, la primera genera dos lineas de ganancia (converted_net se suma una vez)
con.executemany("insert into dp_earnings_lines.earnings_lines_v values (?,?,?,?,?,?,?,?,?,?,?,?,?)", [
    (6101269, "United States", "SMP Latin", "2025-03-31", 1, 1, 10, 100, 20000.00, 1200.00, 2000.00, 16800.00, 18000.00),
    (6101269, "United States", "SMP Latin", "2025-03-31", 1, 1, 10, 101, 4636.78, 983.33, 705.94, 2947.51, 18000.00),
    (6101269, "United States", "SMP Latin", "2025-09-30", 2, 1, 11, 102, 10000.00, 0.00, 1000.00, 9320.27, 14773.72),
    (6101269, "United States", "YouTube - USA", "2025-09-30", 3, 1, 12, 103, 500.0, 0, 50, 450, 500),   # otra fuente
    (6101269, "Mexico", "SMP Latin", "2025-09-30", 4, 2, 13, 104, 900.0, 0, 90, 810, 900),            # otra oficina
])
con.execute("create table dp_song_metadata.identifiers_iswc_v(tempo_song_id bigint, ident_iswc_cd varchar, preferred_indicator varchar, conflict_indicator varchar)")
con.executemany("insert into dp_song_metadata.identifiers_iswc_v values (?,?,?,?)", [
    (6101269, "T0000000009", "No", "No"), (6101269, "T3333333333", "Yes", "No"), (274220, "T9099014901", "Yes", "No")])

cur = con.execute(sqlglot.parse_one(SQL.read_text(encoding="utf-8"), read="redshift").sql(dialect="duckdb"))
cols = [d[0] for d in cur.description]
R = {r[0]: dict(zip(cols, r)) for r in cur.fetchall()}

fallas = 0
def check(nombre, cond, extra=""):
    global fallas
    print(("OK   " if cond else "FALLA") + " " + nombre + ("" if cond else f"  -> {extra}"))
    fallas += 0 if cond else 1
f = lambda x: None if x is None else round(float(x), 2)

check("una fila por obra con importe; sin importes y no controladas no salen", sorted(R) == [274220, 6101269], sorted(R))
b = R[6101269]
check("SMP Latin = front (34.636,78 / 2.183,33 / 3.705,94 / 29.067,78)",
      (f(b["smp_latin_gross_income_usd"]), f(b["smp_latin_affiliate_nps_usd"]), f(b["smp_latin_domestic_nps_usd"]),
       f(b["smp_latin_client_royalty_usd"])) == (34636.78, 2183.33, 3705.94, 29067.78), b)
check("SMP Latin converted net una vez por linea de statement (32.773,72)", f(b["smp_latin_converted_net_usd"]) == 32773.72, b)
check("obra en dos paises: una fila con la lista", b["paises_controlados"] == "CHILE, COLOMBIA" and b["cantidad_paises"] == 2, b)
check("ISWC preferido Yes", (b["iswc"], b["iswc_preferido"]) == ("T3333333333", "Yes"), b)
y = R[274220]
check("EMMAC: solo oficina Mexico, fuente EMMAC, Finalized; MXN y USD con tc que divide o multiplica",
      (f(y["emmac_gross_mxn"]), f(y["emmac_neto_mxn"]), f(y["emmac_gross_usd"]), f(y["emmac_neto_usd"]), y["emmac_lineas"])
      == (2775.0, 2250.0, 150.0, 121.62, 2), y)
check("total = EMMAC gross USD + SMP Latin gross", f(y["total_recaudado_usd"]) == 150.0 and f(b["total_recaudado_usd"]) == 34636.78, (y, b))
check("orden por total descendente", list(R) == [6101269, 274220], list(R))
print("\nTodo OK" if not fallas else f"\n{fallas} fallas")
sys.exit(1 if fallas else 0)
