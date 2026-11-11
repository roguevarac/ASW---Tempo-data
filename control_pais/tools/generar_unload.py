"""
Genera unload_obras_controladas_pais_v1.sql a partir de obras_controladas_pais_v1.sql:
saca los comentarios, quita el ';' final y duplica las comillas simples para meter
la query dentro de UNLOAD ('...'). Verifica que, des-escapado, el texto vuelva a ser
exactamente la query.

También genera unload_obras_controladas_pais_tandas.sql: un UNLOAD por cada rango de
rangos_tandas.txt (un archivo por tanda en S3), para correr el catálogo completo por partes.

Uso: python3 control_pais/tools/generar_unload.py
"""
import re, pathlib, sqlglot

ROOT = pathlib.Path(__file__).resolve().parent.parent
FUENTE = ROOT / "obras_controladas_pais_v1.sql"
DESTINO = ROOT / "unload_obras_controladas_pais_v1.sql"
DESTINO_TANDAS = ROOT / "unload_obras_controladas_pais_tandas.sql"
DESTINO_PROC = ROOT / "procedimiento_obras_controladas_pais.sql"
TABLA = "public.obras_controladas_pais_resultado"
TABLA_LOG = "public.obras_controladas_pais_log"
COLUMNAS = [
    ("song_id", "BIGINT"), ("song_title_tx", "VARCHAR(2000)"), ("iswc", "VARCHAR(100)"), ("pais", "VARCHAR(100)"),
    ("performance_pc_total", "NUMERIC(10,2)"), ("mechanical_pc_total", "NUMERIC(10,2)"), ("sync_pc_total", "NUMERIC(10,2)"),
    ("publishers", "VARCHAR(65535)"), ("cantidad_publishers", "BIGINT"), ("contratos_asociados", "VARCHAR(65535)"),
    ("grupo_ip_usado", "VARCHAR(2000)"), ("como_se_eligio_grupo", "VARCHAR(100)"),
    ("lineas_que_cubren_el_pais", "VARCHAR(65535)"), ("cantidad_lineas", "BIGINT"),
    ("contrato_venc_mas_proximo", "TIMESTAMP"), ("contrato_venc_mas_lejano", "TIMESTAMP"),
    ("estado_contrato", "VARCHAR(100)"), ("alertas", "VARCHAR(4000)"),
]
RANGOS = ROOT / "rangos_tandas.txt"
TABLA_CLAVES = "public.control_pais_claves"
MARCA_PAIS = "pais = 'CHILE'"   # el país de ejemplo en las queries; en el procedimiento es el parámetro p_pais
# Formas de escritura (P) y regiones que contienen al país (R): las mismas listas que alias_pais y regiones
# de reporte_cwr/reporte_cwr_x_territorio_v8.sql. La clave del diccionario es el nombre del país (columna pais y
# parámetro del CALL).
# PAÍS NUEVO: agregarlo acá y regenerar (o insertar sus filas en public.control_pais_claves).
CLAVES = {
    "ARGENTINA": (["ARGENTINA"], ["LATIN AMERICA", "SOUTH AMERICA"]),
    "CHILE": (["CHILE"], ["LATIN AMERICA", "SOUTH AMERICA"]),
    "PERU": (["PERU"], ["LATIN AMERICA", "SOUTH AMERICA"]),
    "URUGUAY": (["URUGUAY"], ["LATIN AMERICA", "SOUTH AMERICA"]),
    "COLOMBIA": (["COLOMBIA"], ["LATIN AMERICA", "SOUTH AMERICA"]),
    # Brasil: en los textos de Tempo aparece como BRAZIL (no estaba en la v8; agregado el 11/11/2026)
    "BRASIL": (["BRAZIL", "BRASIL"], ["LATIN AMERICA", "SOUTH AMERICA"]),
    "UNITED STATES": (["UNITED STATES", "UNITED STATES OF AMERICA", "USA", "US", "U S A", "U S"],
                      ["NORTH AMERICA", "US AND CANADA", "US & CANADA", "USA AND CANADA", "USA & CANADA"]),
}

def filas_claves():
    filas = []
    for pais, (alias, regiones) in CLAVES.items():
        n = 0
        for a in alias:
            n += 1; filas.append((pais, "P", a, n))
        for r in regiones:
            n += 1; filas.append((pais, "R", r, n))
    return filas

def sql_claves():
    valores = ",\n".join(f"    ('{p}', '{t}', '{c}', {o})" for p, t, c, o in filas_claves())
    return f"""CREATE TABLE IF NOT EXISTS {TABLA_CLAVES} (
    pais   VARCHAR(100),
    tipo   VARCHAR(1),
    clave  VARCHAR(200),
    orden  INTEGER
);
DELETE FROM {TABLA_CLAVES};
INSERT INTO {TABLA_CLAVES} (pais, tipo, clave, orden) VALUES
{valores};
"""
RANGO_TODO = "BETWEEN 0 AND 999999999999"
PREFIJO_S3 = "s3://dw-export-prod/7000042560/obras_controladas_pais_"

ENCABEZADO = """-- =====================================================================
-- UNLOAD: obras controladas en un país (todo el catálogo) a S3
--
-- Es la misma query que obras_controladas_pais_v1.sql dentro de un UNLOAD.
-- Adentro del texto las comillas simples van duplicadas ('' en vez de ').
-- No editar la query acá: cambiarla en obras_controladas_pais_v1.sql y
-- regenerar este archivo con:  python3 control_pais/tools/generar_unload.py
--
-- País: bloque "claves" de la query (hoy CHILE).
--
-- Datos según "Redshift Query Editor Instructions for Access":
--   conexión self-service-prod-wg, base selfsvcdb
--   destino  s3://dw-export-prod/<GID>/<archivo>   (GID 7000042560)
--   rol      arn:aws:iam::991042281579:role/DataWarehouse/RedShift-S3-Unload
--
-- Resultado: s3://dw-export-prod/7000042560/obras_controladas_pais_000.csv
--   CSV con encabezado, un solo archivo ordenado por obra (si pasa de 1 GB se
--   parte en _001, _002...). Para descargarlo: consola AWS > S3 > bucket
--   dw-export-prod > carpeta 7000042560 > Download. El archivo se borra solo a
--   los 7 días. Correrlo de nuevo lo pisa.
-- =====================================================================
"""

ENCABEZADO_TANDAS = """-- =====================================================================
-- UNLOAD POR TANDAS: obras controladas en un país (todo el catálogo)
--
-- La misma query que obras_controladas_pais_v1.sql, una vez por cada rango de
-- Tempo ID de rangos_tandas.txt ({n} tandas). Cada tanda deja su propio archivo:
--   s3://dw-export-prod/7000042560/obras_controladas_pais_tNN_000.csv
-- Entre todas cubren el catálogo completo sin repetir obras.
--
-- Cómo correrlo: seleccionar un bloque UNLOAD (de "UNLOAD (" hasta su ";") y
-- ejecutar solo ese; o "Run all" para todas en orden. Si una tanda falla, las
-- demás ya quedaron en S3: partir ese rango en rangos_tandas.txt y regenerar.
-- No editar acá: python3 control_pais/tools/generar_unload.py
-- Los archivos duran 7 días en S3; correr una tanda de nuevo la pisa.
-- =====================================================================
"""

def cuerpo_sin_comentarios(sql):
    cuerpo = sql[sql.index("WITH\n"):].rstrip().rstrip(";").rstrip()
    cuerpo = "\n".join(l for l in cuerpo.split("\n") if not l.strip().startswith("--"))
    cuerpo = re.sub(r"\s+--[^\n']*$", "", cuerpo, flags=re.M)
    if "--" in cuerpo:
        raise SystemExit("Quedó un comentario '--' dentro de la query; revisar antes de generar el UNLOAD")
    return cuerpo

def unload(cuerpo, prefijo):
    texto = ("UNLOAD ('\n" + cuerpo.replace("'", "''") + "\n')\n"
             f"TO '{prefijo}'\n"
             "IAM_ROLE 'arn:aws:iam::991042281579:role/DataWarehouse/RedShift-S3-Unload'\n"
             "FORMAT AS CSV\nHEADER\nEXTENSION 'csv'\nPARALLEL OFF\nMAXFILESIZE 1 GB\nALLOWOVERWRITE;\n")
    adentro = texto.split("UNLOAD ('\n", 1)[1].rsplit("\n')\nTO", 1)[0]
    assert adentro.replace("''", "'") == cuerpo
    return texto

def leer_rangos():
    rangos = []
    for linea in RANGOS.read_text(encoding="utf-8").splitlines():
        linea = linea.strip()
        if not linea or linea.startswith("#"):
            continue
        desde, hasta = (int(x) for x in linea.split())
        assert desde <= hasta, linea
        if rangos:
            assert desde == rangos[-1][1] + 1, f"los rangos deben ser contiguos: {linea}"
        rangos.append((desde, hasta))
    assert rangos and rangos[0][0] == 0, "el primer rango tiene que empezar en 0"
    return rangos

def cuerpo_tanda(cuerpo, desde, hasta):
    assert cuerpo.count(RANGO_TODO) == 4, "se esperan 4 filtros de rango (TANDA) en la query"
    return cuerpo.replace(RANGO_TODO, f"BETWEEN {desde} AND {hasta}")

def cuerpo_sin_orden(cuerpo):
    fin = cuerpo.rstrip()
    m = re.search(r"\nORDER BY [^\n]*$", fin)
    assert m, "la query tiene que terminar en ORDER BY ..."
    return fin[: m.start()].rstrip()

def texto_dinamico(cuerpo):
    """La query como literal de plpgsql: comillas duplicadas y el rango tomado de las variables."""
    q = cuerpo_sin_orden(cuerpo).replace("'", "''")
    assert q.count(RANGO_TODO) >= 1
    marca = MARCA_PAIS.replace("'", "''")
    assert q.count(marca) >= 1, "falta el filtro de país en la query"
    q = q.replace(marca, "pais = ' || QUOTE_LITERAL(p_pais) || '")
    assert "CHILE" not in q, "quedó un país escrito en la query del procedimiento"
    return q.replace(RANGO_TODO, "BETWEEN ' || CAST(v_desde AS VARCHAR(20)) || ' AND ' || CAST(v_hasta AS VARCHAR(20)) || '")

def procedimiento(cuerpo, sp="public.sp_obras_controladas_pais", tabla=TABLA, tabla_log=TABLA_LOG,
                  columnas=None, titulo="obras controladas en un país (todo el catálogo, por tandas)",
                  fuente="obras_controladas_pais_v1.sql", prefijo="obras_controladas_pais_",
                  previo_texto="", tope_sql=None):
    columnas = columnas or COLUMNAS
    cols = ",\n".join(f"    {c} {t}" for c, t in columnas)
    lista = ", ".join(c for c, _ in columnas)
    dinamico = texto_dinamico(cuerpo)
    tope_sql = tope_sql or "SELECT CAST(MAX(song_id) AS BIGINT) INTO v_max FROM dp_song_metadata.contract_territories;"
    paises = ", ".join(f"'{p}'" for p in CLAVES)
    return f"""-- =====================================================================
-- PROCEDIMIENTO: {titulo}
--
-- No editar acá: se genera desde {fuente} con
--   python3 control_pais/tools/generar_unload.py
{previo_texto}--
-- PASO 1 (una vez, y cada vez que te pase una versión nueva): ejecutar TODO este
--   archivo. Crea o actualiza {TABLA_CLAVES} (formas de escritura de
--   cada país), {tabla} (resultado), {tabla_log}
--   (avance) y el procedimiento. NO borra resultados ya guardados.
--   Países disponibles: {paises}.
-- PASO 2: correr, con el país entre comillas:
--     CALL {sp}('CHILE', 500000, 0);
--   (tandas de 500.000 Tempo ID; desde 0 = borra solo lo de ese país y empieza
--   de cero). Cada país queda guardado aparte (columna pais).
--   Avance:  SELECT * FROM {tabla_log} WHERE pais = 'CHILE' ORDER BY tanda;
-- PASO 3: el archivo de ese país:
--     UNLOAD ('SELECT * FROM {tabla} WHERE pais = ''CHILE'' ORDER BY song_id')
--     TO 's3://dw-export-prod/7000042560/{prefijo}chile_'
--     IAM_ROLE 'arn:aws:iam::991042281579:role/DataWarehouse/RedShift-S3-Unload'
--     FORMAT AS CSV HEADER EXTENSION 'csv' PARALLEL OFF MAXFILESIZE 1 GB ALLOWOVERWRITE;
--
-- Si se corta: lo ya confirmado queda guardado. Ver en el log el "hasta" de la
-- última tanda y seguir desde el siguiente Tempo ID, sin borrar:
--     CALL {sp}('CHILE', 500000, <hasta + 1>);
-- Si una tanda tarda demasiado, usar un tamaño menor (ej. 250000).
-- =====================================================================
{sql_claves()}
CREATE TABLE IF NOT EXISTS {tabla} (
{cols}
);

-- El log se rehace (ahora lleva el país); el resultado no se toca.
DROP TABLE IF EXISTS {tabla_log};
CREATE TABLE {tabla_log} (
    pais      VARCHAR(100),
    tanda     INTEGER,
    desde     BIGINT,
    hasta     BIGINT,
    filas     BIGINT,
    inicio    VARCHAR(60),
    fin       VARCHAR(60)
);

-- Versión anterior (sin país), si estaba creada.
DROP PROCEDURE IF EXISTS {sp}(BIGINT, BIGINT);

CREATE OR REPLACE PROCEDURE {sp}(p_pais VARCHAR(100), p_tamano BIGINT, p_desde BIGINT)
AS $$
DECLARE
    v_max    BIGINT;
    v_desde  BIGINT;
    v_hasta  BIGINT;
    v_filas  BIGINT;
    v_tanda  INTEGER;
    v_claves INTEGER;
    v_inicio VARCHAR(60);
BEGIN
    IF p_tamano IS NULL OR p_tamano < 1 THEN
        RAISE EXCEPTION 'El tamaño de tanda tiene que ser mayor que 0';
    END IF;
    SELECT COUNT(*) INTO v_claves FROM {TABLA_CLAVES} WHERE pais = p_pais;
    IF v_claves = 0 THEN
        RAISE EXCEPTION 'País % sin formas de escritura en {TABLA_CLAVES}', p_pais;
    END IF;
    IF p_desde = 0 THEN
        DELETE FROM {tabla} WHERE pais = p_pais;
        DELETE FROM {tabla_log} WHERE pais = p_pais;
        COMMIT;
    END IF;
    {tope_sql}
    SELECT COALESCE(MAX(tanda), 0) INTO v_tanda FROM {tabla_log} WHERE pais = p_pais;
    v_desde := p_desde;
    WHILE v_desde <= v_max LOOP
        v_hasta  := v_desde + p_tamano - 1;
        v_tanda  := v_tanda + 1;
        v_inicio := TIMEOFDAY();
        EXECUTE 'INSERT INTO {tabla} ({lista})
{dinamico}';
        GET DIAGNOSTICS v_filas := ROW_COUNT;
        INSERT INTO {tabla_log} VALUES (p_pais, v_tanda, v_desde, v_hasta, v_filas, v_inicio, TIMEOFDAY());
        COMMIT;
        RAISE INFO '% - tanda %: Tempo ID % a %: % filas', p_pais, v_tanda, v_desde, v_hasta, v_filas;
        v_desde := v_hasta + 1;
    END LOOP;
    RAISE INFO '% listo. Máximo Tempo ID recorrido: %', p_pais, v_max;
END;
$$ LANGUAGE plpgsql;
"""

# ---------------------------------------------------------------------------
# Reporte CWR v8 (control por país) para un país, sobre las obras de la tabla de
# resultado, por tandas. Se genera desde reporte_cwr/reporte_cwr_x_territorio_v8.sql
# para que la lógica sea exactamente la misma.
FUENTE_CWR = ROOT.parent / "reporte_cwr" / "reporte_cwr_x_territorio_v8.sql"
DESTINO_CWR = ROOT / "reporte_cwr_pais_v1.sql"
DESTINO_PROC_CWR = ROOT / "procedimiento_reporte_cwr_pais.sql"
TABLA_CWR = "public.reporte_cwr_pais_resultado"
TABLA_CWR_LOG = "public.reporte_cwr_pais_log"
COLUMNAS_CWR = [
    ("song_id", "BIGINT"), ("song_title_tx", "VARCHAR(2000)"), ("iswc", "VARCHAR(100)"), ("pais", "VARCHAR(100)"),
    ("performance_pc_total", "VARCHAR(20)"), ("mechanical_pc_total", "VARCHAR(20)"), ("sync_pc_total", "VARCHAR(20)"),
    ("publishers", "VARCHAR(65535)"), ("cantidad_publishers", "BIGINT"), ("contratos_del_pais", "VARCHAR(65535)"),
    ("cantidad_contratos_del_pais", "BIGINT"), ("todos_los_contratos", "VARCHAR(65535)"),
    ("cantidad_contratos_obra", "BIGINT"), ("originating_office", "VARCHAR(65535)"),
    ("song_tempo_create_date", "TIMESTAMP"), ("song_not_ours_dt", "TIMESTAMP"), ("estado_obra", "VARCHAR(50)"),
    ("contrato_venc_mas_proximo", "TIMESTAMP"), ("contrato_venc_mas_lejano", "TIMESTAMP"),
    ("estado_contrato", "VARCHAR(50)"), ("grupo_ip_usado", "VARCHAR(2000)"), ("como_se_eligio_grupo", "VARCHAR(100)"),
    ("regla_territorial", "VARCHAR(65535)"), ("grupos_ip_de_la_obra", "VARCHAR(65535)"),
    ("lineas_de_control_obra", "VARCHAR(65535)"), ("lineas_que_cubren_el_pais", "VARCHAR(65535)"),
    ("texto_territorio_contratos", "VARCHAR(65535)"), ("alertas", "VARCHAR(4000)"),
]

def cuerpo_cwr():
    cuerpo = cuerpo_sin_comentarios(FUENTE_CWR.read_text(encoding="utf-8"))
    def rep(a, b):
        nonlocal cuerpo
        assert cuerpo.count(a) == 1, a
        cuerpo = cuerpo.replace(a, b)
    # obras: las de la tabla de resultado del procedimiento de control por país, por rango
    rep("FROM public.rankingdigital_song_id t\n    WHERE t.song_id IS NOT NULL",
        f"FROM {TABLA} t\n    WHERE t.{MARCA_PAIS} AND t.song_id {RANGO_TODO}")
    def bloque(nombre, nuevo):
        nonlocal cuerpo
        i = cuerpo.index(nombre + " AS (")
        j = cuerpo.index("\n),", i) + 3
        cuerpo = cuerpo[:i] + nombre + " AS (\n" + nuevo + "\n)," + cuerpo[j:]
    # un solo país; formas de escritura y regiones desde la tabla de claves (misma lista que la v8)
    bloque("paises", f"    SELECT c.pais FROM {TABLA_CLAVES} c WHERE c.{MARCA_PAIS} AND c.orden = 1")
    bloque("alias_pais", f"    SELECT c.pais, c.clave AS alias FROM {TABLA_CLAVES} c WHERE c.tipo = 'P'")
    bloque("regiones", f"    SELECT c.clave AS region, c.pais FROM {TABLA_CLAVES} c WHERE c.tipo = 'R'")
    # el rango también en cada lectura filtrada por las obras (mismo resultado; ayuda a Redshift a saltear bloques)
    cuerpo, n = re.subn(r"WHERE (\w+\.)?(song_id|tempo_song_id) IN \(SELECT song_id FROM ids\)",
                        lambda m: f"WHERE {m.group(1) or ''}{m.group(2)} {RANGO_TODO} AND {m.group(1) or ''}{m.group(2)} IN (SELECT song_id FROM ids)",
                        cuerpo)
    assert n >= 5, n
    cuerpo = re.sub(r"\bAND song_id IN \(SELECT song_id FROM ids\) AND associated_contract_id",
                    f"AND song_id IN (SELECT song_id FROM ids) AND associated_contract_id", cuerpo)
    sqlglot.parse_one(cuerpo, read="redshift")
    return cuerpo

def generar_cwr():
    cuerpo = cuerpo_cwr()
    DESTINO_CWR.write_text(f"""-- =====================================================================
-- REPORTE CWR v8 PARA UN PAÍS (ejemplo: CHILE) sobre las obras de {TABLA}
--
-- Generado desde reporte_cwr/reporte_cwr_x_territorio_v8.sql (misma lógica y
-- mismas columnas, un solo país). No editar a mano:
--   python3 control_pais/tools/generar_unload.py
-- Para el catálogo completo usar procedimiento_reporte_cwr_pais.sql (por tandas).
-- Los filtros "BETWEEN 0 AND 999999999999" son el rango de la tanda.
-- =====================================================================
""" + cuerpo + ";\n", encoding="utf-8")
    DESTINO_PROC_CWR.write_text(procedimiento(
        cuerpo, sp="public.sp_reporte_cwr_pais", tabla=TABLA_CWR, tabla_log=TABLA_CWR_LOG, columnas=COLUMNAS_CWR,
        titulo="reporte CWR v8 para un país, sobre sus obras controladas (por tandas)",
        fuente="reporte_cwr/reporte_cwr_x_territorio_v8.sql", prefijo="reporte_cwr_pais_",
        previo_texto=f"-- ANTES: tiene que estar cargado el país en {TABLA}\n-- (CALL public.sp_obras_controladas_pais('PAIS', 500000, 0)).\n",
        tope_sql=f"SELECT CAST(MAX(song_id) AS BIGINT) INTO v_max FROM {TABLA} WHERE pais = p_pais;"), encoding="utf-8")

def generar():
    cuerpo = cuerpo_sin_comentarios(FUENTE.read_text(encoding="utf-8"))
    sqlglot.parse_one(cuerpo, read="redshift")
    DESTINO.write_text(ENCABEZADO + unload(cuerpo, PREFIJO_S3), encoding="utf-8")
    rangos = leer_rangos()
    partes = [ENCABEZADO_TANDAS.format(n=len(rangos))]
    for i, (desde, hasta) in enumerate(rangos, 1):
        partes.append(f"-- ---- Tanda {i:02d} de {len(rangos):02d}: Tempo ID {desde} a {hasta} "
                      f"-> obras_controladas_pais_t{i:02d}_000.csv\n")
        partes.append(unload(cuerpo_tanda(cuerpo, desde, hasta), f"{PREFIJO_S3}t{i:02d}_") + "\n")
    DESTINO_TANDAS.write_text("".join(partes), encoding="utf-8")
    DESTINO_PROC.write_text(procedimiento(cuerpo), encoding="utf-8")
    generar_cwr()
    return cuerpo

if __name__ == "__main__":
    generar()
    print("OK", DESTINO)
    print("OK", DESTINO_TANDAS)
    print("OK", DESTINO_PROC)
    print("OK", DESTINO_CWR)
    print("OK", DESTINO_PROC_CWR)
