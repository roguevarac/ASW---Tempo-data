# Migración de Supabase a un sistema propio

Partes del proyecto en Supabase y cómo se extrae cada una:

| Parte | Cómo se extrae | Archivo |
|---|---|---|
| Base de datos (tablas, funciones, seguridad) + buckets, auth y realtime | SQL Editor de Supabase | `extraer_esquema.sql` |
| Edge Functions | Supabase CLI desde PowerShell | `descargar_edge_functions.ps1` |
| Archivos del bucket | Después de ver el tamaño (sección 14 del CSV) | — |
| Front | Ya es código: subirlo a un repo de GitHub si no está | — |

## Paso 1 — extraer la estructura (pendiente: lo corre el usuario)
`extraer_esquema.sql` se pega en el SQL Editor de Supabase y devuelve UN resultado con una fila por objeto:
extensiones, enums, tablas, restricciones (PK, UNIQUE, CHECK, FK), índices, vistas, funciones, triggers, RLS,
políticas, permisos por rol y tamaño estimado de cada tabla. Solo estructura, no lee datos.
Exportar a CSV y dejarlo en esta carpeta como `esquema_supabase.csv`.

También trae lo de Supabase que hay que reemplazar: buckets y sus políticas, archivos por bucket, usuarios por
proveedor de login y tablas en realtime. No trae contraseñas, tokens ni contenido de archivos.

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

## Edge Functions
`descargar_edge_functions.ps1` (Windows/PowerShell): lista y descarga el código de todas las funciones con la CLI de
Supabase (`npx supabase`, autorización por navegador con `npx supabase login`; no se escriben contraseñas). Baja
además los NOMBRES de los secretos, sin sus valores. Subir la carpeta `supabase/functions` a
`migracion_supabase/edge_functions/`.
