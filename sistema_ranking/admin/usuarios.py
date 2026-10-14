"""
Administración de usuarios (reemplaza la pantalla Authentication > Users de Supabase).

    PGURL=postgresql://postgres:CLAVE@localhost:5432/ranking python usuarios.py <comando> ...

Comandos:
  listar                                   usuarios, rol, oficina, último ingreso y si están bloqueados
  crear <email> <rol> [oficina]            pide la contraseña (mín. 10 caracteres) sin mostrarla
  clave <email>                            cambia la contraseña
  rol <email> <rol> [oficina]              cambia rol/oficina
  bloquear <email> | desbloquear <email>   impide o permite el ingreso sin borrar al usuario
Roles: admin, usuario_estandar, auditor.
"""
import getpass
import os
import sys

import psycopg

ROLES = ("admin", "usuario_estandar", "auditor")


def pedir_clave():
    a = getpass.getpass("Contraseña nueva: ")
    if a != getpass.getpass("Repetila: "):
        sys.exit("Las contraseñas no coinciden.")
    return a


def main(args):
    if not args or args[0] not in ("listar", "crear", "clave", "rol", "bloquear", "desbloquear"):
        sys.exit(__doc__)
    cmd, resto = args[0], args[1:]
    with psycopg.connect(os.environ.get("PGURL") or sys.exit("Falta PGURL")) as con, con.cursor() as cur:
        if cmd == "listar":
            cur.execute("""SELECT u.email, coalesce(a.app_role::text, '(sin rol)'), coalesce(a.oficina, ''),
                                  coalesce(to_char(u.last_sign_in_at, 'YYYY-MM-DD HH24:MI'), 'nunca'),
                                  CASE WHEN u.banned_until > now() THEN 'BLOQUEADO' ELSE '' END
                           FROM auth.users u LEFT JOIN public.app_users a ON a.user_id = u.id ORDER BY 1""")
            for fila in cur.fetchall():
                print("  ".join(f"{c:<28}" for c in fila).rstrip())
            return
        if not resto:
            sys.exit(__doc__)
        email = resto[0].strip().lower()
        if cmd in ("crear", "rol"):
            if len(resto) < 2 or resto[1] not in ROLES:
                sys.exit(f"Rol inválido. Opciones: {', '.join(ROLES)}")
            if cmd == "crear":
                cur.execute("SELECT 1 FROM auth.users WHERE lower(email) = %s", (email,))
                if cur.fetchone():
                    sys.exit("Ese usuario ya existe (usá 'clave' o 'rol').")
                cur.execute("SELECT auth.set_password(%s, %s)", (email, pedir_clave()))
            cur.execute("SELECT id FROM auth.users WHERE lower(email) = %s", (email,))
            fila = cur.fetchone() or sys.exit("No existe ese usuario.")
            oficina = resto[2] if len(resto) > 2 else None
            cur.execute("""INSERT INTO public.app_users (user_id, app_role, oficina) VALUES (%s, %s, %s)
                           ON CONFLICT (user_id) DO UPDATE SET app_role = excluded.app_role,
                               oficina = coalesce(excluded.oficina, public.app_users.oficina)""",
                        (fila[0], resto[1], oficina))
        elif cmd == "clave":
            cur.execute("SELECT 1 FROM auth.users WHERE lower(email) = %s", (email,))
            cur.fetchone() or sys.exit("No existe ese usuario.")
            cur.execute("SELECT auth.set_password(%s, %s)", (email, pedir_clave()))
        else:
            cur.execute("UPDATE auth.users SET banned_until = %s WHERE lower(email) = %s",
                        ("infinity" if cmd == "bloquear" else None, email))
            if not cur.rowcount:
                sys.exit("No existe ese usuario.")
    print("Hecho.")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except psycopg.Error as e:
        sys.exit(f"Error: {e.diag.message_primary or e}")
