# Notas técnicas: Auditor de Rankings Digitales

Este repo contiene solo el sistema Auditor de Rankings Digitales (`sistema_ranking/`) y lo que hace falta para generarlo
(`frontend_ranking_digital.html` y `migracion_supabase/`).

## Reglas de información
- **Nunca subir datos ni documentos de la empresa:** nada de exportaciones de Tempo, statements, montos, documentación
  interna, cuentas de AWS de la empresa, roles, buckets, números de empleado, IPs ni direcciones de servidores.
- Las queries sobre Tempo/Redshift no van en este repo.
- Nada de contraseñas, claves, `.env`, `ranking.env`, respaldos (`.dump`, `.tgz`) ni la carpeta `exportacion/`.

## Sistema Ranking Digital (reemplazo de Supabase) — `sistema_ranking/`
- PostgreSQL (17 en la PC; también probado con 16) + API FastAPI propia + el mismo front (`frontend_ranking_digital.html` -> `front/index.html` con
  `front/generar_index.py`; `tempo-client.js` imita supabase-js). Ver `sistema_ranking/README.md`.
- El esquema (`db/03`, `db/04`) se genera del CSV `migracion_supabase/origen/esquema_supabase.csv`; no editarlo a mano.
- Supabase fue solo el entorno de prueba: es una aplicación profesional de uso diario. Las limitaciones heredadas se
  corrigen (tabla en el README, "Uso diario en la empresa"); solo quedan las que el README lista como que se mantienen.
  `anon` no tiene permisos.
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
    (`/mnt/c/Users/<usuario_windows>/OneDrive - .../Backoffice/Charts historicos Youtube` y `Charts historicos_spotify`).
- **Instalación real (21/10/2026, con `INSTALACION_PC.md`):**
  - Usuario de Ubuntu `rguevara`; clon de git en `/home/rguevara/proyectos/ranking` (rama
    `main`). `gh` está autenticado como `roguevarac`.
  - Docker Engine 29.9.1, Compose v5.6.0, Buildx v0.38.0. **Buildx 0.38 / Compose 5.6 rechazan `network: host` en el
    build** (piden `--allow=network.host`): no volver a ponerlo. `test_docker_linux.py` lo controla.
  - Sistema en `http://localhost:8000`. Migrado de Supabase: 2 usuarios, 672 obras, 1.500 registros por territorio y
    4.610 archivos de historial. Tenía YouTube programado `0 12 * * 5` UTC; desde el 21/10/2026 ya no hay carga
    automática.
  - El escritorio de Windows está dentro de OneDrive.
  - En WSL no hay `xdg-open`/`wslview`; para abrir algo en Windows se usa `explorer.exe` o `powershell.exe`.
  - En la instalación falló copiar el respaldo a OneDrive por los espacios de la ruta. Desde ahora `ranking.sh respaldo`
    lo copia solo.
  - Las mejoras se aplican en la PC con `bash ranking.sh actualizar`.
  - **API reiniciándose en bucle (21/10/2026):** cada `docker compose up -d` con otro proxy en el entorno recreaba la
    API. Pasaba con una terminal con proxy y el mantenedor oculto de WSL (sin `.bashrc`, sin proxy).
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
    "Todas" o "Identificadas desde la última descarga" (27/10/2026, reemplazó a "Solo las nuevas"): obras identificadas
    que nunca figuraron identificadas en una descarga de ese tipo (tabla `envio_identificadas`; BO = Tempo ID numérico,
    CSV = cualquier Tempo ID). **Por persona desde el 18/11/2026** (cada una genera el reporte BO para sus países; antes,
    cuando una enviaba, a las demás les quedaba en 0): `envio_identificadas.usuario` (= `envios.created_by`,
    `fn_usuario_envio()`), PK (tipo, usuario, obra); el bloque de 01 repartió lo anterior por persona. Front: "Identificadas
    desde tu último reporte BO" / "desde tu última descarga" y "Tu último …" (envíos propios). `unificar_obras` pasa también esas marcas. Si una tabla apunta a `tracks_master`,
    va en los TRUNCATE (ya está `envio_identificadas`). El usuario **no quiere ver la columna
    "Seguimiento"** (23/10/2026): el registro de envíos sigue y se usa en el cartel de cada descarga.
  - **Mejoras propias de la base:** van en `db/mejoras/*.sql`, idempotentes. `db/mejoras.sh` las aplica:
    - al instalar;
    - en cada arranque del servicio `instalador` de compose;
    - en `instalar.py`.

    Así llegan a la base ya instalada. Nunca editar `db/03`/`db/04` para esto. Si una tabla nueva apunta a
    `tracks_master`, agregarla a los TRUNCATE de `restaurar`, `empezar-de-cero` y `migracion/importar.py`.
  - **Rendimiento (22/10/2026):** con los históricos, abrir tardaba 147 s (fetchAll de a 1.000 filas y filtro en el
    navegador). Las tablas se paginan en la base: `db/mejoras/03_rendimiento.sql` (`fn_master_pagina`,
    `fn_territory_pagina`, `fn_territory_opciones`, `fn_envio_conteo`, `fn_ultimas_cargas` e índices). El front pide
    100 filas (`PAGE_SIZE`) con el total; búsqueda y filtros van al servidor. **Nunca volver a traer una tabla entera
    para mostrarla.** `fn_master_view`/`fn_territory_view` quedan para descargas. `test_rendimiento.py` (al final de
    `correr_todo`, vacía la base) mide los tiempos con volumen real.
  - **Uso diario (22/10/2026, `db/mejoras/04_uso_diario.sql`):**
    - Sesiones en `auth.sesiones`: el token lleva `sid`; la API valida cada pedido con `auth.sesion_valida`
      (inactividad = `SESSION_HOURS`). `/auth/renovar`, `/auth/salir`. Contraseña desde la
      **pantalla de ingreso** (pedido del usuario, 23/10/2026; no dentro de la aplicación): `/auth/clave` (con la actual)
      y `/auth/restablecer` (código de `auth.generar_codigo_clave`, `usuarios.py codigo`, menú 6 de `ranking.sh usuarios`
      y `USUARIOS.bat`; tabla `auth.codigos_clave`). `tempo-client.js` renueva a mitad
      de vigencia. Si una tabla nueva apunta a `auth.users`, agregarla a los TRUNCATE de `restaurar` y `importar.py`
      (hoy `auth.sesiones` y `auth.codigos_clave`).
    - **Ingreso recordado (11/11/2026, pedido del usuario: no volver a escribir la contraseña):** el login es un `<form>`
      con `autocomplete=username/current-password` (el navegador ofrece guardar la contraseña; nunca guardarla en el
      sistema ni en localStorage). Casilla "Mantener la sesión iniciada en esta computadora" (marcada por defecto,
      `rk_recordar`): token con `rec` y 30 días (`RECORDAR_DIAS`), `auth.sesiones.recordar`, inactividad de 30 días;
      sin ella la sesión va a `sessionStorage` y termina al cerrar el navegador.
    - El freno de ingreso cuenta solo intentos fallidos.
    - Cargas: `fn_cargar_archivo` (filas + `csv_uploads` en una transacción; el archivo se guarda antes). El front ya no
      manda tandas de 250. Chart sin semana en el nombre: no se carga (como `importar_charts.py`).
    - Tempo ID: `fn_asignar_tempo_id` (con `p_unificar` tras la confirmación) unifica obras. No usar `fn_set_tempo_id`
      en el front.
    - Descarga por territorio: `fn_territory_exportar` (todos los filtros). Respuestas con gzip.
    - Servicio `respaldo` (`db/respaldo_automatico.sh`, imagen de postgres): diario, `ranking_auto_*` en `RESPALDOS`
      (ranking.sh pasa `RESPALDOS_DIR`), conserva 14 y copia el `.dump` a OneDrive. `RESPALDO_HORAS=0` lo apaga. El
      usuario lo pidió (uso profesional): no es una carga automática de datos.
    - Logs de Docker con tope (`x-registros`).
  - **Panel de control (23/10/2026, `db/mejoras/05_panel.sql`, `/panel/*`, pestaña del front):** solo para
    `panel.acceso` (inicial: `rocio.guevara@sonymusicpub.com`; se cambia por consola: `usuarios.py panel <email> si|no`,
    opción 7 del menú). Secciones: estado, respaldos y OneDrive, usuarios, actividad, integridad, registro del servidor.
    - Nunca dar a la API acceso al socket de Docker: los servicios informan con `panel.latido` y `panel.registrar`
      (espejo.py, respaldo_automatico.sh, mejoras.sh/instalar.py, `registrar_evento` de ranking.sh).
    - "Respaldar ahora" = fila en `panel.solicitudes` que atiende el servicio `respaldo` (bucle cada 10 s).
    - Actividad: cada "Cambio" (agrupado por persona, tabla y minuto) trae `obras` (jsonb, hasta 200), con
      `panel.describir_cambio`: Tempo ID antes → después, "Unificada con …" (HARD_DELETE + `obra_alias`), compilado,
      estado de trabajo y ticket por país. El front lo muestra en "Ver obras" (`<details>`), pedido del 16/11/2026.
    - El esquema `panel` lo crea el superusuario dentro de 05 (`RESET ROLE` / `SET ROLE app_owner`).
    - Restaurar y dar acceso al panel quedan en la consola a propósito.
    - `test_panel.py` (después de `test_uso_diario.py`) y `test_docker_linux.py` lo controlan.
  - **Arranque rápido (24/10/2026):**
    - healthcheck de la base con `start_interval: 1s` y por TCP (`pg_isready -h 127.0.0.1`, 16/11/2026): por socket daba
      "lista" durante el servidor temporal de la primera instalación y el instalador fallaba a veces con "exit 2";
    - `mejoras.sh` saltea si la firma (md5 de `db/mejoras/*.sql`) coincide con `panel.servicios.instalador.detalle.firma`;
    - la API abre el pool sin esperar (`/health` 503 hasta que la base responda);
    - el repaso del espejo espera `ESPEJO_DEMORA` (60 s) y el primer respaldo automático `RESPALDO_DEMORA` (600 s);
    - el `CACHE` de `sw.js` lo escribe `generar_index.py` (firma de BASICOS): la PWA de la PC mostraba la pantalla vieja
      "Ranking Digital está iniciando" porque la caché nunca cambiaba de nombre;
    - `abrir` registra "Arranque del sistema: N s (...)" en `panel.eventos` y el Panel lo muestra. Usar esos datos si
      vuelve a haber quejas de lentitud.
  - **Servidor apagado al abrir (26/10/2026):** la PWA de Edge no puede encender WSL.
    - `acceso-directo` registra `auditor-rankings://` (HKCU -> `lanzar.ps1 -SoloServidor`) y `apagado.html` lo usa.
    - `actualizar` regenera los accesos en WSL siempre.
    - `abrir --mantener` reintenta sin fin (`ESPERA_DOCKER=300`, `sudo -n`) y escribe `arranque.log`.
    - `verificar` avisa si `INICIO_AUTOMATICO` no es S.
  - **Carga de Tempo IDs desde planilla (26/10/2026):** `bash ranking.sh cargar-tempo-ids <archivo>`.
    - `migracion/importar_tempo_ids.py` limpia el texto y `fn_cargar_tempo_ids` (`db/mejoras/06_tempo_ids.sql`) cruza.
    - Claves: `fn_clave_texto`, `fn_claves_artistas`, `fn_clave_titulo_base`.
    - Unifica con `unificar_obras` (04, sin prefijo fn_ para que la API no la publique).
    - Simula, respalda, carga y deja el reporte en `RESPALDOS` y OneDrive.
    - La planilla real del usuario (no está en el repo) tiene 6.619 Tempo ID numéricos y 3.448 "UNCONTROLLED"; las
      tildes aparecen como mayúsculas ("ParEntesis").
    - Cruce ampliado (26/10/2026, pedido "trabajo mayor en identificar obras"): niveles 6 (otra versión, nunca remix),
      7 (título parecido) y 8 (artista parecido), con trigramas propios (`fn_trigramas`, `fn_parecido`, `fn_una_letra`;
      sin pg_trgm) y misma firma de números/remix. Sugerencias para revisar en el reporte. Segunda pasada: las obras
      ya identificadas pasan su Tempo ID a sus otras versiones. La planilla "normalizada v2" trae el Tempo ID en la
      columna A, "Sin artista" y tildes como "FrA¡gil": el importador lo detecta. Medido con la planilla real: 0 errores
      número contra número (harness en el scratchpad, no en el repo).
    - El usuario quiere cargar también los UNCONTROLLED (26/10/2026): `db/mejoras/07_marcadores.sql` deja único solo el
      Tempo ID numérico (índice parcial `uq_tracks_master_tempo_id`) y quita `fk_territory_tempo_id`. Los marcadores
      nunca unifican obras ni pisan un número; con número y marcador para la misma obra, gana el número.
  - **Fusión real, limpieza y valores estándar (27/10/2026):**
    - `unificar_obras` (04) guarda el nombre de la obra que desaparece en `obra_alias`; `fn_upsert_ranking_row`
      (reemplazada en 04) carga ese nombre en la obra que quedó. En obras con alias, `territory_tracks_partes` guarda
      los streams por nombre y `territory_tracks` la suma y el mejor puesto (recargar no suma dos veces). Base para el
      futuro dashboard de streams.
    - `fusionar_obras` elige el Tempo ID (el número gana); con dos números distintos no fusiona.
    - `09_limpieza.sql`: `fn_reparar_texto` (UTF-8 leído como Windows-1252: "Ã¡", "â€¦") dentro de `fn_normalize_text`,
      "…" -> "..."; vuelve a normalizar las obras cargadas y fusiona las que quedan iguales.
    - Tempo ID: solo número o `fn_marcadores_tempo()` (UNCONTROLLED y PENDING ARGENTINA/CHILE/URUGUAY/MIAMI/USA/MEXICO/
      COREA/ESPAÑA); `fn_valor_tempo` en `fn_asignar_tempo_id`, en la carga CSV de Tempo IDs (que además fusiona) y en
      la planilla (VALOR NO VÁLIDO). El front ofrece la lista (`MARCADORES_TEMPO`).
    - Tabla por territorio: País, Track - Artista, Created date, Tempo ID, % Perf/Mech Tempo, BO ID, C/A, % Mech BO,
      Estado, Reclamos, Estado de trabajo, Ticket, Fecha. Ticket y fecha en `territory_seguimiento`
      (`fn_guardar_seguimiento`, fecha DDMMAAAA). Las tablas nuevas que apuntan a obras van en los TRUNCATE.
  - **Todas las obras en todos los países (15/11/2026, pedido del usuario):** en la tabla por territorio cada obra que
    figuró en algún chart (del período Desde/Hasta) aparece en los 8 países del enum, para controlar Tempo y BO en cada
    uno. `fn_territory_pagina` (03) devuelve `chart` ('En chart' si figuró en el chart de ese país en el período, si no
    'No en chart', con `id` null) y `en_chart_de` (países donde figuró, "MX, CL").
    - El usuario **no quiere estados por semana** (16/11/2026: "todas vienen de chart"; se quitó "Estuvo en chart" y la
      columna Chart).
    - Front: `celdaPais` muestra debajo del país solo "No en chart", en letra chica. El usuario **no quiere** que se diga
      de qué chart sale (16/11/2026); `en_chart_de` queda sin uso en el front.
    - Filtro al final, después de Estado de trabajo (pedido del 16/11/2026, en lugar del "Chart: todos/En chart" que no
      le gustó): **Todo / Ranking de origen** (`#origenFilter`, `state.origenFilter` = 'En chart' → `p_chart`): solo las
      filas de los países donde la obra figuró en el chart.
    - La descarga (`fn_territory_exportar`) lleva la columna "Chart".
    - Las obras **UNCONTROLLED no aparecen** en la tabla por territorio (16/11/2026: "es al pedo hasta que tengan
      Tempo ID"); vuelven al recibir un número. Las vacías y PENDING sí aparecen.
  - **Filtros visibles (27/10/2026):** el filtro funcionaba, pero la primera página se veía igual y daba desconfianza.
    Cada cambio de filtro (país, fechas, Limpiar, reclamos, estado de trabajo) pasa por `aplicarFiltro` y abre un
    aviso con los filtros y la cantidad antes/ahora (`#okFiltro`). Línea `#filtroActivo` arriba de la tabla y clase
    `filtro-on` en los campos. Las pruebas que filtran tienen que cerrar el aviso.
  - **Filtros por pestaña:** cada tabla tiene su búsqueda (`searchMaster`, `searchTerritory`) y sus fechas
    (`dateFrom/dateTo`, `dateFromT/dateToT`); cambiar de pestaña no los borra. La tabla por territorio tiene
    "Limpiar" (`#clearFiltersT`) para todos sus filtros. Buscar "-" = sin Tempo ID (`fn_coincide_busqueda`, 03).
  - **Filtro Tempo ID de la tabla principal (11/11/2026):** selector en el encabezado de la columna (Todos / Vacíos /
    Con Tempo ID, `#tempoFilter`), combinable con la búsqueda por artista; reemplaza al guion en la indicación (el guion
    sigue funcionando). `fn_coincide_tempo` y `p_tempo` en `fn_master_pagina`, `fn_master_conteo`, `fn_envio_conteo` y
    `fn_preparar_envio` (las descargas lo respetan, igual que la búsqueda).
  - **Acceso desde otras computadoras (pedido del usuario: "la PWA tiene que poder usarse desde la laptop de cada
    uno"):** `bash ranking.sh compartir` → **Tailscale Funnel** (29/10/2026), servicio `tunel` de compose.
    - Enlace fijo `https://auditor-rankings.<red>.ts.net/`; `--apagar` deja de compartir.
    - Funcionamiento: perfil `compartir`, que `dc()` agrega con `COMPARTIR_ENLACE=1` + `IMAGEN_TUNEL`. Clave nueva a propósito: el mantenedor viejo (en memoria hasta reiniciar) lee `COMPARTIR` y pisaría el estado. Red del equipo, hacia
      `127.0.0.1:PUERTO`. La sesión queda en el volumen `tailscale`, y usa el proxy de la configuración y `certificados/`.
    - Quien abre el enlace no necesita cuenta: lo protege el ingreso del sistema.
    - `compartir`: elige la imagen (Docker Hub, ghcr.io, mirror.gcr.io; Docker Hub dio 429 en las pruebas), abre en el
      navegador el `AuthURL` y después el enlace de habilitación de Funnel (`login.tailscale.com/f/...`), y comprueba.
      Si algo falla y no se compartía antes, queda sin compartir (`fallar_compartir`).
    - Sin red hacia Tailscale: muestra el `Health` y qué pedirle a IT; con `x509`, `certificados`.
    - Estado en el Panel: `relevar_tunel` → `panel.latido_tunel` (`db/mejoras/11_acceso_compartido.sql`). Interpreta
      `tailscale status --json --peers=false` y `tailscale funnel status --json` en la base: Ubuntu no trae jq.
    - Windows: solo `sin-suspension.ps1`, que lanza `lanzar.ps1` si `$Compartir`.
    - **Usuarios con la VPN de la empresa (13/11/2026):** "algunos usuarios no conectan con la VPN". Causa más probable:
      el filtro web o el túnel de la VPN bloquea o corta `*.ts.net`. La solución la aplica IT; el texto del pedido está
      en el README. En el sistema:
      - `tempo-client.js` reintenta las lecturas (GET y RPC de consulta, `LECTURAS`) ante cortes o 502/503/504, con 1,
        2, 4 y 8 s de espera. Tiene un plazo (90 s las lecturas, 300 s los cambios) y emite el evento `rk-conexion`; el
        front muestra `#avisoConexion`.
      - Los cambios nunca se reintentan.
      - `front/conexion.html` prueba la conexión. Está en los BASICOS de `sw.js`, así que abre aunque la red no llegue
        al servidor. Distingue bloqueo, sin respuesta, inestable y descarga cortada, y permite copiar el resultado. Se
        abre desde el ingreso (`#linkConexion`), el aviso y `apagado.html`.
    - **Microsoft Dev Tunnels quedó descartado; no volver a él:**
      - en Docker no guarda la sesión (no hay llavero);
      - desde Windows, a un usuario de la empresa el ingreso con cuenta Microsoft le dio `HTTP ERROR 431` en
        `tunnels.api.visualstudio.com`, y el modo anónimo tampoco lo dejó entrar.

      `retirar_devtunnel`, en `arrancar`, borra el túnel viejo, los archivos de Windows y `TUNEL_ID`. `limpiar_tunel_viejo`
      (en `arrancar` si se comparte) borra un contenedor `tunel` de otra imagen: en la PC quedaba el de Microsoft en Docker
      (27/10), unido a la red de una API ya recreada, y con `--no-recreate` Docker intentaba arrancarlo ("joining network
      namespace of container: No such container"). El volumen viejo `tunel` queda sin uso (Tailscale usa `tailscale`).
    - Descartados también:
      - Cloudflare Tunnel: dominio propio y puerto 7844;
      - ngrok gratuito: advertencia y límites.
    - Pruebas:
      - `test_docker_linux.py` con `tests/tailscale_simulado/` (misma salida que tailscale 1.104);
      - `test_panel.py` (estados);
      - `test_acceso_directo.py` (`sin-suspension.ps1`).
    - La red de esta sesión bloquea Tailscale (403) y el clasificador no deja abrir un Funnel desde acá: el enlace real
      se prueba en la PC.
  - **Tempo ID en la tabla principal:** números y "/"; los valores de la lista se eligen o se completan escribiendo parte
    del nombre (`completarTempoParte`, 16/11/2026: "miam" -> PENDING MIAMI cuando coincide uno solo; al borrar no
    completa; letras que no coinciden no se escriben; al salir sin completar vuelve el valor anterior). También como
    parte de un compilado (`listaTempo` arma "123/" + cada valor). Lista: UNCONTROLLED, UNCONTROLLED DUP y los PENDING
    en orden alfabético (PENDING COLOMBIA agregado el 16/11/2026; `fn_marcadores_tempo` en 04).
  - **Compilados (11/11/2026, `db/mejoras/14_compilados.sql`):** "A / B - Artista" con Tempo ID `123/456` (en la tabla
    principal, `fn_asignar_tempo_id`, o en la carga CSV de Tempo IDs) se separa en una obra por canción
    (`separar_compilado`): usa la obra que ya tenga ese número o ese título y artista, reparte los streams en partes
    iguales (el resto, de a uno, a las primeras) como partes en `territory_tracks_partes` y borra el compilado. Su nombre
    (y sus alias) queda en `compilado_partes` (tabla en 04, va en los TRUNCATE); `fn_upsert_ranking_row` reparte las
    cargas siguientes con ese nombre y nunca recrea la obra. La cantidad de títulos tiene que coincidir con la de IDs.
  - **Los datos de BO y Tempo siguen al Tempo ID (13/11/2026, `db/mejoras/15_reportes_siguen_tempo.sql`):** las filas de
    `territory_bo_report`/`territory_tempo_report`/`territory_control` (únicas por Tempo ID + país) van a la obra que hoy
    tiene su Tempo ID (`trg_reporte_sigue_tempo`, BEFORE, `trg_b0_*` para correr antes del estado de trabajo; el ticket
    del país pasa con los datos de BO). Sin obra quedan `en_espera` (con `deleted_at`, ocultas) hasta que una lo reciba.
    `trg_tracks_master_reportes_tempo` las reubica al cambiar el Tempo ID. Un traslado explícito (`unificar_obras`) no se
    recalcula. Los joins con `territory_bo_report` filtran `deleted_at is null`. `territory_control` ya no se renombra
    con el Tempo ID nuevo de la obra.
  - **UNCONTROLLED DUP (13/11/2026):** opción de la lista de Tempo ID (no se guarda): `prompt` para pegar el Track -
    Artista exacto de la otra obra; `fn_unificar_uncontrolled` (15) unifica con `unificar_obras` y deja una sola,
    UNCONTROLLED, con el nombre pegado. Rechaza si alguna tiene Tempo ID numérico.
  - **La misma obra escrita de otra forma (16/11/2026, `db/mejoras/16_misma_obra.sql`, pedido del usuario):**
    - `fn_normalize_text` (09) quita comillas dobles ('"EMHDM"' = 'EMHDM') y artistas vacíos (", Myke Towers": algunos
      charts traen el primer artista sin nombre). El bloque de 09 renormaliza lo cargado, unifica lo que queda igual y
      pasa las claves de `territory_tracks_partes`/`compilado_partes` (sin sumar dos veces la misma semana).
    - `fn_clave_obra` = título sin "(feat./with/con X)" + conjunto de artistas con los invitados ("Danza Kuduro (feat.
      Lucenzo) - Don Omar" = "Danza Kuduro - Don Omar, Lucenzo"); índice `ix_tracks_master_clave_obra`.
    - `misma_obra`: misma clave, o artista incompleto (`fn_artista_incompleto`) con una sola obra del mismo título cuyos
      artistas lo incluyen. `fn_upsert_ranking_row` (04) llama a `vincular_misma_obra` (SECURITY DEFINER) antes de crear
      una obra: el nombre nuevo queda como alias.
    - El bloque de 16 unifica lo ya cargado (destino: la de Tempo ID numérico o la más antigua; con números distintos no)
      y, si el principal tiene el artista incompleto, pone como principal el alias completo.
    - En las pruebas no correr `mejoras.sh` entero a mitad de camino: `08_perfiles` pasa el auditor a usuario estándar.
  - **Tempo ID duplicado en Tempo (16/11/2026, `db/mejoras/00_tempo_duplicado.sql` y `17_tempo_duplicado.sql`):**
    - "123-456" en la tabla principal o en la carga de Tempo IDs (`asignar_tempo_duplicado`): la obra queda con el
      principal (`tracks_master.tempo_id`) y los duplicados en `tempo_duplicado` (va en los TRUNCATE y en las exclusiones
      de migración). Un solo Tempo ID los quita (`quitar_tempos_duplicados`).
    - `fn_tempo_texto` lo muestra como "123-456": en `fn_master_pagina`, en `fn_envio_obras` y en la búsqueda. El reporte
      BO genera una línea por Tempo ID.
    - `fn_territory_pagina`: una fila por país y Tempo ID; `duplicada`; el estado empieza con DUPLICADA. Los datos de BO y
      Tempo se unen por Tempo ID (`fn_obra_del_tempo` incluye duplicados).
    - Las cargas de reportes (`fn_upsert_bo_report_row`, `fn_upsert_tempo_report_row`, `fn_upsert_control_row`) se
      reemplazan en 17 para aceptar duplicados; son cambios a propósito en `comparar_con_supabase.py`.
    - `territory_seguimiento.tempo_id`: NULL es el principal, con índice único (obra, país, coalesce(tempo_id,'')).
      `fn_guardar_seguimiento(..., p_tempo_id)`.
    - Front: `*dup*` al lado del Tempo ID (`.dup-marca`) y `data-tempo` en ticket y fecha.
  - **Nombre principal al unificar (16/11/2026, pedido del usuario: "a veces una es cover"):** al unificar (Tempo ID
    repetido o UNCONTROLLED DUP), el cartel `elegirNombre` pregunta qué nombre queda; `p_nombre_de_esta` en
    `fn_asignar_tempo_id` y `fn_unificar_uncontrolled`. `poner_nombre_principal` (04) intercambia el nombre de la obra
    con un alias de `obra_alias`. La tabla principal muestra debajo "Unificada: …" (`fn_nombres_unificados`, ids en
    JSON: la API pasa arreglos como jsonb) con "Usar este nombre" (`fn_nombre_principal`).
  - **Enviar reporte BO (16/11/2026, pedido de la usuaria: "linkear FileZilla"):** en lugar de descargar, la API sube el
    reporte a `intranet.backoffice-ms.com` (`api/envio_bo.py`, `POST /bo/enviar`). Detalles:
    - **Conexión:** FTP con TLS explícito si el servidor lo ofrece; si no, FTP simple, como FileZilla. Reusa la sesión
      TLS en los datos. Configuración: `BO_SERVIDOR/BO_PUERTO/BO_MODO/BO_TLS_VERIFICAR`, en compose y en
      `CLAVES_CONFIG`. SFTP no está soportado.
    - **Cifrados antiguos (17/11/2026, caso real):** BO respondió `SSLV3_ALERT_HANDSHAKE_FAILURE`: el servidor no acepta
      los cifrados de Python por defecto (solo ECDHE/DHE, sin SHA1, TLS 1.2+). Se reintenta con `_contexto(compatible)`
      (`DEFAULT:@SECLEVEL=0`, TLS 1.0+); si tampoco, en `auto` FTP simple. El servidor de BO no es de la empresa: los
      mensajes no mencionan la VPN.
    - **Certificado autofirmado (17/11/2026, caso real):** como FileZilla, se fija la huella. `subir(..., huellas)`: si
      falla la verificación, segunda conexión sin verificar cadena que controla la huella tras AUTH (y en los datos)
      **antes de USER/PASS**; si no está aceptada, `CertificadoDesconocido` → 409 `certificado_bo` con `detalle`
      (datos del certificado, `puede_aceptar`). El front muestra `.cert-bo` y "Confiar en este certificado y enviar"
      (`aceptar_certificado` en el cuerpo). Solo un Administrador (`panel.tiene_acceso`) habilitado acepta
      (`aceptar_certificado_bo`, tabla `envio_bo_certificados`, en el TRUNCATE de `restaurar`); queda aunque el envío
      falle. No sugerir `BO_TLS_VERIFICAR=0`.
    - **Carpeta (17/11/2026, caso real: "550 /reporte_bo_carga12...: Permission denied"):** en la carpeta inicial de BO no
      se puede escribir. `subir(..., carpeta)` hace CWD; si CWD o STOR dan 550/553/532/552, `CarpetaSinPermiso` con la
      carpeta actual y sus subcarpetas (`_carpetas`: MLSD o LIST Unix/IIS) → 409 `carpeta_bo`. Front: campo `#boCarpeta`
      (`rk_bo_carpeta` en localStorage) y botones `data-carpeta-bo` que reenvían a esa carpeta. La carpeta de la usuaria en BO es `/20817` (dentro de
      `/`, donde no se puede escribir). **Cada usuario de BO ve una sola carpeta (la de carga) y no tiene que indicarla**
      (pedido del 17/11/2026): `_subir` sin carpeta, ante 550 en la inicial con una sola subcarpeta, carga ahí; el cartel
      no tiene campo de carpeta (`#boCarpeta` solo aparece dentro de la lista, si hay varias o ninguna).
    - **Registro de la conexión:** `_Registro` (mixin de `_FTP`/`_FTPS`) anota comandos y respuestas como FileZilla
      (`PASS ********`); `ErrorEnvio.registro` → `detalle.registro` en los errores de `/bo/enviar` → `#boRegistro` en el
      front. Pedirle ese registro a la usuaria si un envío falla.
    - **Transacción:** `fn_preparar_envio`, armado de líneas (`_lineas_reporte_bo`, igual que `downloadBoReport`),
      subida y `marcar_envio_enviado`. Si la subida falla, rollback: no queda envío ni carga.
    - **Credenciales:** la contraseña de BO nunca se guarda ni se registra. El usuario se recuerda en `localStorage`
      (`rk_bo_usuario`).
    - **Quién puede:** **todas las personas desde el 17/11/2026** (pedido de la usuaria tras probarlo): tabla
      `envio_bo_config` (una fila, `todos`, sembrada una sola vez en 18; sin fila = todas; en el TRUNCATE de `restaurar`);
      `usuarios.py envio-bo todos si|no`. Con `todos = false`, solo `envio_bo_usuarios` (`db/mejoras/18_envio_bo.sql`;
      al comienzo solo rocio.guevara@sonymusicpub.com). Se habilita con `usuarios.py envio-bo` o con la opción 8 de
      `ranking.sh usuarios`. `fn_envio_bo_habilitado` decide el botón "Enviar reporte BO" (las demás personas siguen
      descargando). `envio_bo_usuarios` va en el TRUNCATE de `restaurar` (lo siembra 18).
    - **Registro:** `envios.enviado_a` (01); el Panel lo muestra como "Reporte BO enviado a …".
    - **Pruebas:** `tests/test_envio_bo.py`, con servidores FTP y FTPS locales (pyftpdlib + pyopenssl); la API de
      `correr_todo` apunta a 127.0.0.1:2121. El servidor real no se puede probar desde acá.
  - **Estado de trabajo (28/10/2026, `db/mejoras/10_estado_trabajo.sql`, reemplaza `trg_bo_report_auto_revisar`):**
    problemas RECLAMO ACTIVO (`fn_reclamo_activo`: Reclamos con valor que no sea vacío/No/None/0/N/A/resuelto),
    REVISAR NOT WORK (`bo_status` informado y distinto de WORK) y REVISAR % (ex "REVISAR"); sin problemas, OK BO-Tempo /
    OK - Obra AR/MX. **Una obra con varios problemas los muestra todos** (pedido del usuario): se guardan unidos por
    " / ", pero el usuario **no quiere ver la barra** ni un desplegable en cada fila ("desprolijo"): el front muestra
    una etiqueta por estado en todas las filas (rojo problema, verde OK, azul manual) y el botón "Marcar" abre
    Automático / duplicada / dif de split. La descarga los separa por coma. El filtro (`fn_territory_pagina`) y las opciones separan por " / ".
    `fn_estado_automatico` decide qué se recalcula; los manuales (duplicada, dif de split) no se pisan. En plpgsql usar
    `array_append` (`arreglo || 'texto'` lee el texto como arreglo y la fila falla).
  - **Charts sin saltear semanas (28/10/2026):** `fn_cargar_archivo` no carga un chart más de 10 días posterior a la
    última semana del país en esa plataforma (`fn_semana_faltante`) y avisa "falta cargar la semana del ...". Las
    semanas ya cargadas o anteriores sí cargan. El front ordena los archivos por semana. `cargar-historicos` no pasa por
    ese control (el historial de OneDrive puede tener huecos).
  - **Tickets en bloque (04/11/2026, pedido del usuario: los tickets se mandan por grupo de obras):** con un filtro en la
    tabla por territorio aparece "Cargar ticket": el mismo ticket y fecha a todas las obras filtradas (todas las páginas).
    `fn_ticket_filtrado` (`db/mejoras/12_tickets_masivos.sql`, mismos filtros que `fn_territory_pagina`): `p_aplicar=false`
    cuenta (obras y cuántas ya tienen otro ticket), `true` guarda todo o nada; sin filtros se rechaza. La celda sigue
    editable para una obra sola.
  - **Ticket enviado y pestaña "Tickets enviados" (04/11/2026, `db/mejoras/13_tickets_enviados.sql`):** con ticket, el
    estado de trabajo pasa a TICKET ENVIADO (etiqueta amarilla) mientras la obra tenga problemas o si estaba marcada a
    mano; un reporte nuevo sin problemas la deja en OK; quitar el ticket recalcula (trigger de 10 + `fn_guardar_seguimiento`,
    que se mudó de 04 a 13). Tabla `public.tickets` (quién lo cargó primero y cuándo; va en los TRUNCATE y se excluye
    de la comparación de migración). `fn_tickets_lista` (sale de las obras; `tickets` solo aporta autor y fecha) y
    `fn_ticket_obras` ("Ver obras").
  - **Contador "Identificadas · Sin identificar"** arriba de la tabla principal (`.conteo-id`), no en el paginador.
  - **Dos perfiles (27/10/2026, pedido del usuario):** "Usuario estándar" y "Administrador" (= acceso al Panel de
    control, hoy solo rocio.guevara@sonymusicpub.com). El front muestra el perfil según `panel.acceso`, no el
    `app_role`; no hay selector de rol en el Panel ni rol "auditor" (`db/mejoras/08_perfiles.sql` los pasa a
    usuario_estandar). Sin "Ver eliminados" (nada se elimina desde el sistema). El manual no lleva la tabla de nombres
    de charts ni la rutina trimestral.
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
  - **Descargas (reporte BO y CSV):** la elección "Todas" / "Identificadas desde la última descarga" va en el cartel que se abre al apretar cada
    botón. El usuario no quiere desplegables de seguimiento en la barra ni la columna "Seguimiento".
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
    - Carpeta: "RANKING DIGITAL REGIONAL" de OneDrive. Está en `Latam`, no en `Backoffice`.
    - Principio: la base en Docker es la fuente de verdad. El espejo es solo escritura (nunca se lee ni se borra), y un
      error de copia nunca frena una carga.
    - `api/espejo.py --servicio`: corre en el servicio `espejo` de compose, como root. En la PC real (22/10/2026) la API
      (uid 10001) no podía escribir en `/mnt/c`: drvfs solo deja escribir al dueño (uid 1000) o a root.
      - Al arrancar, copia lo que falte.
      - Después, cada 3 s, copia las filas nuevas de `csv_uploads` (por id). Si el máximo baja (restaurar), repasa
        todo.
      - Solo copia cargas con `updated_rows > 0`.
      - No tiene puertos y monta `archivos` en solo lectura.
      - La API no toca OneDrive.
      - `ranking.sh` usa `herramienta_root` para `espejo` y el LEEME.
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
  - **Carga única de charts históricos** (22/10/2026): `bash ranking.sh cargar-historicos` corre
    `migracion/importar_charts.py` en el contenedor `herramientas`, sobre `/espejo/Spotify Charts` y
    `/espejo/Youtube Charts`.
    - Es un port en Python de la lectura del front (Papa.parse, `canonicalHeader`, `detect*`, `entero`,
      `processRankingCsv`, `finishUpload`). **Si cambia esa lógica del front, cambiarla también ahí.**
      `test_importar_charts.py` compara contra el front real.
    - Diferencias a propósito:
      - país por carpeta;
      - sin semana no carga;
      - la carpeta decide la plataforma si el nombre y los links no lo hacen;
      - saltea filenames ya cargados (importados o con `updated_rows > 0`);
      - guarda en `<fmt>/<PAIS>/importado-onedrive/` con `uploaded_by = 'importación histórica'`.
    - El espejo saltea `/importado-onedrive/`.
  - **Nombre del sistema: "Auditor de Rankings Digitales"** (22/10/2026; antes "Ranking Digital Regional").
    - Se usa en el front, el manifest (short_name "Auditor Rankings"), el manual, las pantallas de inicio, los accesos
      de Windows (que borran los viejos "Ranking Digital") y los mensajes de `ranking.sh`.
    - Los identificadores internos no cambian: `ranking.sh`, compose `ranking-digital`, `ranking.env`,
      `%LOCALAPPDATA%\RankingDigital` y la carpeta de OneDrive "RANKING DIGITAL REGIONAL".
  - `cargar-historicos` corre como root (`herramienta_root`), igual que el espejo, porque OneDrive puede no dejar leer
    a otros usuarios. Lo que guarda queda a nombre del dueño del almacenamiento. `verificar` avisa cuántos charts de
    OneDrive faltan cargar (`charts_pendientes`).
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
- **Servidor en AWS (18/11/2026, cuenta aprobada por sus superiores, región us-east-2):** guía `sistema_ranking/nube/AWS.md`
  (EC2 t3.small Ubuntu 24.04, SSH solo "Mi IP", sin puertos HTTP: el acceso sigue por Tailscale con el mismo enlace).
  - `nube/preparar_servidor.sh`: Docker CE oficial + Compose + Buildx, gh, TZ Buenos Aires, swap 2 GB; idempotente
    (probado en un contenedor ubuntu:24.04: Docker 29.10, Compose v5.8).
  - `ranking.sh retirar [enlace]` (en la PC, con una persona): `tailscale logout` + `apagar_compartir`, respaldo final,
    `dc stop`, `SERVIDOR_REMOTO=<enlace>` e `INICIO_AUTOMATICO=N`, y accesos de Windows con `escritorio/lanzar_remoto.ps1`
    (solo abre el enlace; sin "Apagar" ni inicio automático). Con `SERVIDOR_REMOTO`, el despacho de `ranking.sh` niega
    todo salvo `acceso-directo`, `reactivar`, `retirar` y `abrir` (que solo muestra/abre el enlace). `reactivar` lo deshace.
  - En el servidor no hay OneDrive ni WSL: `instalar`, `compartir` y `verificar` ajustan sus textos con `en_windows`.
    Sin `ESPEJO`, `espejo.py --servicio` queda encendido sin copiar (antes salía y Docker lo reiniciaba sin fin:
    `verificar` daba FALLA); `test_espejo.py` lo controla.
  - Desde acá no hay acceso a la cuenta de AWS ni a la PC: los pasos los hace la usuaria.
  - **Traspaso hecho (17/11/2026):** el sistema corre en una instancia EC2 (usuario `ubuntu`, llave SSH en la PC, IP
    fija). El SSH solo acepta la IP de salida de la VPN; 80 y 443 abiertos. Los datos concretos (cuenta, instancia, IP)
    no van en el repo: los tiene la administradora.
    - **Acceso:** `https://<IP-CON-GUIONES>.sslip.io`, Caddy fuera del compose (`docker run --name caddy --network host`,
      `~/caddy/Caddyfile` → `127.0.0.1:8000`, certificado Let's Encrypt en el volumen `caddy_data`). Tailscale quedó
      apagado (pedido del usuario; **no volver a habilitarlo sin pedido**). `nube/AWS.md`, paso 9. Sin Tailscale, el
      Panel de control muestra como dirección de acceso `location.origin` (si no se abre desde localhost).
    - Repo en el servidor: `/home/ubuntu/proyectos/ranking`. **Actualizar** = desde la PC, con la VPN:
      `ssh -i ~/.ssh/auditor-aws.pem ubuntu@<IP_DEL_SERVIDOR> 'cd ~/proyectos/ranking/sistema_ranking && bash ranking.sh actualizar'`.
- Alternativa sin WSL (Windows portable, `*.bat` + `windows/`): PostgreSQL 17 de npm `@embedded-postgres/windows-x64`
  y Python 3.12 de NuGet en `%LOCALAPPDATA%\RankingDigital`. Usa PowerShell 5.1 (archivos con BOM + CRLF) y los
  paquetes de `windows/paquetes`.

## Reglas para seguir trabajando (código)
- **No subir secretos.** Nada de contraseñas, `.env`, service_role key, anon key ni la carpeta `exportacion/`.
  El `.gitignore` ya los excluye.
- No editar a mano:
  - `sistema_ranking/db/03_esquema.sql` y `04_rls_politicas.sql`: se generan con `db/generar_esquema.py` desde
    `migracion_supabase/origen/esquema_supabase.csv`.
  - `sistema_ranking/front/index.html`: se genera con `front/generar_index.py` desde `frontend_ranking_digital.html`.
- **No cambiar la lógica del front ni las funciones SQL** salvo que el usuario lo pida. Costó mucho armar cada
  función. Los errores heredados de Supabase están listados en el README y se dejaron así a propósito.
- **Antes de dar un cambio por bueno**, correr `sistema_ranking/tests/correr_todo.sh`. Necesita Linux o WSL2 con
  PostgreSQL 16 o 17 (`PGHOST_URL`, por defecto el puerto 54340), y Chromium para la prueba del navegador. Si hay
  PowerShell (`PWSH`), también prueba la versión portable de Windows de punta a punta (`test_portable.py`) y los
  componentes reales de Windows (`test_componentes_windows.py`).
- Si cambian `api/requirements.txt` o las versiones de Python o PostgreSQL de Windows, actualizar
  `sistema_ranking/windows/paquetes` y los sha256 de `windows/comun.ps1`; `test_paquetes_windows.py` dice qué falta.
- Los `.ps1` de `sistema_ranking/windows/` tienen que andar en PowerShell 5.1, que es el que trae Windows:
  - nada de sintaxis de PowerShell 7;
  - los archivos se guardan con BOM y fin de línea CRLF;
  - un comando que muestra algo en pantalla no se llama dentro de una expresión, porque eso esconde lo que
    pregunta.
- `ranking.sh` es bash para Ubuntu. No usa Python del sistema; todo corre en los contenedores. Probarlo con
  `tests/test_docker_linux.py`, que necesita Docker Engine.
- Si una prueba falla, se arregla el código, no la prueba.
