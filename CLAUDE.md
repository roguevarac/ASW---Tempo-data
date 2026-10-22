# Contexto del repo: consultas sobre Tempo (Redshift)

Este repo guarda el modelo de datos de Tempo y las queries construidas sobre él.
**Antes de escribir cualquier query, leé `docs/tempo_schema/CATALOG.md`** (objetos, grano, columnas,
relaciones). El DDL completo está en `docs/tempo_schema/sa00*_create_statements.sql` y el workbook
completo en `docs/tempo_schema/workbook_csv/` (glosario, reglas de calidad, referencias).

## Reglas de trabajo
- Las listas de Tempo ID van en una tabla (`public.rankingdigital_song_id`), no escritas en la query.
- Entorno del usuario (de `docs/redshift/Redshift Query Editor Instructions for Access.docx`): Redshift Query Editor V2,
  conexión serverless `self-service-prod-wg`, base `selfsvcdb`. Usuario SSO
  `AWSReservedSSO_RedshiftQueryEditorV2_78629b54267a226f/7000042560`, GID `7000042560`.
  El editor muestra hasta 100.000 filas o 10 MB; para más, UNLOAD a `s3://dw-export-prod/7000042560/<archivo>` con
  `IAM_ROLE 'arn:aws:iam::991042281579:role/DataWarehouse/RedShift-S3-Unload'`. Los archivos duran 7 días en S3.
- Dialecto: **Amazon Redshift**. Validar sintaxis con `sqlglot` (`read='redshift'`) antes de entregar.
- El usuario **no tiene permiso sobre el esquema `edw`**. Usar solo vistas/tablas `dp_*`
  (`dp_song_metadata`, `dp_deal_metadata`, `dp_deal_financials`, `dp_statement_lines`).
  Las definiciones de esas vistas mencionan `edw.*`, pero eso es solo documentación de linaje.
- No hay acceso a la base desde acá: las queries no se pueden ejecutar. Decirlo siempre y dar casos de validación.
- **Rendimiento en Redshift:** una CTE se recalcula cada vez que se la nombra. No nombrar varias veces una CTE que lee
  una vista pesada (`song_v`, `contract_v`, `song_share_detail_mv`). El usuario quiere **una sola sentencia con un
  solo resultado** (no scripts con tablas TEMP): armar la consulta como una cadena lineal donde cada CTE pesada se
  nombra una vez, y resolver cruces con funciones de ventana sobre un flujo único (patrón de la v7). Medir con
  `python3 reporte_cwr/tools/contar_expansiones.py <archivo.sql>` antes de entregar. Nunca leer `contract_v` sin filtro.
- Redshift: todos los `LISTAGG` de un mismo SELECT deben tener el mismo `WITHIN GROUP (ORDER BY ...)`. No usar
  `LISTAGG(DISTINCT ...)` (no corre en el test con DuckDB); marcar primeras apariciones con `ROW_NUMBER`.
- Respetar el grano. Nunca sumar porcentajes de `writer_*` entre filas de publishers (se repiten por cadena).

## Hechos del modelo que importan (verificados en el DDL)
- `song_share_detail_mv`: una fila por canción + territorio IP + writer + publisher + contrato + nivel de jerarquía.
  Solo incluye obras `song_type_id=1`, `song_sequence_id=0`. Hace JOIN interno a `tempo_society` por writer:
  un writer sin sociedad hace desaparecer la obra de la MV sin error.
- `song_contract_territory_nm` de esa MV es `inclusions || ' ' || exclusions`: **es NULL cuando exclusions es NULL**
  (el caso mayoritario). No usarla; leer `contract_territories` directo.
- `contract_territories` (tabla poblada por `shared.sp_get_all_contract_territories`): una fila por obra+contrato.
  - Solo contratos con rate client + payment option + office group activos (si no, no hay fila).
  - Puede repetir filas por obra+contrato con distinto `contract_nm` (el procedimiento no filtra `prior_version_ind`);
    el territorio es igual en todas. Deduplicar por obra+contrato.
  - Si `inclusions || exclusions` es más largo que la lista de todos los países no excluidos, reemplaza
    `World` por la lista explícita de países y deja `exclusions` NULL. Hay que comparar elemento por elemento.
  - Países con sufijo ` (REG)` y solo países con `gca_territory_ind='Y'`; los nombres de región vienen de `tempo_territory`.
  - Los overrides de la obra ya están aplicados en el texto (ganan sobre el contrato).
- Porcentajes de control por obra: `publisher_*_pc` filtrando `smp_controlled_ind='Y'`, un solo grupo IP por país
  (el que nombra al país; si no, región; si no, mundial).
- **Territorio de control = líneas de control de la obra**, no el "Associated Contract" de la participación.
  `contract_territories` trae una fila por línea de control (contrato con rate client activo) y puede incluir
  contratos que `song_share_detail_mv` no menciona. El grupo IP "All (Other) Contractual Territories" significa
  "los demás territorios contratados". Un país está controlado si el grupo IP aplicable es de SMP y **alguna** línea de
  control de la obra lo cubre. Caso de referencia: Baba O'Riley 2701309 (`reporte_cwr/casos/baba_oriley/`).
- Un contrato puede tener texto de territorio distinto al que sugiere su nombre (1525818 "ex. Philippines" = Asia).
  Confiar en `contract_territories`, no en el nombre.
- Los países se buscan por todas sus formas de escritura (CTE `alias_pais`): Estados Unidos aparece como
  `UNITED STATES` en los textos de contratos y como `USA`, `US`, `U.S.A.`, `US & CANADA` en grupos IP. Agregar alias ahí.
- `MIN/MAX` de vencimientos ignoran NULL: contar líneas sin vencimiento por separado antes de decir "todos vencidos".

## Financials (front "Song Financials")
- Sale de `dp_earnings_lines.earnings_lines_v`: Gross Income = `gross_client_share_of_income_amt`, Affiliate NPS =
  `foreign_nps_am`, Domestic NPS = `gross_nps`, Client Royalty = `gross_royalty_payable`. No hay columna de retención.
- `statement_lines_v.converted_net_am` es lo que llega a la oficina (Domestic NPS + Client Royalty), no el gross.
- Una línea de statement genera varias de ganancia: sumar montos de la línea (`converted_net_am`) una vez por línea.
- Montos en moneda de la oficina que procesó; el front en USD = oficina `United States`. Ver `financials/README.md`.
- Lo recaudado en un país se mide en la oficina de ese país (ej. México: fuente local EMMAC, en MXN). En Estados Unidos
  llega como intercompany ("SMP Mexico") solo la parte de clientes de US, neta de lo que retuvo la afiliada.

## Queries existentes
- `financials/song_financials_el.sql`: Song Financials por obra/fuente/income type para las obras de la tabla.
- `financials/mexico_emmac.sql`: lo generado en México (fuente EMMAC) por obra, en moneda local y USD.
- `reporte_cwr/reporte_cwr_x_territorio_v8.sql`: reporte CWR por obra y país (AR, CL, PE, UY, CO y UNITED STATES). Una sola
  sentencia; las obras se leen de `public.rankingdigital_song_id` (columna `song_id`). Ver `reporte_cwr/README.md`.
- `reporte_cwr/unload_reporte_cwr_v8.sql`: la v8 dentro de un `UNLOAD` a S3 para resultados grandes. Se genera con
  `python3 reporte_cwr/tools/generar_unload.py`; nunca editarlo a mano. Deja `reporte_cwr_v8_000.csv` en la carpeta
  del GID.
  Antes de entregar un cambio: `python3 reporte_cwr/tests/test_reporte.py` (DuckDB + sqlglot, necesita `pip install duckdb sqlglot`).
  Agregar a ese test un caso por cada conflicto nuevo que aparezca con el front. El test agrega la opción 'g' a
  `REGEXP_REPLACE` al pasar a DuckDB (Redshift reemplaza todas las coincidencias, DuckDB solo la primera).

## Sistema Ranking Digital (reemplazo de Supabase) — `sistema_ranking/`
- PostgreSQL (17 en la PC; también probado con 16) + API FastAPI propia + el mismo front (`frontend_ranking_digital.html` -> `front/index.html` con
  `front/generar_index.py`; `tempo-client.js` imita supabase-js). Ver `sistema_ranking/README.md`.
- El esquema (`db/03`, `db/04`) se genera del CSV `migracion_supabase/origen/esquema_supabase.csv`; no editarlo a mano.
- Comportamientos heredados de Supabase se mantienen a propósito (listados en el README); `anon` no tiene permisos.
- Antes de entregar un cambio: `sistema_ranking/tests/correr_todo.sh` (Postgres local: `PGHOST_URL`, por defecto el
  puerto 54340; con PowerShell también prueba la versión portable de Windows de punta a punta).
- **Entorno real del usuario:** WSL2 Ubuntu 26.04 + Docker Engine dentro de Ubuntu (`docker compose`, sin Docker
  Desktop, sin admin en Windows). Trabaja desde bash, en `~/proyectos`, y abre `http://localhost:PUERTO` en el
  navegador de Windows. Red corporativa con posible proxy.
  - Todo pasa por `sistema_ranking/ranking.sh` (`instalar`, `migrar`, `abrir`, `detener`, `usuarios`, `respaldo`,
    `restaurar`, `certificados`). Las instrucciones son para bash/apt, sin pasos de Windows ni de Docker Desktop.
  - La base es PostgreSQL 17, con locale builtin C.UTF-8 y codificación UTF8, la misma semántica que Supabase.
  - La configuración está en `~/.config/ranking-digital/ranking.env`, el nombre de compose es fijo
    (`ranking-digital`) y la API solo escucha en 127.0.0.1.
  - Si Docker Hub falla, se usan los espejos `mirror.gcr.io` y `public.ecr.aws`. Los certificados de la empresa van
    en `certificados/`.
  - La migración va por la API de Supabase (HTTPS). El historial de archivos se toma de OneDrive
    (`/mnt/c/Users/7000042560/OneDrive - Sony/.../Backoffice/Charts historicos Youtube` y `Charts historicos_spotify`).
- **Instalación real (21/10/2026, hecha por Antigravity con `ANTIGRAVITY.md`; commit 4899a81):**
  - Usuario de Ubuntu `rguevara`; clon de git en `/home/rguevara/proyectos/ranking` (rama
    `claude/funny-bell-bbdz84`). `gh` está autenticado como `roguevarac`.
  - Docker Engine 29.9.1, Compose v5.6.0, Buildx v0.38.0. **Buildx 0.38 / Compose 5.6 rechazan `network: host` en el
    build** (piden `--allow=network.host`): no volver a ponerlo. `test_docker_linux.py` lo controla.
  - Sistema en `http://localhost:8000`. Migrado de Supabase: 2 usuarios, 672 obras, 1.500 registros por territorio y
    4.610 archivos de historial. Tenía YouTube programado `0 12 * * 5` UTC; desde el 21/10/2026 ya no hay carga
    automática.
  - El escritorio de Windows está en OneDrive: `C:\Users\7000042560\OneDrive - Sony\Desktop`.
  - En WSL no hay `xdg-open`/`wslview`; para abrir algo en Windows se usa `explorer.exe` o `powershell.exe`.
  - Al agente le falló copiar el respaldo a OneDrive por los espacios de la ruta. Desde ahora `ranking.sh respaldo`
    lo copia solo.
  - Las mejoras se aplican en la PC con `bash ranking.sh actualizar`, que puede correr Antigravity.
  - **API reiniciándose en bucle (21/10/2026):** cada `docker compose up -d` con otro proxy en el entorno recreaba la
    API. Pasaba con la terminal de Antigravity (con proxy) y el mantenedor oculto de WSL (sin `.bashrc`, sin proxy).
    Arreglo:
    - el proxy se guarda en `ranking.env` (`guardar_proxy`) y `dc()` ignora el de la terminal;
    - `abrir` usa `up -d --no-recreate`, salvo que recién haya cambiado el proxy.
    `test_docker_linux.py` lo controla. No volver a pasar variables de la terminal al compose sin guardarlas.
- **Cambios del usuario (21/10/2026):**
  - **Sin carga automática de YouTube** (a futuro podía romperse). Los charts de Spotify y YouTube se cargan a mano desde
    "Carga CSV". Se borraron `api/youtube_job.py`, `YOUTUBE_CRON` y croniter; `ranking.sh` borra el horario viejo de
    `ranking.env`. No volver a agregar tareas programadas sin que el usuario lo pida.
  - **Fecha de última carga por país:** en el front (`renderLastLoads`) se toma el país del filtro de la pestaña (en
    Carga CSV / Historial, el último elegido). Sin país muestra "Seleccionar país para ver fecha de última carga".
  - El pie del front ya no dice "Supabase · PostgreSQL 15 · RLS activo".
  - El usuario quiere empezar el historial de cero: `bash ranking.sh vaciar-historial` (respaldo previo, confirmación de
    una persona, no corre con `--automatico`). Borra `storage.objects` del bucket `csv-uploads`, `csv_uploads` y los
    archivos; no toca obras, territorios ni usuarios.
  - **Empezar de cero:** `bash ranking.sh empezar-de-cero` vacía obras, territorios, reportes, auditoría, envíos e
    historial (respaldo previo, confirmación de una persona). Quedan los usuarios y `bo_export_counter`.
  - **Seguimiento de envíos** (`db/mejoras/01_seguimiento.sql`: tablas `envios` y `envio_obras`, `fn_preparar_envio`,
    `fn_envio_obras`, `fn_envios_por_obra`). El reporte BO y el CSV de la tabla principal se descargan como
    "Solo las nuevas" (nunca salieron en ese tipo) o "Todas" (revisión trimestral). La tabla principal tiene la columna
    y el filtro "Seguimiento".
  - **Mejoras propias de la base:** van en `db/mejoras/*.sql`, idempotentes. `db/mejoras.sh` las aplica:
    - al instalar;
    - en cada arranque del servicio `instalador` de compose;
    - en `instalar.py`.

    Así llegan a la base ya instalada. Nunca editar `db/03`/`db/04` para esto. Si una tabla nueva apunta a
    `tracks_master`, agregarla a los TRUNCATE de `restaurar`, `empezar-de-cero` y `migracion/importar.py`.
  - **Manual de uso:** `front/manual.html` (enlace "Manual de uso" arriba a la derecha).
    **Regla fija (pedido del usuario): toda mejora o agregado que cambie lo que ve o hace el usuario se entrega con el
    manual actualizado en el mismo commit, sin que lo pida.** Solo si la información le sirve a quien usa el sistema;
    lo interno (back, cruces, scripts) no va. Si una prueba del navegador cubre la función, chequear también el manual.
  - **Redacción de los textos para el usuario** (front, manual, pantallas de inicio). Regla fija, pedido del usuario el
    22/10/2026:
    - Registro intermedio: voseo, pero con vocabulario formal y preciso. Ejemplo: "Charts: subí los archivos .csv con
      el nombre de descarga; el territorio y la semana del título se utilizan para interpretar el archivo".
    - Sin giros coloquiales ("acá", "de ahí salen", "mirá", "ojo", "podés seguir mirando").
    - Nada redundante con lo que la pantalla ya muestra. Por ejemplo, no poner "Solo lectura" en una sección sin
      acciones: las dudas se resuelven en el manual.
    - Mensajes breves que indiquen qué hacer o qué representa la información.
    - Términos: "territorio/país", "Reporte BackOffice", "Reporte Tempo Control", "seleccionar", "cargar".
  - **Descargas (reporte BO y CSV):** la elección "Solo las nuevas" / "Todas" va en el cartel que se abre al apretar cada
    botón. El usuario no quiere desplegables de seguimiento en la barra; solo queda la columna "Seguimiento".
  - **Nombres de charts que se deben leer** (país, semana y plataforma salen del nombre; `test_navegador.py` los prueba):
    - `regional-ar-weekly-2021-01-07.csv`
    - `regional-py-weekly-2023-12-14 -ult.csv`
    - `youtube-py-weekly-2023-03-09.csv`
    - `youtube-TopSongs-ar-weekly-2021-01-07.csv`
    - `youtube-charts-top-songs-py-weekly-20230309[.csv]`

    También se leen:
    - el formato viejo de Spotify (aviso arriba; Position/Artist/URL);
    - el oficial de YouTube (Artist Names/Periods on Chart/Growth);
    - números con separador de miles (`entero()` en el front).
  - **Historial de cargas** (ex "Historial CSV", 22/10/2026). Es solo lectura: sin descargar ni borrar.
    - Pestañas YouTube y Spotify, con chips de país: con "Todos" muestra un resumen por país; con un país, cada semana
      con su archivo.
    - Pestañas Reportes BackOffice y Reportes Tempo Control. Tempo Control incluye las cargas de Tempo IDs.
    - Datos: `fn_historial_charts`, `fn_historial_reportes` y `fn_nombres_usuarios` (`db/mejoras/02_historial.sql`),
      más todas las filas de `csv_uploads`.
    - Las descargas (`bo_generado`, `csv_principal`) no se muestran.
    - Los archivos nuevos se guardan en `formato/PAIS/fecha/`, y el historial lee el país de esa carpeta.
  - **Carga CSV:** sin lista de columnas. Nombra los tipos (Spotify, YouTube, Reporte BackOffice, Reporte Tempo Control,
    Tempo IDs), da tres indicaciones y muestra el avance archivo por archivo: barra, estado, tipo, país y semana.
  - **Espejo de respaldo y auditoría en OneDrive** (22/10/2026):
    - Carpeta: `C:\Users\7000042560\OneDrive - Sony\SMP-Administration Argentina - Documents\Latam\RANKING DIGITAL
      REGIONAL`. Está en `Latam`, no en `Backoffice`.
    - Principio: la base en Docker es la fuente de verdad. El espejo es solo escritura (nunca se lee ni se borra), y un
      error de copia nunca frena una carga.
    - `api/espejo.py`: la API copia cada carga cuando se registra en `csv_uploads` (POST `/rest/csv_uploads`, en un
      hilo aparte). Solo copia cargas con `updated_rows > 0`.
      - Destinos: `Spotify Charts/<pais>/`, `Youtube Charts/<pais>/`, `Reportes BackOffice/<pais>/`,
        `Reportes Tempo Control/` (con `Tempo IDs/`).
      - También escribe el LEEME.
    - Compose monta `${ESPEJO_DIR:-espejo_apagado}:/espejo` y pasa `ESPEJO: ${ESPEJO_DIR:+/espejo}`.
    - `ranking.sh`:
      - `configurar_espejo` guarda `ESPEJO_DIR`;
      - `respaldo` copia el `.dump` y el `.tgz` a `respaldo_documentacion_sistema/respaldos` y la documentación a
        `respaldo_documentacion_sistema/docs`;
      - `espejo` copia lo que falte; `actualizar` también lo hace.
    - Pruebas: `test_espejo.py` y `test_docker_linux.py` (con `RK_ESPEJO`).
    - La versión portable de Windows no tiene espejo.
- **Como aplicación (PWA, desde el 21/10/2026):** el front es instalable (`front/manifest.webmanifest`, `front/sw.js`,
  `front/apagado.html`, `front/iconos/`); los inyecta `front/generar_index.py`, y los íconos se generan con
  `front/generar_iconos.py`.
  - El service worker **nunca cachea la API**: solo la pantalla de apagado y los íconos.
  - En Windows, `ranking.sh acceso-directo` genera desde `escritorio/` el lanzador
    `%LOCALAPPDATA%\RankingDigital\lanzar.ps1` y la pantalla `iniciando.html`. El lanzador:
    - arranca Docker como root de WSL;
    - deja un "mantenedor" oculto (`wsl.exe ... ranking.sh abrir --mantener --sin-navegador`) que mantiene Ubuntu
      prendido;
    - abre la ventana con `msedge.exe --app=URL`;
    - con `-SoloServidor`, se usa en el inicio de Windows;
    - con `-Apagar`, apaga todo.
  - Accesos: escritorio, menú Inicio (abrir y apagar) e inicio de Windows. `actualizar` los regenera si existe
    `ACCESO_DIRECTO=1` en la configuración.
  - Se descartó la app nativa (.exe con Electron o Tauri): sin firma, la bloquearía la empresa.
- Alternativa sin WSL (Windows portable, `*.bat` + `windows/`): PostgreSQL 17 de npm `@embedded-postgres/windows-x64`
  y Python 3.12 de NuGet en `%LOCALAPPDATA%\RankingDigital`. Usa PowerShell 5.1 (archivos con BOM + CRLF) y los
  paquetes de `windows/paquetes`.
