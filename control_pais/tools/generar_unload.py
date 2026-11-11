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
    return cuerpo

if __name__ == "__main__":
    generar()
    print("OK", DESTINO)
    print("OK", DESTINO_TANDAS)
