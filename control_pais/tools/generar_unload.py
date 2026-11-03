"""
Genera unload_obras_controladas_pais_v1.sql a partir de obras_controladas_pais_v1.sql:
saca los comentarios, quita el ';' final y duplica las comillas simples para meter
la query dentro de UNLOAD ('...'). Verifica que, des-escapado, el texto vuelva a ser
exactamente la query.

Uso: python3 control_pais/tools/generar_unload.py
"""
import re, pathlib, sqlglot

ROOT = pathlib.Path(__file__).resolve().parent.parent
FUENTE = ROOT / "obras_controladas_pais_v1.sql"
DESTINO = ROOT / "unload_obras_controladas_pais_v1.sql"
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

def cuerpo_sin_comentarios(sql):
    cuerpo = sql[sql.index("WITH\n"):].rstrip().rstrip(";").rstrip()
    cuerpo = "\n".join(l for l in cuerpo.split("\n") if not l.strip().startswith("--"))
    cuerpo = re.sub(r"\s+--[^\n']*$", "", cuerpo, flags=re.M)
    if "--" in cuerpo:
        raise SystemExit("Quedó un comentario '--' dentro de la query; revisar antes de generar el UNLOAD")
    return cuerpo

def generar():
    cuerpo = cuerpo_sin_comentarios(FUENTE.read_text(encoding="utf-8"))
    sqlglot.parse_one(cuerpo, read="redshift")
    texto = (ENCABEZADO + "UNLOAD ('\n" + cuerpo.replace("'", "''") + "\n')\n"
             f"TO '{PREFIJO_S3}'\n"
             "IAM_ROLE 'arn:aws:iam::991042281579:role/DataWarehouse/RedShift-S3-Unload'\n"
             "FORMAT AS CSV\nHEADER\nEXTENSION 'csv'\nPARALLEL OFF\nMAXFILESIZE 1 GB\nALLOWOVERWRITE;\n")
    adentro = texto.split("UNLOAD ('\n", 1)[1].rsplit("\n')\nTO", 1)[0]
    assert adentro.replace("''", "'") == cuerpo
    DESTINO.write_text(texto, encoding="utf-8")
    return cuerpo

if __name__ == "__main__":
    generar()
    print("OK", DESTINO)
