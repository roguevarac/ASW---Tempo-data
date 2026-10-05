"""
Genera unload_reporte_cwr_v8.sql a partir de reporte_cwr_x_territorio_v8.sql:
saca los comentarios, quita el ';' final y duplica las comillas simples para meter
la query dentro de UNLOAD ('...'). Verifica que, des-escapado, el texto vuelva a ser
exactamente la query.

Uso: python3 reporte_cwr/tools/generar_unload.py
"""
import re, pathlib, sqlglot

ROOT = pathlib.Path(__file__).resolve().parent.parent
FUENTE = ROOT / "reporte_cwr_x_territorio_v8.sql"
DESTINO = ROOT / "unload_reporte_cwr_v8.sql"

ENCABEZADO = """-- =====================================================================
-- UNLOAD del reporte CWR v8 a S3 (para resultados grandes)
--
-- Es la misma query que reporte_cwr_x_territorio_v8.sql, metida dentro de un
-- UNLOAD. Adentro del texto las comillas simples van duplicadas ('' en vez de ');
-- no editar la query acá: cambiarla en el .sql v8 y regenerar este archivo con
--     python3 reporte_cwr/tools/generar_unload.py
--
-- Las obras se leen de public.rankingdigital_song_id (columna song_id).
--
-- COMPLETAR ANTES DE CORRER (datos de "Redshift Query Editor Instructions for Access"):
--   <RUTA_S3>   carpeta y prefijo de destino, ej. s3://bucket/carpeta/reporte_cwr_
--   <IAM_ROLE>  ARN del rol con permiso de escritura en ese bucket. Si el cluster
--               tiene rol por defecto, reemplazar la línea por: IAM_ROLE default
-- Usuario SSO de referencia: AWSReservedSSO_RedshiftQueryEditorV2_78629b54267a226f/7000042560
--
-- Resultado: CSV con encabezado, en un solo archivo (PARALLEL OFF; si pasa de
-- 1 GB se parte en varios) y ordenado por obra y país.
-- =====================================================================
"""

def cuerpo_sin_comentarios(sql):
    cuerpo = sql[sql.index("WITH\n"):].rstrip().rstrip(";")
    cuerpo = "\n".join(l for l in cuerpo.split("\n") if not l.strip().startswith("--"))
    cuerpo = re.sub(r"\s+--[^\n']*$", "", cuerpo, flags=re.M)
    if "--" in cuerpo:
        raise SystemExit("Quedó un comentario '--' dentro de la query; revisar antes de generar el UNLOAD")
    return cuerpo

def generar():
    cuerpo = cuerpo_sin_comentarios(FUENTE.read_text(encoding="utf-8"))
    sqlglot.parse_one(cuerpo, read="redshift")
    texto = (ENCABEZADO + "UNLOAD ('\n" + cuerpo.replace("'", "''") + "\n')\n"
             "TO '<RUTA_S3>'\n"
             "IAM_ROLE '<IAM_ROLE>'\n"
             "FORMAT AS CSV\nHEADER\nPARALLEL OFF\nMAXFILESIZE 1 GB\nALLOWOVERWRITE;\n")
    adentro = texto.split("UNLOAD ('\n", 1)[1].rsplit("\n')\nTO", 1)[0]
    assert adentro.replace("''", "'") == cuerpo
    DESTINO.write_text(texto, encoding="utf-8")
    return cuerpo

if __name__ == "__main__":
    generar()
    print("OK", DESTINO)
