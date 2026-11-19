"""
Genera db/03_esquema.sql a partir del CSV extraído de Supabase
(migracion_supabase/origen/esquema_supabase.csv), sin reescribir a mano la lógica:
tablas, restricciones, índices, funciones, vistas y triggers se copian tal cual.

Cambios respecto de Supabase (todos a propósito, ver README):
  - Las vistas se crean con security_invoker = true: respetan RLS del usuario
    (en Supabase corrían como dueño y se salteaban RLS).
  - Comentarios de tabla pasan a COMMENT ON TABLE.
  - No se copian extensiones propias de Supabase (pg_cron, pg_net, supabase_vault):
    sus tareas las hace la API.
RLS, políticas y permisos van en 04_seguridad.sql (escritos a mano y revisados).

Uso: python3 sistema_ranking/db/generar_esquema.py
"""
import csv, pathlib, re

RAIZ = pathlib.Path(__file__).resolve().parents[2]
CSV = RAIZ / "migracion_supabase" / "origen" / "esquema_supabase.csv"
SALIDA = pathlib.Path(__file__).resolve().parent / "03_esquema.sql"

def main():
    filas = list(csv.DictReader(open(CSV, encoding="utf-8")))
    por = {}
    for f in filas:
        por.setdefault(f["tipo"], []).append(f)
    out = ["-- GENERADO por generar_esquema.py desde esquema_supabase.csv. No editar a mano.",
           "SET check_function_bodies = off;", "SET search_path = public;", ""]

    out.append("-- ===== Tipos =====")
    out += [f["definicion"] for f in por.get("enum", [])]

    out.append("\n-- ===== Tablas =====")
    comentarios = []
    for f in por.get("tabla", []):
        d = f["definicion"]
        partes = d.split("\n);")
        out.append(partes[0] + "\n);")
        resto = partes[1].strip() if len(partes) > 1 else ""
        if resto.startswith("--"):
            comentarios.append((f["objeto"], resto[2:].strip()))
    for obj, c in comentarios:
        out.append(f"COMMENT ON TABLE {obj} IS '{c.replace(chr(39), chr(39)*2)}';")

    out.append("\n-- ===== Restricciones (PK, UNIQUE, CHECK y después FK) =====")
    orden = ["restriccion PK", "restriccion UNIQUE", "restriccion CHECK", "restriccion EXCLUDE", "restriccion FK"]
    for t in orden:
        out += [f["definicion"] for f in por.get(t, [])]

    out.append("\n-- ===== Índices =====")
    out += [f["definicion"] for f in por.get("indice", [])]

    out.append("\n-- ===== Funciones (copiadas tal cual) =====")
    for f in por.get("funcion", []):
        out.append(f["definicion"])

    out.append("\n-- ===== Vistas (security_invoker: respetan RLS del usuario) =====")
    for f in por.get("vista", []):
        d = f["definicion"].rstrip().rstrip(";")
        d = re.sub(r"^CREATE VIEW (\S+) AS", r"CREATE VIEW \1 WITH (security_invoker = true) AS", d, count=1)
        out.append(d + ";")

    out.append("\n-- ===== Triggers =====")
    out += [f["definicion"] for f in por.get("trigger", [])]

    out.append("\nRESET check_function_bodies;")
    SALIDA.write_text("\n".join(out) + "\n", encoding="utf-8")

    # RLS y políticas: copiadas tal cual de Supabase (incluidas las de storage).
    seg = ["-- GENERADO por generar_esquema.py desde esquema_supabase.csv. No editar a mano.", ""]
    seg += [f["definicion"] for f in por.get("rls", [])]
    seg.append("")
    seg += [f["definicion"] for f in por.get("politica", [])]
    seg.append("")
    seg.append("-- Archivos (storage.objects): mismas políticas que el bucket de Supabase")
    seg += [f["definicion"] for f in por.get("politica_storage", [])]
    (SALIDA.parent / "04_rls_politicas.sql").write_text("\n".join(seg) + "\n", encoding="utf-8")
    print("OK", SALIDA, "funciones:", len(por.get("funcion", [])), "tablas:", len(por.get("tabla", [])))

if __name__ == "__main__":
    main()
