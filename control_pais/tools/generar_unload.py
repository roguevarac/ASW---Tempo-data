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
    assert fin.endswith("ORDER BY song_id"), "la query tiene que terminar en ORDER BY song_id"
    return fin[: -len("ORDER BY song_id")].rstrip()

def texto_dinamico(cuerpo):
    """La query como literal de plpgsql: comillas duplicadas y el rango tomado de las variables."""
    q = cuerpo_sin_orden(cuerpo).replace("'", "''")
    assert q.count(RANGO_TODO) == 4
    return q.replace(RANGO_TODO, "BETWEEN ' || CAST(v_desde AS VARCHAR(20)) || ' AND ' || CAST(v_hasta AS VARCHAR(20)) || '")

def procedimiento(cuerpo):
    cols = ",\n".join(f"    {c} {t}" for c, t in COLUMNAS)
    lista = ", ".join(c for c, _ in COLUMNAS)
    dinamico = texto_dinamico(cuerpo)
    return f"""-- =====================================================================
-- PROCEDIMIENTO: obras controladas en un país (todo el catálogo, por tandas)
--
-- No editar acá: se genera desde obras_controladas_pais_v1.sql con
--   python3 control_pais/tools/generar_unload.py
-- País: bloque "claves" de esa query (hoy CHILE).
--
-- PASO 1 (una sola vez, y cada vez que cambie la query): ejecutar TODO este
--   archivo. Crea {TABLA} (resultado), {TABLA_LOG}
--   (avance por tanda) y el procedimiento.
-- PASO 2: correr
--     CALL public.sp_obras_controladas_pais(500000, 0);
--   (tanda de 500.000 Tempo ID, desde el 0: vacía el resultado y empieza de cero).
--   Cada tanda se confirma (COMMIT) al terminar y queda anotada en el log.
--   Avance:  SELECT * FROM {TABLA_LOG} ORDER BY tanda;
-- PASO 3: el archivo, un solo CSV:
--     UNLOAD ('SELECT * FROM {TABLA} ORDER BY song_id')
--     TO 's3://dw-export-prod/7000042560/obras_controladas_pais_'
--     IAM_ROLE 'arn:aws:iam::991042281579:role/DataWarehouse/RedShift-S3-Unload'
--     FORMAT AS CSV HEADER EXTENSION 'csv' PARALLEL OFF MAXFILESIZE 1 GB ALLOWOVERWRITE;
--
-- Si se corta: lo ya confirmado queda guardado. Ver en el log el "hasta" de la
-- última tanda y seguir desde el siguiente Tempo ID, sin vaciar:
--     CALL public.sp_obras_controladas_pais(500000, <hasta + 1>);
-- Si una tanda tarda demasiado, usar un tamaño menor (ej. 250000).
-- =====================================================================
CREATE TABLE IF NOT EXISTS {TABLA} (
{cols}
);

CREATE TABLE IF NOT EXISTS {TABLA_LOG} (
    tanda     INTEGER,
    desde     BIGINT,
    hasta     BIGINT,
    obras     BIGINT,
    inicio    VARCHAR(60),
    fin       VARCHAR(60)
);

CREATE OR REPLACE PROCEDURE public.sp_obras_controladas_pais(p_tamano BIGINT, p_desde BIGINT)
AS $$
DECLARE
    v_max    BIGINT;
    v_desde  BIGINT;
    v_hasta  BIGINT;
    v_filas  BIGINT;
    v_tanda  INTEGER;
    v_inicio VARCHAR(60);
BEGIN
    IF p_tamano IS NULL OR p_tamano < 1 THEN
        RAISE EXCEPTION 'El tamaño de tanda tiene que ser mayor que 0';
    END IF;
    IF p_desde = 0 THEN
        TRUNCATE {TABLA};
        TRUNCATE {TABLA_LOG};
    END IF;
    SELECT CAST(MAX(song_id) AS BIGINT) INTO v_max FROM dp_song_metadata.contract_territories;
    SELECT COALESCE(MAX(tanda), 0) INTO v_tanda FROM {TABLA_LOG};
    v_desde := p_desde;
    WHILE v_desde <= v_max LOOP
        v_hasta  := v_desde + p_tamano - 1;
        v_tanda  := v_tanda + 1;
        v_inicio := TIMEOFDAY();
        EXECUTE 'INSERT INTO {TABLA} ({lista})
{dinamico}';
        GET DIAGNOSTICS v_filas := ROW_COUNT;
        INSERT INTO {TABLA_LOG} VALUES (v_tanda, v_desde, v_hasta, v_filas, v_inicio, TIMEOFDAY());
        COMMIT;
        RAISE INFO 'Tanda %: Tempo ID % a %: % obras', v_tanda, v_desde, v_hasta, v_filas;
        v_desde := v_hasta + 1;
    END LOOP;
    RAISE INFO 'Listo. Máximo Tempo ID con línea de control: %', v_max;
END;
$$ LANGUAGE plpgsql;
"""

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
    return cuerpo

if __name__ == "__main__":
    generar()
    print("OK", DESTINO)
    print("OK", DESTINO_TANDAS)
    print("OK", DESTINO_PROC)
