"""
Prueba split_cliente_v1.sql con DuckDB (transpilado desde Redshift con sqlglot).
Caso basado en You Are My Heart 274220 (captura de Tempo): dos territorios del split,
un contrato del cliente vencido, ISWC preferido / sin preferido, obra sin split.
Uso:  python3 split_cliente/tests/test_split_cliente.py
"""
import pathlib, sys
import duckdb, sqlglot

SQL = pathlib.Path(__file__).resolve().parent.parent / "split_cliente_v1.sql"
CLIENTE = 1738984
con = duckdb.connect()
for esq in ("dp_song_metadata", "dp_deal_metadata"):
    con.execute(f"create schema {esq}")
con.execute("""create table dp_deal_metadata.client_contract_song_v(client_id bigint, client_name varchar, contract_id bigint,
    contract_nm varchar, song_id bigint, song_sequence_id int, song_title_tx varchar, active_ind varchar)""")
con.execute("create table dp_deal_metadata.contract_v(contract_id bigint, contract_nm varchar, contract_expiration_dt timestamp)")
con.execute("create table dp_song_metadata.song_v(song_id bigint, song_title_tx varchar, song_not_ours_dt date)")
con.execute("""create table dp_song_metadata.identifiers_iswc_v(tempo_song_id bigint, ident_iswc_cd varchar,
    preferred_indicator varchar, conflict_indicator varchar)""")
con.execute("create table dp_song_metadata.contract_territories(song_id bigint, contract_id bigint, contract_nm varchar, inclusions varchar, exclusions varchar)")
con.execute("""create table dp_song_metadata.song_share_detail_mv(song_id bigint, song_title_tx varchar, song_ip_territory_nm varchar,
    writer_id bigint, writer_nm varchar, writer_capacity_type_cd varchar, writer_contribution_pc double,
    writer_mechanical_pc double, writer_performance_pc double, writer_sync_pc double,
    publisher_id bigint, publisher_name_tx varchar, publisher_capacity_type_cd varchar, smp_controlled_ind varchar,
    publisher_control_pc double, publisher_mechanical_pc double, publisher_performance_pc double, publisher_sync_pc double,
    associated_contract_id bigint, associated_contract_nm varchar)""")

con.executemany("insert into dp_deal_metadata.client_contract_song_v values (?,?,?,?,?,0,?,?)", [
    (CLIENTE, "CLIENTE X", 166692, "Fabian Lara And Allison Rick", 274220, "You Are My Heart", "Y"),
    (CLIENTE, "CLIENTE X", 155812, "Afanasieff, Walter", 274220, "You Are My Heart", "Y"),
    (CLIENTE, "CLIENTE X", 166692, "Fabian Lara And Allison Rick", 900, "SIN SPLIT", "N"),
    (999, "OTRO CLIENTE", 777, "Otro", 5000, "OBRA DE OTRO", "Y"),
])
con.executemany("insert into dp_deal_metadata.contract_v values (?,?,?)", [
    (166692, "Fabian Lara And Allison Rick", None), (155812, "Afanasieff, Walter", "2013-08-13"), (777, "Otro", None)])
con.executemany("insert into dp_song_metadata.song_v values (?,?,?)", [
    (274220, "You Are My Heart", None), (900, "SIN SPLIT", "2001-01-01"), (5000, "OBRA DE OTRO", None)])
con.executemany("insert into dp_song_metadata.identifiers_iswc_v values (?,?,?,?)", [
    (274220, "T9099014901", "Yes", "No"), (274220, "T0000000001", "No", "No"), (274220, "T9099014901", "Yes", "No"),
    (900, "T5000000002", "No", "Yes"), (900, "T5000000003", "No", "No")])
con.executemany("insert into dp_song_metadata.contract_territories values (?,?,?,?,?)", [
    (274220, 166692, "Fabian Lara And Allison Rick", "Include: World", ""),
    (274220, 155812, "Afanasieff, Walter", "Include: World", "")])
rows = []
def s(grp, wid, wnm, cap, contrib, pid, pub, pcap, ctrl, own, mech, perf, sync, cid, cnm):
    rows.append((274220, "You Are My Heart", grp, wid, wnm, cap, contrib, 0, 12.5, 0, pid, pub, pcap, ctrl, own, mech, perf, sync, cid, cnm))
for grp, sony in (("All Other Contractual Territories", 6.25), ("UNITED STATES", 5.0)):
    s(grp, 11, "Lara Fabian", "CA", 25, 101, "Vita Mia Music", "OP", "Y", 25, 25, 12.5, 25, 166692, "Fabian Lara And Allison Rick")
    s(grp, 12, "Rick Allison", "CA", 25, 101, "Vita Mia Music", "OP", "Y", 25, 25, 12.5, 25, 166692, "Fabian Lara And Allison Rick")
    s(grp, 13, "Walter N Afanasieff", "CA", 25, 102, "Sony/ATV Tunes LLC", "OP", "Y", sony, sony, 6.25, sony, 155812, "Afanasieff, Walter")
    s(grp, 14, "John Bettis", "CA", 25, 103, "John Bettis Music", "OP", "N", 25, 25, 12.5, 25, None, None)
rows.append((5000, "OBRA DE OTRO", "World", 1, "X", "CA", 100, 0, 0, 0, 1, "P", "OP", "Y", 100, 100, 100, 100, 777, "Otro"))
con.executemany("insert into dp_song_metadata.song_share_detail_mv values (" + ",".join("?" * 20) + ")", rows)

texto = SQL.read_text(encoding="utf-8")
assert texto.count("CAST(1738984 AS BIGINT)") == 1
cur = con.execute(sqlglot.parse_one(texto, read="redshift").sql(dialect="duckdb"))
cols = [d[0] for d in cur.description]
res = [dict(zip(cols, r)) for r in cur.fetchall()]

fallas = 0
def check(nombre, cond, extra=""):
    global fallas
    print(("OK   " if cond else "FALLA") + " " + nombre + ("" if cond else f"  -> {extra}"))
    fallas += 0 if cond else 1

y = [r for r in res if r["song_id"] == 274220]
check("solo obras del cliente (no la 5000)", {r["song_id"] for r in res} == {274220, 900}, {r["song_id"] for r in res})
check("274220: 8 filas de split (2 territorios x 4 writers), sin duplicar por los 2 contratos del cliente", len(y) == 8, len(y))
check("territorios del split", sorted({r["territorio_split"] for r in y}) == ["All Other Contractual Territories", "UNITED STATES"])
a = [r for r in y if r["territorio_split"] == "All Other Contractual Territories"]
check("total controlado del territorio = Publisher Controlled de Tempo (31.25 / 56.25 / 56.25)",
      all((float(r["smp_controlado_perf_territorio"]), float(r["smp_controlado_mech_territorio"]), float(r["smp_controlado_sync_territorio"]))
          == (31.25, 56.25, 56.25) for r in a), a[0])
u = [r for r in y if r["territorio_split"] == "UNITED STATES"]
check("US: 55 de mech (Sony/ATV 5)", all(float(r["smp_controlado_mech_territorio"]) == 55 for r in u))
check("ISWC: el preferido (Yes), sin repetir; cuenta y otros", (y[0]["iswc"], y[0]["iswc_preferido"], y[0]["cantidad_iswc"], y[0]["otros_iswc"])
      == ("T9099014901", "Yes", 2, "T0000000001"), (y[0]["iswc"], y[0]["iswc_preferido"], y[0]["cantidad_iswc"], y[0]["otros_iswc"]))
check("contratos del cliente con vencimiento y estado MIXTO",
      y[0]["contratos_cliente"] == "155812 - Afanasieff, Walter [VENCIDO 2013-08-13] | 166692 - Fabian Lara And Allison Rick [sin venc.]"
      and y[0]["estado_contratos_cliente"] == "MIXTO (alguno vencido)", (y[0]["contratos_cliente"], y[0]["estado_contratos_cliente"]))
sony = [r for r in y if r["publisher"] == "Sony/ATV Tunes LLC"][0]
check("fila Sony/ATV: contrato asociado vencido, del cliente, con su territorio",
      (sony["contrato_asociado_venc"], sony["es_contrato_del_cliente"], sony["territorio_contrato_asociado"], sony["control"])
      == ("VENCIDO 2013-08-13", "Y", "Include: World", "Yes"), sony)
bet = [r for r in y if r["publisher"] == "John Bettis Music"][0]
check("fila sin contrato: control No, sin contrato", bet["control"] == "No" and bet["contrato_asociado"] is None, bet)
n = [r for r in res if r["song_id"] == 900]
check("obra sin split: una fila con aviso, NOP, inactiva, ISWC sin preferido (sin conflicto primero)",
      len(n) == 1 and n[0]["aviso"] and n[0]["estado_obra"] == "VENCIDA (NOP)" and n[0]["activa_en_cliente"] == "N"
      and (n[0]["iswc"], n[0]["iswc_preferido"]) == ("T5000000003", "No"), n)
check("orden por obra", [r["song_id"] for r in res] == sorted(r["song_id"] for r in res))
print("\nTodo OK" if not fallas else f"\n{fallas} fallas")
sys.exit(1 if fallas else 0)
