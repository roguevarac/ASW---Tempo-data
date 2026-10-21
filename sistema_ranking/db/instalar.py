"""
Crea la base completa, igual que instalar.sh pero sin psql (lo usa la versión portable de Windows).
    PGURL=postgresql://postgres:CLAVE@127.0.0.1:54329/ranking AUTHENTICATOR_PASSWORD=... python instalar.py
PGURL es el superusuario. Si la base de PGURL no existe, la crea (conectándose a la base "postgres").
"""
import os
import pathlib
import sys

import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo

AQUI = pathlib.Path(__file__).resolve().parent
PGURL = os.environ.get("PGURL") or sys.exit("Falta PGURL")
CLAVE = os.environ.get("AUTHENTICATOR_PASSWORD") or sys.exit("Falta AUTHENTICATOR_PASSWORD")


def correr(con, *archivos):
    for nombre in archivos:
        con.execute((AQUI / nombre).read_text(encoding="utf-8"))


def mejoras(con):
    # Mejoras propias (db/mejoras/*.sql): idempotentes, se aplican también sobre una base ya instalada.
    con.execute("SET ROLE app_owner")
    for f in sorted((AQUI / "mejoras").glob("*.sql")):
        con.execute(f.read_text(encoding="utf-8"))
    con.execute("RESET ROLE")


def main():
    datos = conninfo_to_dict(PGURL)
    base = datos.get("dbname", "postgres")
    with psycopg.connect(make_conninfo(PGURL, dbname="postgres"), autocommit=True) as con:
        if not con.execute("SELECT 1 FROM pg_database WHERE datname = %s", (base,)).fetchone():
            con.execute(sql.SQL("CREATE DATABASE {} TEMPLATE template0 ENCODING 'UTF8'").format(sql.Identifier(base)))
    with psycopg.connect(PGURL, autocommit=True) as con:
        if con.execute("SELECT to_regclass('public.tracks_master') IS NOT NULL").fetchone()[0]:
            con.execute("SET client_min_messages = warning")
            mejoras(con)
            print("Base ya instalada.")
            return
        con.execute("SET client_min_messages = warning")
        correr(con, "01_roles_extensiones.sql")
        con.execute(sql.SQL("ALTER ROLE authenticator PASSWORD {}").format(sql.Literal(CLAVE)))
        con.execute("SET ROLE app_owner")
        correr(con, "02_auth_storage.sql", "03_esquema.sql", "04_rls_politicas.sql")
        con.execute("RESET ROLE")
        correr(con, "05_permisos.sql", "06_datos_iniciales.sql")
        mejoras(con)
    print("Base instalada.")


if __name__ == "__main__":
    try:
        main()
    except psycopg.Error as e:
        sys.exit(f"Error al instalar la base: {e}")
