"""
Prueba el reporte CWR con un motor local (DuckDB) y datos de ejemplo.
Redshift no es DuckDB: el SQL se transpila con sqlglot (redshift -> duckdb).
Sirve para verificar la LOGICA (grupos, territorios, vencimientos), no el rendimiento
ni los detalles de Redshift. Los datos del caso 2701309 son los reales del diagnostico.

Corre los chequeos sobre la version vigente (v7, una sola sentencia optimizada) y verifica
que v7 y v6 den EXACTAMENTE el mismo resultado que la v5.

Uso:  python3 reporte_cwr/tests/test_reporte.py
"""
import re, sys, pathlib, datetime as dt
import duckdb, sqlglot

ROOT = pathlib.Path(__file__).resolve().parent.parent

def _duck(stmt_sql):
    duck = sqlglot.transpile(stmt_sql, read="redshift", write="duckdb")[0]
    # DuckDB devuelve HUGEINT en REGEXP_INSTR; Redshift no necesita este ajuste.
    duck = re.sub(r"SUBSTRING\(([\w.]+), 1, ([\w.]*pos_excl)\)", r"SUBSTRING(\1, 1, CAST(\2 AS BIGINT))", duck)
    duck = re.sub(r"SUBSTRING\(([\w.]+), ([\w.]*pos_excl)\)", r"SUBSTRING(\1, CAST(\2 AS BIGINT))", duck)
    return duck

def run_file(con, name, ids):
    """Ejecuta el archivo (una sentencia o un script) y devuelve las filas del ultimo SELECT."""
    text = (ROOT / name).read_text(encoding="utf-8")
    text = re.sub(r"song_id IN \(\s*[\d,\s]+\)", "song_id IN (%s)" % ",".join(map(str, ids)), text, count=1)
    text = re.sub(r"INSERT INTO cwr_ids VALUES [^;]+;", "INSERT INTO cwr_ids VALUES %s;" % ",".join(f"({i})" for i in ids), text, count=1)
    text = re.sub(r"REGEXP_REPLACE\('\s*[\d,\s]+'", "REGEXP_REPLACE('%s'" % ",".join(map(str, ids)), text, count=1)
    cur = None
    for stmt in sqlglot.parse(text, read="redshift"):
        if stmt is None:
            continue
        cur = con.execute(_duck(stmt.sql(dialect="redshift")))
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]

con = duckdb.connect()
for sch in ("dp_song_metadata", "dp_deal_metadata"):
    con.execute(f"create schema {sch}")
con.execute("""create table dp_song_metadata.song_v(song_id bigint, song_title_tx varchar, tempo_create_date timestamp, song_not_ours_dt date)""")
con.execute("""create table dp_song_metadata.identifiers_iswc_v(tempo_song_id bigint, ident_iswc_cd varchar, preferred_indicator varchar)""")
con.execute("""create table dp_song_metadata.song_share_detail_mv(song_id bigint, associated_contract_id bigint, associated_contract_nm varchar,
    smp_controlled_ind varchar, writer_id bigint, publisher_id bigint, publisher_name_tx varchar, song_ip_territory_nm varchar,
    publisher_performance_pc double, publisher_mechanical_pc double, publisher_sync_pc double)""")
con.execute("""create table dp_song_metadata.contract_territories(song_id bigint, contract_id bigint, contract_nm varchar, inclusions varchar, exclusions varchar)""")
con.execute("""create table dp_deal_metadata.contract_v(contract_id bigint, contract_nm varchar, orig_office_nm varchar, contract_expiration_dt date)""")

songs, shares, cts, contracts = [], [], [], {}
def song(i, title, nop=None):
    songs.append((i, title, "2013-10-04 22:04:56", nop))
def share(i, grp, contract, ctrl, pub, perf, mech, sync, cname=None, pid=1):
    shares.append((i, contract, cname or (f"C{contract}" if contract else None), ctrl, 1, pid, pub, grp, perf, mech, sync))
def ct(i, contract, inc, exc=None, name=None):
    cts.append((i, contract, name or f"C{contract}", inc, exc))
def contract(cid, exp=None, name=None):
    contracts[cid] = (cid, name or f"C{cid}", "London", exp)

WORLD = "Include: World"
PAISES = ["ARGENTINA", "CHILE", "COLOMBIA", "PERU", "URUGUAY"]

# 1) Baba O'Riley 2701309 -- datos reales del diagnostico
song(2701309, "BABA O'RILEY")
share(2701309, "All Other Contractual Territories", 1525818, "Y", "WESTMINSTER MUSIC LTD", 50, 100, 100, "WESTMINSTER MUSIC LTD. (ex. Philippines)", 1063009)
share(2701309, "MEXICO, PHILIPPINES (REG)", 1551999, "Y", "TOWSER TUNES LTD.", 6.66, 13.33, 13.33, "ABKCO (Mexico & Phillipines Only)", 1055780)
share(2701309, "MEXICO, PHILIPPINES (REG)", None, "N", "Unknown Publisher", 43.34, 86.67, 86.67, None, 2295)
ct(2701309, 1146885, "Include: ARGENTINA;BRAZIL;CENTRAL AMERICA;CHILE;COLOMBIA;ECUADOR;ECUADOR (REG);MEXICO;PERU;PERU (REG);URUGUAY;URUGUAY (REG);VENEZUELA;VENEZUELA (REG)")
ct(2701309, 1525818, "Include: CHINA;HONG KONG;INDONESIA;KOREA REPUBLIC OF;MALAYSIA;PHILIPPINES;PHILIPPINES (REG);SINGAPORE;TAIWAN;THAILAND")
ct(2701309, 1551025, WORLD, "Exclude: AFGHANISTAN;ALGERIA;AUSTRALASIA;AUSTRALIA;AUSTRIA;AUSTRIA (REG);BAHRAIN;BULGARIA;BULGARIA (REG);CANADA;CROATIA;CROATIA (REG);CZECH REPUBLIC;CZECH REPUBLIC (REG);EGYPT;GERMANY;HUNGARY;HUNGARY (REG);IRAN ISLAMIC REPUBLIC OF;IRAQ;IRELAND;IRELAND (REG);ISRAEL;JAPAN;JORDAN;KUWAIT;LEBANON;MOROCCO;NEW ZEALAND;OMAN;PAKISTAN;QATAR;ROMANIA;ROMANIA (REG);SAUDI ARABIA;SERBIA;SERBIA (REG);SLOVAKIA;SLOVENIA;SPAIN")
ct(2701309, 1551999, "Include: INDONESIA;INDONESIA (REG);MALAYSIA;MEXICO;PHILIPPINES;PHILIPPINES (REG)")
for c in (1146885, 1525818, 1551025, 1551999): contract(c)

# 2) Ella Dijo: grupo propio de Argentina + grupo generico. Argentina = 25 (no 25 + 12.5)
song(100, "ELLA DIJO")
share(100, "ARGENTINA", 10, "Y", "SMP", 25, 25, 25)
share(100, "All Other Contractual Territories", 10, "Y", "SMP", 50, 50, 50)
ct(100, 10, WORLD); contract(10)

# 3) Sin Sentimientos: unica linea excluye Colombia -> NVFT en Colombia
song(200, "SIN SENTIMIENTOS")
share(200, "ALL CONTRACTUAL TERRITORIES", 20, "Y", "SMP", 50, 100, 100)
ct(200, 20, WORLD, "Exclude: COLOMBIA;MEXICO"); contract(20)
# 3b) igual, pero otra linea de control cubre Colombia -> controlado, con alerta
song(201, "SIN SENTIMIENTOS B")
share(201, "ALL CONTRACTUAL TERRITORIES", 20, "Y", "SMP", 50, 100, 100)
ct(201, 20, WORLD, "Exclude: COLOMBIA;MEXICO"); ct(201, 21, "Include: COLOMBIA;PERU"); contract(21)

# 4) Te Encontre: lista explicita sin Colombia
song(300, "TE ENCONTRE")
share(300, "ALL OTHER CONTRACTUAL TERRITORIES", 30, "Y", "SMP", 50, 100, 100)
ct(300, 30, "Include: ARGENTINA;CHILE;MEXICO"); contract(30)

# 5) Obra ausente de la MV -> SIN DATOS
song(400, "[DELETE] SIRENA")

# 6) Vencimientos
song(500, "MIXTO");  share(500, "ALL CONTRACTUAL TERRITORIES", 50, "Y", "SMP", 50, 50, 50)
ct(500, 50, WORLD); ct(500, 51, WORLD); contract(50, None); contract(51, dt.date(2000, 1, 1))
song(501, "TODOS VENCIDOS"); share(501, "ALL CONTRACTUAL TERRITORIES", 52, "Y", "SMP", 50, 50, 50)
ct(501, 52, WORLD); contract(52, dt.date(2000, 1, 1))
song(502, "VIGENTE"); share(502, "ALL CONTRACTUAL TERRITORIES", 53, "Y", "SMP", 50, 50, 50)
ct(502, 53, WORLD); contract(53, dt.date(2999, 1, 1))

# 7) Participacion sin contrato
song(600, "SIN CONTRATO"); share(600, "ALL CONTRACTUAL TERRITORIES", None, "Y", "SMP", 50, 50, 50)

# 8) NOP
song(700, "NOP", nop=dt.date(2000, 1, 1)); share(700, "ALL CONTRACTUAL TERRITORIES", 70, "Y", "SMP", 50, 50, 50)
ct(700, 70, WORLD); contract(70)

# 9) Texto prestado de otra obra del mismo contrato / contrato sin ningun texto
song(800, "PRESTADO"); share(800, "ALL CONTRACTUAL TERRITORIES", 80, "Y", "SMP", 50, 50, 50)
song(801, "OTRA OBRA"); share(801, "ALL CONTRACTUAL TERRITORIES", 80, "Y", "SMP", 10, 10, 10); ct(801, 80, WORLD); contract(80)
song(802, "SIN TEXTO"); share(802, "ALL CONTRACTUAL TERRITORIES", 81, "Y", "SMP", 50, 50, 50); contract(81)

# 10) Grupo "World ex Argentina"
song(900, "WORLD EX ARG"); share(900, "WORLD EX ARGENTINA", 90, "Y", "SMP", 50, 50, 50)
ct(900, 90, WORLD); contract(90)

# 11) Grupo nombra pais pero no es de SMP -> NVFT (no se cae al generico)
song(950, "GRUPO AJENO"); share(950, "COLOMBIA", 95, "N", "OTRO", 50, 50, 50); share(950, "ALL OTHER CONTRACTUAL TERRITORIES", 95, "Y", "SMP", 40, 40, 40)
ct(950, 95, WORLD); contract(95)

# 12) Acentos, minusculas y sufijo (REG)
song(1200, "ACENTOS"); share(1200, "ALL CONTRACTUAL TERRITORIES", 120, "Y", "SMP", 50, 50, 50)
ct(1200, 120, "Include: Argentina (REG);PERÚ"); contract(120)
# 13) Regiones: incluye Latin America, excluye Uruguay
song(1300, "REGION"); share(1300, "ALL CONTRACTUAL TERRITORIES", 130, "Y", "SMP", 50, 50, 50)
ct(1300, 130, "Include: LATIN AMERICA", "Exclude: URUGUAY"); contract(130)
# 13b) Excluye una region completa
song(1301, "REGION EXCLUIDA"); share(1301, "ALL CONTRACTUAL TERRITORIES", 131, "Y", "SMP", 50, 50, 50)
ct(1301, 131, WORLD, "Exclude: SOUTH AMERICA"); contract(131)
# 14) Dos publishers controlados en el mismo grupo se suman
song(1400, "DOS PUBLISHERS"); share(1400, "ALL CONTRACTUAL TERRITORIES", 140, "Y", "SMP", 25, 25, 25, pid=1)
share(1400, "ALL CONTRACTUAL TERRITORIES", 140, "Y", "SMP", 25, 25, 25, pid=2); ct(1400, 140, WORLD); contract(140)
# 15) Filas duplicadas en contract_territories (mismo contrato, distinto nombre): no duplican
song(1500, "DUPLICADOS"); share(1500, "ALL CONTRACTUAL TERRITORIES", 150, "Y", "SMP", 50, 50, 50)
ct(1500, 150, WORLD, name="NOMBRE VIEJO"); ct(1500, 150, WORLD, name="NOMBRE NUEVO"); contract(150)
# 16) Dos grupos que nombran al pais con la misma prioridad
song(1600, "EMPATE"); share(1600, "ARGENTINA", 160, "Y", "SMP", 30, 30, 30); share(1600, "ARGENTINA, URUGUAY", 160, "Y", "SMP", 40, 40, 40); ct(1600, 160, WORLD); contract(160)
# 17) Grupo regional (Latin America) gana al generico
song(1700, "GRUPO REGIONAL"); share(1700, "LATIN AMERICA", 170, "Y", "SMP", 20, 20, 20); share(1700, "ALL OTHER CONTRACTUAL TERRITORIES", 170, "Y", "SMP", 50, 50, 50)
ct(1700, 170, WORLD); contract(170)
# 18) Grupo "nombra al pais" sin linea de control que lo cubra -> NVFT
song(1800, "SIN LINEA"); share(1800, "ARGENTINA", 180, "Y", "SMP", 50, 50, 50); ct(1800, 180, "Include: JAPAN"); contract(180)

con.executemany("insert into dp_song_metadata.song_v values (?,?,?,?)", songs)
con.executemany("insert into dp_song_metadata.song_share_detail_mv values (?,?,?,?,?,?,?,?,?,?,?)", shares)
con.executemany("insert into dp_song_metadata.contract_territories values (?,?,?,?,?)", cts)
con.executemany("insert into dp_deal_metadata.contract_v values (?,?,?,?)", list(contracts.values()))

ids = [s[0] for s in songs]
rows_v5 = run_file(con, "reporte_cwr_x_territorio_v5.sql", ids)
rows_v6 = run_file(con, "reporte_cwr_x_territorio_v6.sql", ids)
rows = run_file(con, "reporte_cwr_x_territorio_v7.sql", ids)
R = {(r["song_id"], r["pais"]): r for r in rows}

fails = []
def check(name, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + name + ("" if cond else "  -> " + str(extra)))
    if not cond: fails.append(name)
def trio(i, p): r = R[(i, p)]; return (r["performance_pc_total"], r["mechanical_pc_total"], r["sync_pc_total"])

check("filas = obras x 5 paises", len(rows) == len(songs) * 5, len(rows))
for p in PAISES:
    check(f"Baba O'Riley {p} = 50/100/100", trio(2701309, p) == ("50.00", "100.00", "100.00"), trio(2701309, p))
check("Baba O'Riley alerta 'otra linea'", "OTRA LINEA" in (R[(2701309, "ARGENTINA")]["alertas"] or ""))
check("Baba O'Riley no usa a Towser/Unknown (grupo Mexico)", "TOWSER" not in R[(2701309, "CHILE")]["publishers"])
check("Baba O'Riley lineas que cubren incluye 1551025 y no 1525818",
      "1551025" in R[(2701309, "CHILE")]["lineas_que_cubren_el_pais"] and "1525818" not in R[(2701309, "CHILE")]["lineas_que_cubren_el_pais"],
      R[(2701309, "CHILE")]["lineas_que_cubren_el_pais"])
check("Ella Dijo Argentina = 25 (no suma grupos)", trio(100, "ARGENTINA") == ("25.00", "25.00", "25.00"), trio(100, "ARGENTINA"))
check("Ella Dijo Chile = 50", trio(100, "CHILE")[0] == "50.00")
check("Sin Sentimientos Colombia = NVFT", trio(200, "COLOMBIA") == ("NVFT",) * 3, trio(200, "COLOMBIA"))
check("Sin Sentimientos Peru = 50", trio(200, "PERU")[0] == "50.00")
check("Sin Sentimientos B Colombia controlado por otra linea", trio(201, "COLOMBIA")[0] == "50.00" and "OTRA LINEA" in (R[(201, "COLOMBIA")]["alertas"] or ""), R[(201, "COLOMBIA")]["alertas"])
check("Te Encontre Colombia = NVFT", trio(300, "COLOMBIA") == ("NVFT",) * 3, trio(300, "COLOMBIA"))
check("Te Encontre Argentina = 50", trio(300, "ARGENTINA")[0] == "50.00")
check("Obra ausente = SIN DATOS", trio(400, "CHILE") == ("SIN DATOS",) * 3 and "AUSENTE" in R[(400, "CHILE")]["alertas"])
check("Mixto: sin venc + vencida = MIXTO", R[(500, "CHILE")]["estado_contrato"] == "MIXTO (alguno vencido)", R[(500, "CHILE")]["estado_contrato"])
check("Todos vencidos", R[(501, "CHILE")]["estado_contrato"] == "TODOS VENCIDOS", R[(501, "CHILE")]["estado_contrato"])
check("Vigente", R[(502, "CHILE")]["estado_contrato"] == "VIGENTE", R[(502, "CHILE")]["estado_contrato"])
check("Sin contrato asociado cuenta y alerta", trio(600, "CHILE")[0] == "50.00" and "SIN CONTRATO" in R[(600, "CHILE")]["alertas"], R[(600, "CHILE")]["alertas"])
check("NOP", trio(700, "CHILE") == ("NOP",) * 3)
check("Texto prestado de otra obra + alerta", trio(800, "CHILE")[0] == "50.00" and "OTRA OBRA DEL CONTRATO" in (R[(800, "CHILE")]["alertas"] or ""), R[(800, "CHILE")]["alertas"])
check("Contrato sin texto en ningun lado = NVFT + alerta", trio(802, "CHILE") == ("NVFT",) * 3 and "SIN TEXTO" in (R[(802, "CHILE")]["alertas"] or ""), (trio(802, "CHILE"), R[(802, "CHILE")]["alertas"]))
check("World ex Argentina: Argentina NVFT", trio(900, "ARGENTINA") == ("NVFT",) * 3, trio(900, "ARGENTINA"))
check("World ex Argentina: Chile 50", trio(900, "CHILE")[0] == "50.00")
check("Grupo que nombra al pais pero es ajeno -> NVFT (no cae al generico)", trio(950, "COLOMBIA") == ("NVFT",) * 3, trio(950, "COLOMBIA"))
check("Grupo ajeno: otros paises usan el generico (40)", trio(950, "CHILE")[0] == "40.00")
check("Ninguna fila con total > 100", all(not (r["alertas"] or "").count("SUPERA") for r in rows))

check("Acentos/REG: Argentina y Peru controlados", trio(1200, "ARGENTINA")[0] == "50.00" and trio(1200, "PERU")[0] == "50.00", (trio(1200, "ARGENTINA"), trio(1200, "PERU")))
check("Acentos/REG: Chile NVFT", trio(1200, "CHILE")[0] == "NVFT")
check("Region incluida: Chile 50", trio(1300, "CHILE")[0] == "50.00")
check("Region incluida + pais excluido: Uruguay NVFT", trio(1300, "URUGUAY")[0] == "NVFT", trio(1300, "URUGUAY"))
check("Region excluida (South America): todos NVFT", all(trio(1301, p)[0] == "NVFT" for p in PAISES), [trio(1301, p) for p in PAISES])
check("Dos publishers se suman (50)", trio(1400, "CHILE")[0] == "50.00", trio(1400, "CHILE"))
check("Filas duplicadas de territorio no duplican (50)", trio(1500, "CHILE")[0] == "50.00", trio(1500, "CHILE"))
check("Empate de grupos alertado y un solo grupo (30)", trio(1600, "ARGENTINA")[0] == "30.00" and "MISMA PRIORIDAD" in (R[(1600, "ARGENTINA")]["alertas"] or ""), (trio(1600, "ARGENTINA"), R[(1600, "ARGENTINA")]["alertas"]))
check("Grupo regional gana al generico (20)", trio(1700, "CHILE")[0] == "20.00", trio(1700, "CHILE"))
check("Grupo que nombra al pais sin linea que lo cubra = NVFT", trio(1800, "ARGENTINA")[0] == "NVFT", trio(1800, "ARGENTINA"))

key = lambda r: (r["song_id"], r["pais"])
norm = lambda rs: [tuple(sorted(r.items())) for r in sorted(rs, key=key)]
def difs(a, b):
    out = []
    for ra, rb in zip(sorted(a, key=key), sorted(b, key=key)):
        for k in ra:
            if ra[k] != rb.get(k):
                out.append((key(ra), k, ra[k], rb.get(k)))
    return out[:6]
check("v7 da exactamente el mismo resultado que v5 (todas las columnas)", norm(rows) == norm(rows_v5), difs(rows, rows_v5))
check("v6 da exactamente el mismo resultado que v5 (todas las columnas)", norm(rows_v6) == norm(rows_v5), difs(rows_v6, rows_v5))
check("v7 tiene las mismas columnas y en el mismo orden que v5", list(rows[0].keys()) == list(rows_v5[0].keys()),
      (list(rows[0].keys()), list(rows_v5[0].keys())))

print(f"\nFallas: {len(fails)}")
sys.exit(1 if fails else 0)
