# Traspaso para cualquier agente (Antigravity, Gemini, Copilot, etc.)

Leé este archivo antes de tocar nada. Las reglas completas y los hechos verificados están en `CLAUDE.md`.
Aunque el nombre diga Claude, ese archivo vale para cualquier agente.

> **Antigravity (o cualquier agente en la PC del usuario):** para instalar, verificar o actualizar Ranking Digital,
> seguí **`ANTIGRAVITY.md`** paso a paso. Las mejoras las hace y las prueba Claude y llegan por GitHub; en la PC solo
> se aplican con `bash ranking.sh actualizar`.

## Qué hay en el repo
1. **Queries de Tempo (Amazon Redshift)**: `reporte_cwr/`, `financials/` y `docs/tempo_schema/`. Las reglas están
   en `CLAUDE.md`. Las queries no se pueden correr desde acá; las corre el usuario en Redshift Query Editor V2.
2. **Sistema Ranking Digital**: `sistema_ranking/`. Reemplaza el proyecto de Supabase: base de datos, login, bucket
   de archivos, Edge Function de YouTube y front, todo en un servidor propio. Ver `sistema_ranking/README.md`.

## Estado del Sistema Ranking Digital
Terminado y probado con `sistema_ranking/tests/correr_todo.sh`. Todas las pruebas dan OK: estructura igual a Supabase,
API, tarea de YouTube, front en el navegador, migración y versión portable de Windows (también con PostgreSQL 17).

**Entorno del usuario:** Windows corporativo sin admin, con WSL2 Ubuntu 26.04 y Docker Engine dentro de Ubuntu
(`docker compose` v5, sin Docker Desktop). Todo desde bash, proyectos en `~/proyectos`, navegador de Windows a
`http://localhost:PUERTO`, red corporativa con posible proxy. Instrucciones: sección "En tu PC: Ubuntu (WSL2) +
Docker Engine" de `sistema_ranking/README.md`. Todo pasa por `sistema_ranking/ranking.sh`:
1. `bash ranking.sh instalar` y después `bash ranking.sh migrar`.
   - La migración va por HTTPS, con la service_role key, que se pide en pantalla y no se guarda.
   - Los archivos del historial se toman de OneDrive (`/mnt/c/Users/...`) y, si falta alguno, se baja del bucket.
   - Al final pide contraseñas nuevas y el horario de YouTube.
2. Probar con los usuarios y, si todo está bien, apagar Supabase y rotar sus claves.

Uso diario: `bash ranking.sh abrir | detener | usuarios | respaldo | restaurar | logs | estado | verificar | actualizar`. La configuración
está en `~/.config/ranking-digital/ranking.env`, fuera del proyecto. El nombre del proyecto de compose es fijo
(`ranking-digital`), así que una versión nueva en otra carpeta usa los mismos datos.

Red corporativa:
- `ranking.sh certificados` exporta los certificados raíz de Windows a Ubuntu, a Docker y a la imagen.
- Si Docker Hub falla, se usan los espejos `mirror.gcr.io` y `public.ecr.aws`.

La versión portable de Windows (`*.bat`, `windows/`) queda como alternativa para una PC sin WSL.

## Reglas para seguir trabajando
- **No subir secretos.** Nada de contraseñas, `.env`, service_role key, anon key ni la carpeta `exportacion/`.
  El `.gitignore` ya los excluye.
- No editar a mano:
  - `sistema_ranking/db/03_esquema.sql` y `04_rls_politicas.sql`: se generan con `db/generar_esquema.py` desde
    `migracion_supabase/origen/esquema_supabase.csv`.
  - `sistema_ranking/front/index.html`: se genera con `front/generar_index.py` desde `frontend_ranking_digital.html`.
  - `reporte_cwr/unload_reporte_cwr_v8.sql`: se genera con `reporte_cwr/tools/generar_unload.py`.
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
- Para las queries de Redshift, `python3 reporte_cwr/tests/test_reporte.py`.
