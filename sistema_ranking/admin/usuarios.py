"""
Administración de usuarios (reemplaza la pantalla Authentication > Users de Supabase).

    PGURL=postgresql://postgres:CLAVE@localhost:5432/ranking python usuarios.py <comando> ...

Comandos:
  listar                                   usuarios, rol, oficina, último ingreso y si están bloqueados
  crear <email> <rol> [oficina]            pide la contraseña (mín. 10 caracteres) sin mostrarla
  clave <email>                            cambia la contraseña
  codigo <email>                           código para que la persona restablezca su contraseña desde la pantalla
                                           de ingreso ("¿Olvidaste la contraseña?"); sirve una vez, durante 30 minutos
  rol <email> <rol> [oficina]              cambia rol/oficina
  bloquear <email> | desbloquear <email>   impide o permite el ingreso sin borrar al usuario
  panel <email> si|no                      da o quita el acceso al Panel de control (solo desde la consola)
  envio-bo <email> si|no                   habilita o no "Enviar reporte BO" (subida directa al servidor de BO)
  envio-bo todos si|no                     todas las personas (también las nuevas) o solo las habilitadas una por una
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
    if not args or args[0] not in ("listar", "crear", "clave", "codigo", "rol", "bloquear", "desbloquear", "panel", "envio-bo"):
        sys.exit(__doc__)
    cmd, resto = args[0], args[1:]
    with psycopg.connect(os.environ.get("PGURL") or sys.exit("Falta PGURL")) as con, con.cursor() as cur:
        if cmd == "listar":
            cur.execute("""SELECT u.email, coalesce(a.app_role::text, '(sin rol)'), coalesce(a.oficina, ''),
                                  coalesce(to_char(u.last_sign_in_at, 'YYYY-MM-DD HH24:MI'), 'nunca'),
                                  CASE WHEN u.banned_until > now() THEN 'BLOQUEADO' ELSE '' END,
                                  CASE WHEN EXISTS (SELECT 1 FROM panel.acceso p WHERE p.email = lower(u.email))
                                       THEN 'PANEL DE CONTROL' ELSE '' END,
                                  CASE WHEN to_regclass('public.envio_bo_usuarios') IS NOT NULL AND (EXISTS (
                                       SELECT 1 FROM public.envio_bo_usuarios e WHERE e.email = lower(u.email))
                                       OR coalesce((SELECT todos FROM public.envio_bo_config), true))
                                       THEN 'ENVIO A BO' ELSE '' END
                           FROM auth.users u LEFT JOIN public.app_users a ON a.user_id = u.id ORDER BY 1""")
            for fila in cur.fetchall():
                print("  ".join(f"{c:<28}" for c in fila).rstrip())
            cur.execute("SELECT to_regclass('public.envio_bo_config') IS NOT NULL AND "
                        "coalesce((SELECT todos FROM public.envio_bo_config), true)")
            if cur.fetchone()[0]:
                print('\n"Enviar reporte BO" está habilitado para todas las personas.')
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
        elif cmd == "panel":
            if len(resto) < 2 or resto[1] not in ("si", "no"):
                sys.exit("Uso: panel <email> si|no")
            cur.execute("SELECT 1 FROM auth.users WHERE lower(email) = %s", (email,))
            cur.fetchone() or sys.exit("No existe ese usuario.")
            if resto[1] == "si":
                cur.execute("INSERT INTO panel.acceso (email) VALUES (%s) ON CONFLICT DO NOTHING", (email,))
            else:
                cur.execute("DELETE FROM panel.acceso WHERE email = %s", (email,))
            cur.execute("SELECT panel.registrar('consola', 'ok', %s)",
                        (f"Acceso al Panel de control {'dado a' if resto[1] == 'si' else 'quitado a'} {email}",))
        elif cmd == "envio-bo" and email == "todos":
            if len(resto) < 2 or resto[1] not in ("si", "no"):
                sys.exit("Uso: envio-bo todos si|no")
            cur.execute("INSERT INTO public.envio_bo_config (id, todos) VALUES (true, %s) "
                        "ON CONFLICT (id) DO UPDATE SET todos = excluded.todos", (resto[1] == "si",))
            cur.execute("SELECT panel.registrar('consola', 'ok', %s)",
                        ("Envío del reporte BO habilitado para todas las personas" if resto[1] == "si"
                         else "Envío del reporte BO solo para las personas habilitadas una por una",))
            print("Listo: " + ("todas las personas pueden enviar el reporte BO." if resto[1] == "si"
                               else "solo las personas habilitadas una por una pueden enviar el reporte BO."))
        elif cmd == "envio-bo":
            if len(resto) < 2 or resto[1] not in ("si", "no"):
                sys.exit("Uso: envio-bo <email> si|no")
            cur.execute("SELECT 1 FROM auth.users WHERE lower(email) = %s", (email,))
            cur.fetchone() or sys.exit("No existe ese usuario.")
            if resto[1] == "si":
                cur.execute("INSERT INTO public.envio_bo_usuarios (email) VALUES (%s) ON CONFLICT DO NOTHING", (email,))
            else:
                cur.execute("DELETE FROM public.envio_bo_usuarios WHERE email = %s", (email,))
            cur.execute("SELECT panel.registrar('consola', 'ok', %s)",
                        (f"Envío del reporte BO {'habilitado a' if resto[1] == 'si' else 'quitado a'} {email}",))
        elif cmd == "codigo":
            cur.execute("SELECT auth.generar_codigo_clave(%s)", (email,))
            print(f"Código para {email}: {cur.fetchone()[0]}")
            print("Sirve una sola vez, durante 30 minutos: en la pantalla de ingreso, \"¿Olvidaste la contraseña?\".")
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
