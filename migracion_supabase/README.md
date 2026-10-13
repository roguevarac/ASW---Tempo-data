# Migración de la base de Supabase a un Postgres propio

## Paso 1 — extraer la estructura (pendiente: lo corre el usuario)
`extraer_esquema.sql` se pega en el SQL Editor de Supabase y devuelve UN resultado con una fila por objeto:
extensiones, enums, tablas, restricciones (PK, UNIQUE, CHECK, FK), índices, vistas, funciones, triggers, RLS,
políticas, permisos por rol y tamaño estimado de cada tabla. Solo estructura, no lee datos.
Exportar a CSV y dejarlo en esta carpeta como `esquema_supabase.csv`.

Probado en PostgreSQL 16: con lo que devuelve se reconstruyó una base desde cero y la nueva extracción dio idéntica
(mismo hash) a la original.

## Paso 2 — qué hay que reemplazar de Supabase (se decide con el CSV)
Supabase es Postgres, así que tablas, vistas, funciones, triggers y políticas pasan casi igual. Lo propio de
Supabase que no existe en un Postgres común:
- `auth.users` y `auth.uid()` / `auth.jwt()`: usuarios y sesión. Se reemplazan por una tabla de usuarios propia y
  una función que lea el usuario de la sesión (por ejemplo `current_setting('app.user_id')`).
- Roles `anon`, `authenticated`, `service_role`: se crean como roles propios con los mismos permisos.
- `storage` (archivos), `realtime`, Edge Functions, `pg_net`, `pg_cron`: solo si el CSV muestra que se usan.

## Paso 3 — datos
Con el tamaño de cada tabla (filas 12 del CSV) se elige: `COPY ... TO STDOUT CSV` tabla por tabla desde el SQL
Editor, o `pg_dump --data-only` si se tiene la cadena de conexión.
