"""
Genera financials/unload_recaudacion_emmac_smp_latin_v1.sql a partir de la query
(sin comentarios, sin ';', comillas duplicadas dentro de UNLOAD ('...')).
Uso: python3 financials/tools/generar_unload.py
"""
import re, pathlib, sqlglot

ROOT = pathlib.Path(__file__).resolve().parent.parent
FUENTE = ROOT / "recaudacion_emmac_smp_latin_v1.sql"
DESTINO = ROOT / "unload_recaudacion_emmac_smp_latin_v1.sql"

ENCABEZADO = """-- =====================================================================
-- UNLOAD: recaudación EMMAC + SMP Latin de las obras controladas
--
-- Misma query que recaudacion_emmac_smp_latin_v1.sql dentro de un UNLOAD. No
-- editar acá: cambiar la query y regenerar con
--   python3 financials/tools/generar_unload.py
-- Obras: todas las de public.obras_controladas_pais_resultado (todos los países
-- ya corridos). Resultado: s3://dw-export-prod/7000042560/recaudacion_emmac_smp_latin_000.csv
-- (si pasa de 1 GB, _001, _002...). Dura 7 días; correrlo de nuevo lo pisa.
-- =====================================================================
"""

def cuerpo_sin_comentarios(sql):
    cuerpo = sql[sql.index("WITH\n"):].rstrip().rstrip(";").rstrip()
    cuerpo = "\n".join(l for l in cuerpo.split("\n") if not l.strip().startswith("--"))
    cuerpo = re.sub(r"\s+--[^\n']*$", "", cuerpo, flags=re.M)
    if "--" in cuerpo:
        raise SystemExit("Quedó un comentario '--' dentro de la query")
    return cuerpo

def generar():
    cuerpo = cuerpo_sin_comentarios(FUENTE.read_text(encoding="utf-8"))
    sqlglot.parse_one(cuerpo, read="redshift")
    texto = (ENCABEZADO + "UNLOAD ('\n" + cuerpo.replace("'", "''") + "\n')\n"
             "TO 's3://dw-export-prod/7000042560/recaudacion_emmac_smp_latin_'\n"
             "IAM_ROLE 'arn:aws:iam::991042281579:role/DataWarehouse/RedShift-S3-Unload'\n"
             "FORMAT AS CSV\nHEADER\nEXTENSION 'csv'\nPARALLEL OFF\nMAXFILESIZE 1 GB\nALLOWOVERWRITE;\n")
    adentro = texto.split("UNLOAD ('\n", 1)[1].rsplit("\n')\nTO", 1)[0]
    assert adentro.replace("''", "'") == cuerpo
    DESTINO.write_text(texto, encoding="utf-8")

if __name__ == "__main__":
    generar()
    print("OK", DESTINO)
