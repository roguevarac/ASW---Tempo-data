# Contexto del repo: consultas sobre Tempo (Redshift)

Este repo guarda el modelo de datos de Tempo y las queries construidas sobre él.
**Antes de escribir cualquier query, leé `docs/tempo_schema/CATALOG.md`** (objetos, grano, columnas,
relaciones). El DDL completo está en `docs/tempo_schema/sa00*_create_statements.sql` y el workbook
completo en `docs/tempo_schema/workbook_csv/` (glosario, reglas de calidad, referencias).

## Reglas de trabajo
- Dialecto: **Amazon Redshift**. Validar sintaxis con `sqlglot` (`read='redshift'`) antes de entregar.
- El usuario **no tiene permiso sobre el esquema `edw`**. Usar solo vistas/tablas `dp_*`
  (`dp_song_metadata`, `dp_deal_metadata`, `dp_deal_financials`, `dp_statement_lines`).
  Las definiciones de esas vistas mencionan `edw.*`, pero eso es solo documentación de linaje.
- No hay acceso a la base desde acá: las queries no se pueden ejecutar. Decirlo siempre y dar casos de validación.
- **Rendimiento en Redshift:** una CTE se recalcula cada vez que se la nombra. No nombrar varias veces una CTE que lee
  una vista pesada (`song_v`, `contract_v`, `song_share_detail_mv`). Para reportes con varias fuentes, leer cada
  fuente una vez, filtrada, en tablas `TEMP` y trabajar sobre ellas (patrón de la v6). Nunca leer `contract_v` sin filtro.
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
- `MIN/MAX` de vencimientos ignoran NULL: contar líneas sin vencimiento por separado antes de decir "todos vencidos".

## Queries existentes
- `reporte_cwr/reporte_cwr_x_territorio_v6.sql`: reporte CWR por obra y país (AR, CL, PE, UY, CO). Script con tablas
  temporales; las obras se cargan en el `INSERT INTO cwr_ids`. Ver `reporte_cwr/README.md`.
  Antes de entregar un cambio: `python3 reporte_cwr/tests/test_reporte.py` (DuckDB + sqlglot, necesita `pip install duckdb sqlglot`).
  Agregar a ese test un caso por cada conflicto nuevo que aparezca con el front.
