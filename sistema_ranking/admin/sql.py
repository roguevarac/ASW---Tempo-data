"""
Consulta de una línea (reemplaza a psql -At en la versión portable de Windows).
    PGURL=postgresql://postgres:CLAVE@127.0.0.1:54329/ranking python sql.py "select count(*) from auth.users"
Imprime una fila por línea y las columnas separadas por |. Sale con código 1 si la consulta falla.
"""
import os
import sys

import psycopg

if len(sys.argv) != 2:
    sys.exit(__doc__)
try:
    with psycopg.connect(os.environ.get("PGURL") or sys.exit("Falta PGURL"), autocommit=True) as con:
        cur = con.execute(sys.argv[1])
        if cur.description:
            for fila in cur.fetchall():
                print("|".join("" if v is None else str(v) for v in fila))
except psycopg.Error as e:
    sys.exit(f"Error: {e}")
