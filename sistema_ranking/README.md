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
| Auth (email + contraseña) | `auth.users` con bcrypt, `auth.uid()`, `auth.jwt()`. Los usuarios migrados conservan su id, email y rol. |
| PostgREST + supabase-js | `api/app.py` + `front/tempo-client.js`, que imita los métodos de supabase-js que usa el front. |
| Bucket `csv-uploads` | Archivos en disco (`STORAGE_DIR`) y registro en `storage.objects`, con RLS y links firmados. |
| Edge Function de YouTube + pg_cron | `api/youtube_job.py`: misma lógica y mismos 8 países, programada con `YOUTUBE_CRON`. |
| Dashboard > Users | `USUARIOS.bat` (o `admin/usuarios.py`) |

## Uso en Windows (doble clic, sin Docker)

No hay que instalar nada ni tener permisos de administrador. PostgreSQL 17 y Python 3.12 corren desde una carpeta
de tu usuario (`%LOCALAPPDATA%\RankingDigital`), como cualquier programa portable.

1. Bajá el ZIP de la rama desde GitHub. Antes de descomprimirlo: clic derecho > Propiedades > tildá
   **Desbloquear** > Aceptar. Después descomprimilo y entrá a la carpeta `sistema_ranking`.
2. **`1_INSTALAR.bat`**. La primera vez baja unos 50 MB de componentes oficiales:
   - Python 3.12, de NuGet (lo publica la Python Software Foundation);
   - PostgreSQL 17, del paquete de npm `@embedded-postgres/windows-x64`.

   Cada archivo se verifica por su sha256 antes de usarlo. Los paquetes de Python ya vienen en el ZIP
   (`windows\paquetes`). Después arma la base, deja el sistema funcionando en http://localhost:8000 (o el siguiente
   puerto libre) y crea el acceso directo **Ranking Digital** en el escritorio. También te pregunta si querés que
   arranque solo al prender la PC.
3. **`2_MIGRAR_DESDE_SUPABASE.bat`**. Trae de Supabase los datos, los usuarios y el historial de cargas. Te pide:
   - la URL del proyecto: Enter para usar la tuya;
   - la service_role key: Supabase > Project Settings > API Keys > service_role > Reveal;
   - una contraseña nueva para cada usuario, porque Supabase no entrega las contraseñas;
   - el horario de la carga de YouTube, que se saca en el SQL Editor con `select schedule from cron.job;`.

   Los archivos del historial los toma de tus carpetas de OneDrive `Charts historicos Youtube` y
   `Charts historicos_spotify`, buscándolos por nombre y tamaño exactos. Los que no estén ahí, los baja del bucket.
   Todo viaja por HTTPS y usa los certificados de Windows, así que funciona detrás del proxy de la empresa. La clave
   no se guarda en ningún archivo.
4. Para el día a día:
   - el acceso directo del escritorio, o **`ABRIR_SISTEMA.bat`**;
   - **`USUARIOS.bat`** para crear usuarios, cambiar contraseñas, cambiar roles y bloquear;
   - **`DETENER.bat`** para apagarlo (los datos quedan guardados).

**Si el paso 2 no puede bajar algo** (la red de la empresa bloquea esa dirección), el mensaje muestra el link. Bajá
el archivo con el navegador; queda en tu carpeta Descargas. Después volvé a correr `1_INSTALAR.bat`: lo encuentra
ahí solo y lo verifica. Los dos links son:
- https://api.nuget.org/v3-flatcontainer/python/3.12.10/python.3.12.10.nupkg
- https://registry.npmjs.org/@embedded-postgres/windows-x64/-/windows-x64-17.10.0-beta.17.tgz

Hay dos diferencias con Supabase:
- **Solo funciona mientras la PC está prendida.** Eso incluye la carga automática de YouTube: si la PC está apagada
  a esa hora, esa semana no se carga sola.
- **Solo entra quien usa esa PC.** El sistema escucha solo en esa PC. Para que lo use todo el equipo, tiene que
  instalarse en un servidor (sección siguiente).

**Dónde queda cada cosa** (todo en `%LOCALAPPDATA%\RankingDigital`, fuera de OneDrive a propósito, porque OneDrive
puede dañar una base de datos mientras la sincroniza):
- `datos\`: la base y los archivos del historial;
- `logs\`: los registros, para ver qué pasó si algo falla;
- `config.env`: las claves internas, generadas al azar;
- `app\`: la copia del programa.

**Para actualizar:** bajá el ZIP nuevo y corré `1_INSTALAR.bat`. Reemplaza el programa y conserva los datos, los
usuarios y las claves.

## Servidor Linux (para que lo use todo el equipo)

Hace falta un servidor con Docker.

```sh
cd sistema_ranking
cp .env.example .env        # completar las 3 claves (cada una larga y distinta)
docker compose up -d        # la primera vez instala la base; después no la toca
```

El sistema queda en `http://servidor:8000`. Si se va a usar fuera de la red interna, poné adelante un proxy con
HTTPS (nginx, Caddy o el balanceador de la empresa), porque el login viaja en cada pedido. La base no se publica
fuera del servidor.

### Migrar los datos de Supabase en el servidor

1. Exportá (en el servidor o en cualquier PC con Python: `pip install "psycopg[binary]" httpx`):
   `python migracion/exportar_supabase.py exportacion --sin-archivos`. Las opciones:
   - Sin `--sin-archivos`, también baja el bucket entero (unos 68 MB).
   - Con `--via-db` (cadena de conexión, puerto 5432), además conserva las contraseñas y saca una foto exacta de un
     mismo instante. En redes corporativas ese puerto suele estar bloqueado.
2. Importá:
   ```sh
   docker compose run --rm -v ./exportacion:/exportacion -v "/ruta/charts:/charts:ro" \
     -e PGURL=postgresql://postgres:<POSTGRES_PASSWORD>@db:5432/ranking \
     api python /app/migracion/importar.py /exportacion --archivos-desde /charts
   ```
   - Va todo en una sola transacción y sin disparar triggers, así que los datos quedan exactamente como estaban.
   - Compara las filas contra el manifiesto; si algo no coincide, no importa nada.
   - Si falta algún archivo del historial, lo lista en `exportacion/archivos_faltantes.txt`. Para esos archivos:
     `exportar_supabase.py exportacion --bajar-faltantes` los baja del bucket, y `--permitir-faltantes` importa
     igual, sin ellos.
   - `--reemplazar` carga sobre datos que ya existen.
3. Contraseñas: `admin/usuarios.py clave <email>` para cada usuario.
4. Horario de YouTube: `YOUTUBE_CRON=<schedule de cron.job>` y `YOUTUBE_CRON_TZ=UTC` en `.env`, y después
   `docker compose up -d`.

## Usuarios (servidor Linux)

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
| `test_migracion.py` | Exportar e importar comparando fila por fila y archivo por archivo. Los dos modos (API y conexión directa), con Supabase simulado; archivos del historial tomados de carpetas tipo OneDrive; protecciones ante datos existentes, archivos faltantes o alterados. |
| `test_portable.py` | La versión portable de Windows con PowerShell real y PostgreSQL 17, como la usa una persona: instalar, migrar, poner contraseñas, programar YouTube, administrar usuarios, apagar, volver a abrir y actualizar. |
| `test_componentes_windows.py` | Los componentes reales de Windows (Python y PostgreSQL): verificación por sha256, archivos alterados, descarga caída y que al descomprimir esté todo lo necesario. |
| `test_paquetes_windows.py` | Que los paquetes de Python incluidos alcancen para Windows sin internet (dependencias evaluadas como en Windows). |

## Archivos

```
db/          instalar.sh (Docker/servidor) e instalar.py (Windows portable, sin psql) + SQL (03 y 04 se generan del CSV con generar_esquema.py)
api/         app.py (API) y youtube_job.py
front/       index.html (generado de ../frontend_ranking_digital.html con generar_index.py), tempo-client.js
admin/       usuarios.py
migracion/   exportar_supabase.py e importar.py
windows/     los scripts que corren los .bat (PowerShell 5.1 o superior) y paquetes/ (Python para Windows, sin internet)
*.bat        doble clic en Windows: 1_INSTALAR, 2_MIGRAR_DESDE_SUPABASE, ABRIR_SISTEMA, USUARIOS, DETENER
tests/       correr_todo.sh y las pruebas
```

Si se cambia el front original, regenerá `front/index.html` con `python3 front/generar_index.py`. Ese script falla
si en el HTML queda alguna referencia a Supabase o alguna clave.
