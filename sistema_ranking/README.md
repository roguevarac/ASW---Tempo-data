# Sistema Ranking Digital (propio, sin Supabase)

Este es el mismo sistema que corría en Supabase, ahora en un servidor propio. El front es el mismo HTML con la misma
lógica. Lo único que cambió es a quién le habla: antes era Supabase, ahora es nuestra API.

```
navegador ──► API propia (FastAPI) ──► PostgreSQL 16
  index.html     login, tablas, RPC,       las mismas 11 tablas, 38 funciones, vistas,
  tempo-client   archivos                  triggers, RLS y políticas que en Supabase
```

| Supabase | Acá |
|---|---|
| Base de datos | `db/` instala lo mismo, generado del CSV del esquema. `tests/comparar_con_supabase.py` lo compara contra el CSV: 151 objetos idénticos. |
| Auth (email + contraseña) | `auth.users` con bcrypt, `auth.uid()`, `auth.jwt()`. Los usuarios migrados conservan su id, email y rol. |
| PostgREST + supabase-js | `api/app.py` + `front/tempo-client.js`, que imita los métodos de supabase-js que usa el front. |
| Bucket `csv-uploads` | Archivos en disco (`STORAGE_DIR`) y registro en `storage.objects`, con RLS y links firmados. |
| Edge Function de YouTube + pg_cron | No se usa más: los charts de YouTube se cargan a mano desde **Carga CSV**, igual que los de Spotify. |
| Dashboard > Users | `USUARIOS.bat` (o `admin/usuarios.py`) |

## En tu PC: Ubuntu (WSL2) + Docker Engine

Todo se hace desde la terminal de Ubuntu, con Docker Engine instalado dentro de Ubuntu. No hace falta Docker
Desktop ni ningún permiso de administrador en Windows. El sistema se abre en el navegador de Windows, en
`http://localhost:PUERTO`.

### Una sola vez

```bash
sudo apt update && sudo apt install -y git curl unzip openssl
cd ~/proyectos
```

Bajá el proyecto de una de estas dos formas:

- **Con git.** Si el repositorio es privado, git te pide tu usuario de GitHub y, como contraseña, un token
  personal:
  ```bash
  git clone -b claude/funny-bell-bbdz84 https://github.com/roguevarac/ASW---Tempo-data.git ranking
  cd ~/proyectos/ranking/sistema_ranking
  ```
- **Con el ZIP.** En GitHub, elegí la rama `claude/funny-bell-bbdz84` > Code > Download ZIP. Queda en Descargas de
  Windows, y desde Ubuntu lo descomprimís así:
  ```bash
  unzip /mnt/c/Users/7000042560/Downloads/ASW---Tempo-data-claude-funny-bell-bbdz84.zip -d ~/proyectos
  cd ~/proyectos/ASW---Tempo-data-claude-funny-bell-bbdz84/sistema_ranking
  ```
  `7000042560` es tu usuario de Windows. Si el archivo tiene otro nombre, `ls /mnt/c/Users/7000042560/Downloads/*.zip`
  lo muestra.

- **Desde una copia en OneDrive** (por ejemplo `...\Backoffice\RANKING DIGITAL REGIONAL`). Esperá a que OneDrive
  termine de sincronizar (tilde verde) y copiala dentro de Ubuntu. No la uses directo desde `/mnt/c`: OneDrive la
  sincroniza mientras Docker la usa, y desde el disco de Windows todo anda más lento.
  ```bash
  cp -r "/mnt/c/Users/7000042560/OneDrive - Sony/SMP-Administration Argentina - Documents/Latam/Backoffice/RANKING DIGITAL REGIONAL" ~/proyectos/ranking
  cd ~/proyectos/ranking/sistema_ranking
  ```
  Si algún archivo quedó con fin de línea de Windows, `ranking.sh` lo arregla solo. Si el que quedó así es el propio
  `ranking.sh` (el error menciona `$'\r'`), corré una vez `sed -i 's/\r$//' ranking.sh`.

Después, en la carpeta `sistema_ranking`:

```bash
bash ranking.sh instalar     # arma y arranca el sistema; la primera vez tarda unos minutos
bash ranking.sh migrar       # trae de Supabase los datos, los usuarios y el historial
```

`instalar`:
- genera las claves internas al azar en `~/.config/ranking-digital/ranking.env`, fuera del proyecto. No compartas
  ese archivo.
- baja PostgreSQL 17 y Python. Si Docker Hub está bloqueado o limitado, usa solo los espejos públicos de las mismas
  imágenes oficiales: `mirror.gcr.io`, de Google, y `public.ecr.aws`, de Amazon.
- arma la imagen y deja el sistema en `http://localhost:8000`, o en el siguiente puerto libre.

`migrar` te pide:
- la URL del proyecto de Supabase: Enter para usar la tuya;
- la service_role key: Supabase > Project Settings > API Keys > service_role > Reveal. No se guarda en ningún lado.
- las carpetas con los CSV del historial. Las de OneDrive (`Charts historicos Youtube` y `Charts historicos_spotify`)
  las encuentra solas. También podés pegar una ruta de Windows (`C:\...`) o de Ubuntu.
- contraseñas nuevas para los usuarios, porque Supabase no entrega las contraseñas por la API.

Los archivos del historial que no estén en esas carpetas los baja del bucket. Antes de importar, todo se compara
contra lo que había en Supabase; si algo no coincide, no se importa nada.

### La aplicación en Windows

Ranking Digital se usa como una **aplicación**: tiene ventana propia, sin pestañas ni barra del navegador, y su
ícono. Por dentro es una aplicación web instalable (PWA) que corre en Microsoft Edge, y el servidor en Ubuntu queda
en segundo plano, sin ventanas negras. No hace falta ser administrador.

`instalar` la crea al final. También se puede crear (o rehacer) con `bash ranking.sh acceso-directo`. Deja:
- **Ranking Digital** en el escritorio y en el **menú Inicio**, así aparece en la búsqueda de Windows. Abre la
  aplicación en su ventana. Si el servidor estaba apagado, lo enciende y muestra "Iniciando Ranking Digital…" hasta
  que está listo.
- **Apagar Ranking Digital**, en el menú Inicio. Apaga todo; los datos quedan guardados.
- **Arranque oculto al iniciar Windows**, si lo aceptás (recomendado). El servidor queda prendido mientras la sesión
  de Windows esté abierta.

Si querés tenerla también en la barra de tareas, instalala desde Edge:
1. Con el servidor prendido, abrí `http://localhost:8000` en una **pestaña común** de Edge, no en InPrivate.
2. Usá el ícono **Instalar** de la barra de direcciones, o el menú **···** > **Aplicaciones** > **Instalar este sitio
   como aplicación**.
3. Clic derecho en su ícono de la barra de tareas > **Anclar**.

Edge solo la ofrece si la página cargó bien, con su manifiesto, sus íconos y el service worker activo. El sistema ya
trae todo eso. Si el servidor se estaba reiniciando, recargá la página y esperá unos segundos.

Si abrís la aplicación con el servidor apagado, en lugar de un error muestra "Ranking Digital está iniciando o
apagado" y entra sola cuando el servidor responde. Nunca guarda datos en el navegador: todo viene siempre del
servidor.

`bash ranking.sh actualizar` también actualiza estos accesos. Los registros del lanzador quedan en
`%LOCALAPPDATA%\RankingDigital\lanzador.log`.

### Día a día

| Comando | Para qué |
|---|---|
| Aplicación **Ranking Digital** (escritorio, menú Inicio) o `bash ranking.sh abrir` | Lo arranca si estaba apagado (incluso Docker) y lo abre en el navegador de Windows |
| `bash ranking.sh detener` | Lo apaga; los datos quedan guardados |
| `bash ranking.sh usuarios` | Crear usuarios, cambiar contraseñas, roles y oficina, bloquear y desbloquear |
| `bash ranking.sh estado` / `logs` | Qué está corriendo / últimos mensajes, si algo falla |
| `bash ranking.sh verificar` | Revisa que todo esté sano, sin cambiar nada |
| `bash ranking.sh actualizar` | Respaldo, versión nueva desde GitHub y reinicio, sin perder datos (si falla, vuelve sola a la anterior) |
| `bash ranking.sh respaldo` | Copia de la base y de los archivos en `~/proyectos/ranking-respaldos`, y también en el espejo de OneDrive (`respaldo_documentacion_sistema\respaldos`) |
| `bash ranking.sh espejo` | Copia al espejo de OneDrive los archivos cargados que falten y actualiza la documentación |
| `bash ranking.sh restaurar NOMBRE` | Vuelve a ese respaldo |
| `bash ranking.sh vaciar-historial` | Borra solo los archivos del historial (antes hace un respaldo) |
| `bash ranking.sh empezar-de-cero` | Borra todos los datos menos los usuarios, para empezar a cargar de cero (antes hace un respaldo) |

Hay dos cosas que tenés que saber:
- **Después de reiniciar Windows**, si aceptaste el arranque automático, el servidor ya está prendido: abrí la
  aplicación y listo.
- **Los charts se cargan a mano.** Spotify y YouTube se suben desde **Carga CSV**; no hay cargas automáticas. Arriba
  se ve la fecha del último chart de Spotify y de YouTube del país elegido, porque cada país se carga por separado.

**Manual de uso:** en la aplicación, botón **Manual de uso** (arriba a la derecha), o `http://localhost:8000/manual.html`.
Explica cada pestaña, las cargas, la limpieza de títulos, el reporte BO y el estado de trabajo.

**Empezar de cero.** Hay dos comandos. Los dos los confirma una persona (no corren con `--automatico`) y antes
hacen un respaldo; para volver atrás: `bash ranking.sh restaurar <respaldo>`.
- `bash ranking.sh empezar-de-cero` vacía todo para volver a cargar desde ahora:
  - la tabla principal;
  - la tabla por territorio (charts, Reporte Tempo, Reporte BO y estados de trabajo);
  - el historial de cambios y el seguimiento de envíos;
  - el historial de archivos.

  Quedan los usuarios y el número de la próxima carga del reporte BO, para no repetir números que BO ya recibió.
- `bash ranking.sh vaciar-historial` borra solo los archivos guardados y su lista en **Historial de cargas** (los datos cargados quedan).

**Respaldos:** los datos viven dentro de Ubuntu, en volúmenes de Docker.
- `bash ranking.sh respaldo` los copia también al espejo de OneDrive (ver la sección siguiente).
- `actualizar` hace un respaldo antes de cada cambio.
- Si algún día se reinstala Ubuntu, alcanza con `instalar` y `restaurar`.

**Versión nueva del proyecto:** bajala en otra carpeta y corré `bash ranking.sh instalar` desde ahí. Usa la misma
configuración y los mismos datos, y actualiza el programa.

### Espejo de respaldo y auditoría en OneDrive

**Principio operativo:**
- **Fuente de verdad:** la base PostgreSQL y el almacenamiento de archivos del sistema, en Docker. La aplicación lee
  y escribe solo ahí.
- **Espejo:** la carpeta compartida
  `C:\Users\7000042560\OneDrive - Sony\SMP-Administration Argentina - Documents\Latam\RANKING DIGITAL REGIONAL`
  recibe una copia de cada carga y de cada respaldo, para transparencia y auditoría.
- **Sin efecto sobre el sistema:** el sistema solo escribe en el espejo. Nunca lee de él ni borra nada. Si alguien
  borra o modifica un archivo en OneDrive, la base y la aplicación no cambian, y `bash ranking.sh espejo` vuelve a
  copiar lo que falte.
- **Una copia que falla no frena nada:** si la copia falla (OneDrive sin la carpeta o sin permiso), la carga se
  registra igual y el motivo queda en `bash ranking.sh logs`.

**Estructura:**

| Carpeta | Contenido | Cuándo se escribe |
|---|---|---|
| `Spotify Charts\<país>\` | Charts de Spotify cargados (país en minúsculas: `ar`, `cl`…) | En cada carga |
| `Youtube Charts\<país>\` | Charts de YouTube cargados | En cada carga |
| `Reportes BackOffice\<país>\` | Reportes BackOffice cargados | En cada carga |
| `Reportes Tempo Control\` (y `Tempo IDs\`) | Reportes Tempo Control y archivos de Tempo IDs cargados | En cada carga |
| `respaldo_documentacion_sistema\respaldos\` | `.dump` de la base y `.tgz` de los archivos | En `respaldo` y antes de cada `actualizar` |
| `respaldo_documentacion_sistema\docs\` | README, manual de uso, runbook de Antigravity y esquema de datos (`esquema\`) | En `respaldo`, `actualizar` y `espejo` |
| `LEEME - Respaldo y auditoria.txt` | Explicación de la carpeta para quien la abra | Siempre que se escribe en el espejo |

Solo se copian las cargas que cargaron datos. Las descargas (reporte BO generado y CSV de la tabla principal) no
son cargas y no se copian.

**Cómo funciona:**
- `ranking.sh` detecta la carpeta y la guarda en la configuración (`ESPEJO_DIR`).
- El servicio `espejo` de Docker (`api/espejo.py --servicio`) monta esa carpeta en `/espejo` y copia cada carga
  nueva unos segundos después de que se registra. Al arrancar copia lo que falte.
- Corre como root porque en WSL `/mnt/c` solo deja escribir al dueño de la carpeta o a root. Para compensarlo, no
  tiene puertos y ve los archivos del sistema en solo lectura. La API sigue sin privilegios y sin acceso a OneDrive.
- Si no se encuentra la carpeta de OneDrive, el espejo queda apagado y el sistema funciona igual.
- `bash ranking.sh espejo` y `actualizar` copian lo que falte, por ejemplo las cargas anteriores a esta función, sin
  pisar ni borrar nada.
- `bash ranking.sh verificar` prueba escribir en el espejo desde el servicio. Si no puede, revisá que la carpeta
  exista y esté sincronizada en OneDrive, y mirá `bash ranking.sh logs`.

### Red de la empresa (proxy y certificados)

`ranking.sh` reconoce los errores típicos de una red corporativa y te dice cuál de estos pasos hace falta:

- **Error de certificado (`x509`, `certificate`, `SSL`).** El proxy de la empresa revisa el HTTPS. Corré
  `bash ranking.sh certificados`. Copia los certificados raíz de Windows (sin permisos de administrador) a Ubuntu, a
  Docker y a la imagen del sistema. Después volvé a correr el paso que falló.
- **No hay salida a internet (`timeout`, `no such host`).** Si en la empresa se usa un proxy, ponelo en
  `~/.bashrc` (`export HTTPS_PROXY=http://proxy:puerto HTTP_PROXY=http://proxy:puerto`) y abrí una terminal nueva.
  Para que Docker también baje imágenes por el proxy:
  ```bash
  sudo mkdir -p /etc/docker
  echo '{ "proxies": { "http-proxy": "http://proxy:puerto", "https-proxy": "http://proxy:puerto", "no-proxy": "localhost,127.0.0.1" } }' | sudo tee /etc/docker/daemon.json
  sudo service docker restart
  ```
  Si `/etc/docker/daemon.json` ya existía, agregale la parte `"proxies"` en lugar de reemplazarlo.
- **Docker Hub limitado o bloqueado.** No hay que hacer nada: usa solo los espejos públicos. Si la empresa tiene su
  propio espejo, ponelo en `IMAGEN_POSTGRES` e `IMAGEN_PYTHON` dentro de `~/.config/ranking-digital/ranking.env`.

El proxy de la terminal (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`) se guarda en `~/.config/ranking-digital/ranking.env`
la primera vez que se corre cualquier comando con él. Desde ahí lo usan todos los comandos, incluso el lanzador
oculto de Windows, que no lee `~/.bashrc`. Así el sistema no ve una configuración distinta según quién lo abra, y
`abrir` nunca reinicia un sistema que ya funciona.

Al armar la imagen se le pasa ese proxy. Si el proxy es
un programa que corre en la misma PC (por ejemplo en `127.0.0.1`), el armado no llega a él: en ese caso usá la
dirección de la red de la empresa del proxy, no la local.

## Alternativa: Windows sin WSL (doble clic, versión portable)

Para una PC con Windows sin WSL ni Docker. Usa la misma base y el mismo programa, con PostgreSQL y Python portables.

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
   - una contraseña nueva para cada usuario, porque Supabase no entrega las contraseñas.

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
- **Solo funciona mientras la PC está prendida.**
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
- **Seguimiento de envíos** (`db/mejoras/01_seguimiento.sql`): el sistema registra qué obras salieron en cada
  reporte BO y en cada descarga del CSV de la tabla principal. Al descargar se elige **Solo las nuevas** (las que
  nunca salieron en ese tipo de descarga, para el seguimiento semanal) o **Todas** (la revisión completa, por
  ejemplo trimestral). La elección se hace en el cartel que abre cada botón de descarga; la tabla principal muestra la columna **Seguimiento**, y cada descarga queda
  registrada.
- **Historial de cargas** (solo lectura): por YouTube y Spotify (con país), Reportes BackOffice y Reportes Tempo
  Control. Muestra qué hay cargado en la base y de qué archivo salió (`db/mejoras/02_historial.sql`).
- **Charts solo de carga manual:** Spotify y YouTube se suben desde Carga CSV; ya no hay carga automática.
- **Fecha de última carga por país**, arriba en la aplicación.
- **Manual de uso** dentro de la aplicación (`front/manual.html`).
- **Espejo de respaldo y auditoría en OneDrive** (`api/espejo.py`): cada carga y cada respaldo se copian a la carpeta
  compartida, sin que el sistema dependa de ella.

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
| `test_navegador.py` | El front real en Chromium: login, cargar CSV de Spotify y de YouTube, fecha de última carga por país, reporte BO y CSV con solo nuevas o todas, seguimiento, manual, editar, descargar, historial, reporte BO, sesión y auditor en solo lectura. |
| `test_migracion.py` | Exportar e importar comparando fila por fila y archivo por archivo. Los dos modos (API y conexión directa), con Supabase simulado; archivos del historial tomados de carpetas tipo OneDrive; protecciones ante datos existentes, archivos faltantes o alterados. |
| `test_espejo.py` | Espejo de OneDrive: carpeta de cada tipo de carga, nombres que Windows no acepta, que nunca interrumpe una carga, que solo escribe, y la sincronización de todas las cargas. |
| `test_docker_linux.py` | `bash ranking.sh ...` con Docker Engine, como en tu PC: instalar detrás de un proxy que inspecciona HTTPS (primero falla y explica; con los certificados anda), espejos si Docker Hub está limitado, migrar, usuarios, respaldo y restauración, vaciar el historial, empezar de cero, espejo de OneDrive (carga nueva copiada, borrado sin efecto, OneDrive sin permiso), mejoras sobre una base ya instalada, detener, abrir sin reiniciar la API y versión nueva en otra carpeta. |
| `test_portable.py` | La versión portable de Windows con PowerShell real y PostgreSQL 17, como la usa una persona: instalar, migrar, poner contraseñas, administrar usuarios, apagar, volver a abrir y actualizar. |
| `test_componentes_windows.py` | Los componentes reales de Windows (Python y PostgreSQL): verificación por sha256, archivos alterados, descarga caída y que al descomprimir esté todo lo necesario. |
| `test_paquetes_windows.py` | Que los paquetes de Python incluidos alcancen para Windows sin internet (dependencias evaluadas como en Windows). |

## Archivos

```
db/          instalar.sh (Docker/servidor) e instalar.py (Windows portable, sin psql) + SQL (03 y 04 se generan del CSV con generar_esquema.py)
             mejoras/ + mejoras.sh: cambios propios, idempotentes; se aplican en cada arranque, también a una base ya instalada
api/         app.py (API)
front/       index.html (generado de ../frontend_ranking_digital.html con generar_index.py), tempo-client.js, manual.html
admin/       usuarios.py
migracion/   exportar_supabase.py e importar.py
windows/     los scripts que corren los .bat (PowerShell 5.1 o superior) y paquetes/ (Python para Windows, sin internet)
ranking.sh   todo en Linux / WSL2 con Docker Engine (instalar, migrar, abrir, usuarios, respaldo...)
certificados/ certificados raíz de la empresa para la imagen (los deja "ranking.sh certificados"; no se suben)
*.bat        doble clic en Windows: 1_INSTALAR, 2_MIGRAR_DESDE_SUPABASE, ABRIR_SISTEMA, USUARIOS, DETENER
tests/       correr_todo.sh y las pruebas
```

Si se cambia el front original, regenerá `front/index.html` con `python3 front/generar_index.py`. Ese script falla
si en el HTML queda alguna referencia a Supabase o alguna clave.
