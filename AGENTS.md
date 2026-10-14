# Traspaso para cualquier agente (Antigravity, Gemini, Copilot, etc.)

Leé este archivo antes de tocar nada. Las reglas completas y los hechos verificados están en `CLAUDE.md`.
Aunque el nombre diga Claude, ese archivo vale para cualquier agente.

## Qué hay en el repo
1. **Queries de Tempo (Amazon Redshift)**: `reporte_cwr/`, `financials/` y `docs/tempo_schema/`. Las reglas están
   en `CLAUDE.md`. Las queries no se pueden correr desde acá; las corre el usuario en Redshift Query Editor V2.
2. **Sistema Ranking Digital**: `sistema_ranking/`. Reemplaza el proyecto de Supabase: base de datos, login, bucket
   de archivos, Edge Function de YouTube y front, todo en un servidor propio. Ver `sistema_ranking/README.md`.

## Estado del Sistema Ranking Digital
Terminado y probado con `sistema_ranking/tests/correr_todo.sh`. Las 5 pruebas dan OK: estructura igual a Supabase,
API, tarea de YouTube, front en el navegador y migración.

Falta lo que solo puede hacer el usuario, en este orden:
1. En su PC (Windows): `pip install "psycopg[binary]" httpx` y luego
   `python sistema_ranking/migracion/exportar_supabase.py`. El script pide la conexión y la service_role key de
   Supabase. Crea la carpeta `exportacion/`.
2. En el servidor: `cd sistema_ranking`, `cp .env.example .env` (completar las claves) y `docker compose up -d`.
3. Importar con el comando de la sección "Migrar los datos" del README.
4. Copiar el horario de `exportacion/cron_jobs.csv` a `YOUTUBE_CRON` en `.env` y reiniciar con
   `docker compose up -d`.
5. Probar con los usuarios reales y, si todo está bien, apagar Supabase.

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
  PostgreSQL 16 en el puerto 54340, y Chromium para la prueba del navegador. Si una prueba falla, se arregla el
  código, no la prueba.
- Para las queries de Redshift, `python3 reporte_cwr/tests/test_reporte.py`.
