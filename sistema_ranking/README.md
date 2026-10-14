# Sistema Ranking Digital (propio, sin Supabase)

Este es el mismo sistema que corría en Supabase, ahora en un servidor propio. El front es el mismo HTML con la misma
lógica. Lo único que cambió es a quién le habla: antes era Supabase, ahora es nuestra API.

```
navegador ──► API propia (FastAPI) ──► PostgreSQL 16
  index.html     login, tablas, RPC,       las mismas 11 tablas, 38 funciones, vistas,
  tempo-client   archivos, YouTube         triggers, RLS y políticas que en Supabase
```

| Supabase | Acá |
|---|---|
| Base de datos | `db/` instala lo mismo, generado del CSV del esquema. `tests/comparar_con_supabase.py` lo compara contra el CSV: 151 objetos idénticos. |
| Auth (email + contraseña) | `auth.users` con bcrypt, `auth.uid()`, `auth.jwt()`. Los usuarios migrados **conservan su contraseña**. |
| PostgREST + supabase-js | `api/app.py` + `front/tempo-client.js`, que imita los métodos de supabase-js que usa el front. |
| Bucket `csv-uploads` | Archivos en disco (`STORAGE_DIR`) y registro en `storage.objects`, con RLS y links firmados. |
| Edge Function de YouTube + pg_cron | `api/youtube_job.py`: misma lógica y mismos 8 países, programada con `YOUTUBE_CRON`. |
| Dashboard > Users | `admin/usuarios.py` |

## Poner en marcha

Hace falta un servidor con Docker.

```sh
cd sistema_ranking
cp .env.example .env        # completar las 3 claves (cada una larga y distinta)
docker compose up -d        # la primera vez instala la base; después no la toca
```

El sistema queda en `http://servidor:8000`. Para usarlo fuera de la red interna, poné adelante un proxy con HTTPS
(nginx, Caddy o el balanceador de la empresa), porque el login viaja en cada pedido. La base no se publica fuera
del servidor.

## Migrar los datos de Supabase

1. **En tu computadora**: `pip install "psycopg[binary]" httpx` y luego `python migracion/exportar_supabase.py`.
   El script pide la cadena de conexión (Dashboard > Connect > Session pooler), la URL del proyecto y la
   service_role key. No guarda nada de eso. Crea la carpeta `exportacion/` con:
   - las 11 tablas;
   - los usuarios;
   - los 4.594 archivos del bucket (unos 68 MB);
   - las tareas de pg_cron;
   - un manifiesto con la cantidad de filas y el hash de cada archivo.

   Si se corta, volvé a correrlo: solo baja lo que falta.
2. **Llevá `exportacion/` al servidor** (junto a `docker-compose.yml`) y corré:
   ```sh
   docker compose run --rm -v ./exportacion:/exportacion \
     -e PGURL=postgresql://postgres:<POSTGRES_PASSWORD>@db:5432/ranking \
     api python /app/migracion/importar.py /exportacion
   ```
   La importación va en una sola transacción y no dispara triggers, así que los datos quedan exactamente como
   estaban. Al terminar compara filas y archivos contra el manifiesto, y si algo no coincide no importa nada.
   Para volver a cargar sobre datos existentes, agregá `--reemplazar`.
3. **Horario de YouTube**: copiá en `YOUTUBE_CRON` del `.env` el `schedule` que figura en
   `exportacion/cron_jobs.csv`. Después corré `docker compose up -d`. Ese horario está en UTC en pg_cron: si
   lo copiás tal cual, poné `YOUTUBE_CRON_TZ=UTC`.
4. Entrá con tu usuario de siempre. Revisá la tabla principal, la de territorios y el historial de cargas.
   Cuando esté todo bien, apagá Supabase.

## Usuarios

```sh
docker compose exec -e PGURL=postgresql://postgres:<POSTGRES_PASSWORD>@db:5432/ranking api \
  python /app/admin/usuarios.py listar
#  crear <email> <admin|usuario_estandar|auditor> [oficina]   (pide la contraseña, mínimo 10 caracteres)
#  clave <email> · rol <email> <rol> [oficina] · bloquear <email> · desbloquear <email>
```

Un usuario bloqueado pierde la sesión en el momento, no cuando le vence.

## Qué se mejoró respecto de Supabase

- **El rol `anon` no tiene permisos.** En Supabase, `anon` tenía permisos completos sobre las vistas y sobre
  `bo_export_counter`, y la clave anon estaba escrita en el HTML. Con esa clave cualquiera podía leer esas vistas
  sin loguearse. Ahora no hay clave en el front y sin login no se ve nada.
- **Las vistas respetan las mismas reglas de RLS que las tablas** (`security_invoker`). Así no sirven para saltear
  las políticas.
- El login frena los intentos repetidos de adivinar contraseñas.
- Los links de descarga están firmados y vencen.
- Las rutas de archivos están validadas, así que no se puede salir de la carpeta del bucket.
- Un `PATCH` sin filtro se rechaza: no se puede modificar la tabla entera por error.
- Un usuario bloqueado pierde la sesión en el acto.
- La tarea de YouTube no puede correr dos veces al mismo tiempo.

## Comportamientos heredados de Supabase (se mantuvieron a propósito)

Se dejaron iguales para no perder ni cambiar funciones. Si se quieren corregir, conviene hacerlo como un cambio
aparte:

- `fn_set_tempo_id`: si se le pone a una obra un Tempo ID que ya tiene otra, falla por `UNIQUE(tempo_id)` en lugar
  de unificarlas. No se puede diferir porque `fk_territory_tempo_id` depende de ese índice.
- El borrado lógico solo lo puede hacer el rol `admin`. Las políticas no se lo permiten a `usuario_estandar`.
- `fn_upsert_territory_track` tiene un `ON CONFLICT` que no coincide con ningún índice único, así que falla si se
  la llama. El front no la usa.

## Pruebas

`tests/correr_todo.sh` corre todo contra un Postgres local. Cada prueba empieza con la base recién instalada.

| Prueba | Qué revisa |
|---|---|
| `comparar_con_supabase.py` | Estructura idéntica a la del CSV de Supabase. |
| `test_e2e.py` | Por HTTP, cada operación del front: login, cargas, ediciones, reportes, historial, archivos, exportaciones, permisos por rol y bloqueo. |
| `test_youtube.py` | La tarea de YouTube con respuestas simuladas, incluidos los errores por país. |
| `test_navegador.py` | El front real en Chromium: login, cargar CSV, editar, descargar, historial, reporte BO, sesión y auditor en solo lectura. |
| `test_migracion.py` | Exportar e importar comparando fila por fila y archivo por archivo; que se mantengan las contraseñas; protecciones ante datos existentes o archivos alterados. |

## Archivos

```
db/          instalar.sh + SQL (03 y 04 se generan del CSV con generar_esquema.py)
api/         app.py (API) y youtube_job.py
front/       index.html (generado de ../frontend_ranking_digital.html con generar_index.py), tempo-client.js
admin/       usuarios.py
migracion/   exportar_supabase.py (en tu PC) e importar.py (en el servidor)
tests/       correr_todo.sh y las pruebas
```

Si se cambia el front original, regenerá `front/index.html` con `python3 front/generar_index.py`. Ese script falla
si en el HTML queda alguna referencia a Supabase o alguna clave.
