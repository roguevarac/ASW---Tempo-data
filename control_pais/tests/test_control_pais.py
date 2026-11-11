"""
Prueba obras_controladas_pais_v1.sql (y su UNLOAD) con DuckDB, sobre los mismos datos
de la prueba de la v8 (reporte_cwr/tests/test_reporte.py, incluye Baba O'Riley real).
Compara obra por obra contra la v8 en CHILE. Diferencias esperadas (documentadas en la
query): la v8 da por controladas las participaciones sin contrato y las que toman el
texto de territorio de otra obra; esta version exige una linea de control que cubra el
pais, y no marca NOP (no lee song_v).

Uso:  python3 control_pais/tests/test_control_pais.py
"""
import re, sys, pathlib, datetime as dt
import duckdb, sqlglot

AQUI = pathlib.Path(__file__).resolve().parent.parent
REPO = AQUI.parent
CWR = REPO / "reporte_cwr"

# Datos de la prueba de la v8: se ejecuta su bloque de carga (de "con = duckdb.connect()"
# hasta los INSERT), sin correr sus consultas.
fuente_v8 = (CWR / "tests" / "test_reporte.py").read_text(encoding="utf-8")
ini = fuente_v8.index("con = duckdb.connect()")
fin = fuente_v8.index("ids = [s[0] for s in songs]")
ns = {"dt": dt, "duckdb": duckdb}
exec(fuente_v8[ini:fin], ns)
con, songs = ns["con"], ns["songs"]

# Esta query toma el titulo de la MV.
con.execute("alter table dp_song_metadata.song_share_detail_mv add column song_title_tx varchar")
con.execute("""update dp_song_metadata.song_share_detail_mv m set song_title_tx = s.song_title_tx
               from dp_song_metadata.song_v s where s.song_id = m.song_id""")
con.execute("insert into dp_song_metadata.identifiers_iswc_v values (2701309, 'T-010.237.425-3', 'Y'), (2701309, 'T-999.999.999-9', 'N')")
# Obras extra para Chile
extra_mv = [
    # grupo propio de Chile de SMP gana al generico
    (3000, "CHILE PROPIO", 300, "Y", 1, 1, "SMP CHILE", "CHILE", 70, 70, 70),
    (3000, "CHILE PROPIO", 300, "Y", 1, 2, "SMP", "ALL OTHER CONTRACTUAL TERRITORIES", 50, 50, 50),
    # elemento por elemento: "CHILEAN ISLANDS" no es CHILE
    (3001, "FALSO CHILE", 301, "Y", 1, 1, "SMP", "ALL CONTRACTUAL TERRITORIES", 50, 50, 50),
    # grupo World ex Chile: no cuenta; otro grupo generico tampoco existe -> no controlada
    (3002, "WORLD EX CHILE", 302, "Y", 1, 1, "SMP", "WORLD EX CHILE", 50, 50, 50),
    # You Are My Heart 274220 (captura de Tempo del usuario): All Other Contractual Territories + UNITED STATES,
    # linea Include: World. Publisher Controlled en All Other = Mech 56.25 / Perf 31.25 / Synch 56.25.
    (274220, "YOU ARE MY HEART", 166692, "Y", 11, 101, "Vita Mia Music", "All Other Contractual Territories", 12.5, 25, 25),
    (274220, "YOU ARE MY HEART", 166692, "Y", 12, 101, "Vita Mia Music", "All Other Contractual Territories", 12.5, 25, 25),
    (274220, "YOU ARE MY HEART", 155812, "Y", 13, 102, "Sony/ATV Tunes LLC", "All Other Contractual Territories", 6.25, 6.25, 6.25),
    (274220, "YOU ARE MY HEART", None, "N", 14, 103, "John Bettis Music", "All Other Contractual Territories", 12.5, 25, 25),
    (274220, "YOU ARE MY HEART", None, "N", None, 104, "Kobalt Music Copyrights SARL", "All Other Contractual Territories", 6.25, 18.75, 18.75),
    (274220, "YOU ARE MY HEART", 166692, "Y", 11, 101, "Vita Mia Music", "UNITED STATES", 12.5, 25, 25),
    (274220, "YOU ARE MY HEART", 166692, "Y", 12, 101, "Vita Mia Music", "UNITED STATES", 12.5, 25, 25),
    (274220, "YOU ARE MY HEART", 155812, "Y", 13, 102, "Sony/ATV Tunes LLC", "UNITED STATES", 6.25, 5, 5),
]
for (sid, tit, cid, ctrl, wid, pid, pub, grp, p, m, s) in extra_mv:
    con.execute("insert into dp_song_metadata.song_share_detail_mv values (?,?,?,?,?,?,?,?,?,?,?,?)",
                (sid, cid, f"C{cid}", ctrl, wid, pid, pub, grp, p, m, s, tit))
    con.execute("insert into dp_song_metadata.song_v values (?,?,?,?)", (sid, tit, "2013-10-04 22:04:56", None))
con.executemany("insert into dp_song_metadata.contract_territories values (?,?,?,?,?)", [
    (3000, 300, "C300", "Include: World", None),
    (3001, 301, "C301", "Include: CHILEAN ISLANDS;PERU", None),
    (3002, 302, "C302", "Include: World", None),
    (274220, 166692, "Fabian Lara And Allison Rick", "Include: World", ""),
    (274220, 155812, "Afanasieff, Walter", "Include: World", ""),
])
con.executemany("insert into dp_deal_metadata.contract_v values (?,?,?,?)",
                [(300, "C300", "London", None), (301, "C301", "London", None), (302, "C302", "London", None), (166692, "Fabian Lara And Allison Rick", "United States", None), (155812, "Afanasieff, Walter", "United States", None)])
# Linea que cubre Chile en una obra sin participaciones: no debe salir
con.execute("insert into dp_song_metadata.contract_territories values (3999, 399, 'C399', 'Include: CHILE', NULL)")
# Tabla de obras para la v8 (todas, incluidas las extra)
ids = [s[0] for s in songs] + [3000, 3001, 3002, 274220]
con.executemany("insert into public.rankingdigital_song_id values (?)", [(i,) for i in ids])

def _duck(stmt_sql):
    tree = sqlglot.parse_one(stmt_sql, read="redshift")
    for node in tree.find_all(sqlglot.exp.RegexpReplace):
        node.set("modifiers", sqlglot.exp.Literal.string("g"))
    duck = tree.sql(dialect="duckdb")
    duck = re.sub(r"SUBSTRING\(([\w.]+), 1, ([\w.]*pos_excl)\)", r"SUBSTRING(\1, 1, CAST(\2 AS BIGINT))", duck)
    duck = re.sub(r"SUBSTRING\(([\w.]+), ([\w.]*pos_excl)\)", r"SUBSTRING(\1, CAST(\2 AS BIGINT))", duck)
    return duck

def correr(sql):
    cur = con.execute(_duck(sql))
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]

v8 = correr((CWR / "reporte_cwr_x_territorio_v8.sql").read_text(encoding="utf-8").rstrip().rstrip(";"))
texto = (AQUI / "obras_controladas_pais_v1.sql").read_text(encoding="utf-8")
res = correr(texto.rstrip().rstrip(";"))
cuerpo_unload = (AQUI / "unload_obras_controladas_pais_v1.sql").read_text(encoding="utf-8") \
    .split("UNLOAD ('\n", 1)[1].rsplit("\n')\nTO", 1)[0].replace("''", "'")
res_unload = correr(cuerpo_unload)

fallas = []
def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FALLA") + " " + nombre + ("" if cond else f"  -> {extra}"))
    if not cond: fallas.append(nombre)

R = {r["song_id"]: r for r in res}
def num(x):
    try: return round(float(x), 2)
    except (TypeError, ValueError): return None

# v8 en CHILE: controlada = porcentaje numerico > 0 en algun derecho
v8_cl = {r["song_id"]: r for r in v8 if r["pais"] == "CHILE"}
v8_ctrl = {i for i, r in v8_cl.items()
           if any((num(r[c]) or 0) > 0 for c in ("performance_pc_total", "mechanical_pc_total", "sync_pc_total"))}
esperadas_distintas = {600: "sin contrato asociado (v8 lo da por cubierto)",
                       800: "texto de territorio prestado de otra obra",
                       700: "NOP (esta version no lee song_v)"}
mias = set(R)
check("mismas obras que la v8 salvo las diferencias documentadas",
      (mias ^ v8_ctrl) <= set(esperadas_distintas), sorted(mias ^ v8_ctrl))
check("NOP 700 sale (tiene linea vigente) y 600/800 no salen", 700 in mias and 600 not in mias and 800 not in mias, sorted(mias))
for i in sorted(mias & v8_ctrl):
    a = (num(R[i]["performance_pc_total"]), num(R[i]["mechanical_pc_total"]), num(R[i]["sync_pc_total"]))
    b = tuple(num(v8_cl[i][c]) or 0.0 for c in ("performance_pc_total", "mechanical_pc_total", "sync_pc_total"))
    if a != b:
        check(f"obra {i}: mismos porcentajes que la v8", False, (a, b))
check("porcentajes iguales a la v8 en todas las obras comunes", not [f for f in fallas if "mismos porcentajes" in f])

b = R.get(2701309, {})
check("Baba O'Riley: 50/100/100 con Westminster", (num(b.get("performance_pc_total")), num(b.get("mechanical_pc_total"))) == (50, 100)
      and b.get("publishers") == "WESTMINSTER MUSIC LTD", b)
check("Baba O'Riley: lineas que cubren Chile = 1146885 y 1551025",
      "1146885" in (b.get("lineas_que_cubren_el_pais") or "") and "1551025" in b["lineas_que_cubren_el_pais"]
      and "1525818" not in b["lineas_que_cubren_el_pais"] and b.get("cantidad_lineas") == 2, b.get("lineas_que_cubren_el_pais"))
check("Baba O'Riley: alerta de otra linea, grupo mundial, ISWC preferido",
      "OTRA LINEA" in (b.get("alertas") or "") and b.get("como_se_eligio_grupo") == "Grupo mundial" and b.get("iswc") == "T-010.237.425-3", b)
check("pais = CHILE", all(r["pais"] == "CHILE" for r in res))
check("grupo propio de Chile gana (70)", num(R.get(3000, {}).get("performance_pc_total")) == 70 and R[3000]["como_se_eligio_grupo"] == "Grupo nombra al país", R.get(3000))
y = R.get(274220, {})
check("274220 (All Other Contractual Territories + Include: World) sale con 31.25 / 56.25 / 56.25",
      (num(y.get("performance_pc_total")), num(y.get("mechanical_pc_total")), num(y.get("sync_pc_total"))) == (31.25, 56.25, 56.25)
      and y.get("grupo_ip_usado") == "ALL OTHER CONTRACTUAL TERRITORIES", y)
check("CHILEAN ISLANDS no cubre Chile", 3001 not in R)
check("grupo WORLD EX CHILE no cuenta", 3002 not in R)
check("linea sin participaciones no sale", 3999 not in R)
check("Te Encontre (lista explicita con CHILE) sale", 300 in R)
check("Region incluida (Latin America ex Uruguay) sale", 1300 in R)
check("Region excluida (World ex South America) no sale", 1301 not in R)
check("vencimientos: MIXTO / TODOS VENCIDOS / VIGENTE",
      (R[500]["estado_contrato"], R[501]["estado_contrato"], R[502]["estado_contrato"]) == ("MIXTO (alguno vencido)", "TODOS VENCIDOS", "VIGENTE"),
      (R[500]["estado_contrato"], R[501]["estado_contrato"], R[502]["estado_contrato"]))
check("duplicados de contract_territories no duplican lineas", R[1500]["cantidad_lineas"] == 1, R[1500]["cantidad_lineas"])
check("UNLOAD da exactamente lo mismo", res_unload == res)
# Tandas: la union de los rangos (sin superponerse) da exactamente el resultado completo
sys.path.insert(0, str(AQUI / "tools"))
import generar_unload as gu
cuerpo = gu.cuerpo_sin_comentarios(texto)
por_tandas = []
for desde, hasta in [(0, 999), (1000, 274219), (274220, 2701308), (2701309, 999999999999)]:
    por_tandas += correr(gu.cuerpo_tanda(cuerpo, desde, hasta))
check("tandas: la union da lo mismo que la corrida completa", sorted(por_tandas, key=lambda r: r["song_id"]) == res,
      (len(por_tandas), len(res)))
bloques = (AQUI / "unload_obras_controladas_pais_tandas.sql").read_text(encoding="utf-8").split("UNLOAD ('\n")[1:]
check("archivo de tandas: un UNLOAD por rango de rangos_tandas.txt", len(bloques) == len(gu.leer_rangos()), len(bloques))
primera = bloques[0].rsplit("\n')\nTO", 1)[0].replace("''", "'")
check("archivo de tandas: la tanda 1 corre", isinstance(correr(primera), list))
check("orden por obra", [r["song_id"] for r in res] == sorted(r["song_id"] for r in res))
print("\nTodo OK" if not fallas else f"\n{len(fallas)} fallas")
sys.exit(1 if fallas else 0)
