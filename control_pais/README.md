# Obras controladas en un país (todo el catálogo)

`obras_controladas_pais_v1.sql`: una fila por obra controlada por SMP en un país (hoy **CHILE**), sin lista de obras.
`unload_obras_controladas_pais_v1.sql`: la misma query dentro de un `UNLOAD` a
`s3://dw-export-prod/7000042560/obras_controladas_pais_000.csv`. Se genera con
`python3 control_pais/tools/generar_unload.py`; nunca editarlo a mano.

## Tandas (catálogo completo)
El conteo del 11/11/2026 dio ~6,8 millones de obras con línea de control y ~5,8 millones con control Yes: en una
sola pasada la query no termina. `unload_obras_controladas_pais_tandas.sql` tiene un `UNLOAD` por cada rango de
Tempo ID de `rangos_tandas.txt` (10 tramos de 1.000.000; el último toma el resto) y deja
`obras_controladas_pais_tNN_000.csv` por tanda. Cada lectura se filtra por el rango (líneas `TANDA` de la query).
Si una tanda no termina, partir su rango en `rangos_tandas.txt` y regenerar. La prueba verifica que la unión de las
tandas dé lo mismo que la corrida completa.

## Procedimiento (recomendado para el catálogo completo)
El usuario tiene permiso CREATE en `public` (`has_schema_privilege` = true, 11/11/2026).
`procedimiento_obras_controladas_pais.sql` (generado; no editar a mano) crea `public.obras_controladas_pais_resultado`,
`public.obras_controladas_pais_log` y `public.sp_obras_controladas_pais(tamaño, desde)`: recorre rangos de Tempo ID
hasta el máximo de `contract_territories`, inserta cada tanda con la misma query (EXECUTE) y hace COMMIT por tanda.
`desde = 0` vacía y empieza de cero; otro valor retoma sin vaciar. Después, un `UNLOAD` simple de la tabla deja un CSV.
La prueba simula el EXECUTE de cada tanda en DuckDB y compara con la corrida completa.

## Reporte CWR v8 para el país, sobre esas obras
`reporte_cwr_pais_v1.sql` y `procedimiento_reporte_cwr_pais.sql` se generan desde
`reporte_cwr/reporte_cwr_x_territorio_v8.sql` (misma lógica y mismas 28 columnas; un solo país, `PAIS_CWR` en el
generador). Las obras salen de `public.obras_controladas_pais_resultado`, por rango de Tempo ID.
`CALL public.sp_reporte_cwr_pais(500000, 0)` deja una fila por obra en `public.reporte_cwr_pais_resultado`.
La prueba verifica que da fila por fila lo mismo que la v8 filtrada a Chile, y que las tandas dan lo mismo.

## País como parámetro
Los dos procedimientos reciben el país: `CALL public.sp_obras_controladas_pais('ARGENTINA', 500000, 0)` y después
`CALL public.sp_reporte_cwr_pais('ARGENTINA', 500000, 0)`. Cada país queda en las mismas tablas con su valor en la
columna `pais`; `desde = 0` borra solo ese país. Las formas de escritura y regiones de cada país están en
`public.control_pais_claves` (la crean los archivos de procedimiento desde `CLAVES` del generador). Países: ARGENTINA,
CHILE, PERU, URUGUAY, COLOMBIA, BRASIL (BRAZIL/BRASIL) y UNITED STATES.

## Regla (la misma de la v8 del reporte CWR)
- Un solo grupo IP por obra: el que nombra al país; si no, el que nombra una región que lo incluye; si no, el mundial.
  Un grupo que excluye al país ("WORLD EX CHILE") no cuenta.
- Controlada = ese grupo tiene alguna participación con control Yes **y** alguna línea de control de la obra
  (`contract_territories`) cubre el país, comparando Include / Exclude elemento por elemento.

## Cambiar de país
Solo el bloque `claves`: filas `P` (formas de escritura del país; la primera es el nombre del reporte) y `R` (regiones
que lo contienen). Después regenerar el UNLOAD.

## Diferencias con la v8
- Exige una línea que cubra el país: no salen las participaciones sin contrato ni las que tomaban el texto de
  territorio de otra obra (la v8 las daba por controladas con alerta).
- No lee `song_v` (vista pesada de todo el catálogo): no marca NOP; el título sale de la MV.
- Obras fuera de `song_share_detail_mv` no aparecen.

## Columnas
song_id, song_title_tx, iswc, pais, performance/mechanical/sync_pc_total, publishers, cantidad_publishers,
contratos_asociados, grupo_ip_usado, como_se_eligio_grupo, lineas_que_cubren_el_pais (con vencimiento),
cantidad_lineas, contrato_venc_mas_proximo, contrato_venc_mas_lejano, estado_contrato, alertas.

## Lecturas
`song_share_detail_mv` 1, `contract_v` 1, `identifiers_iswc_v` 1, `contract_territories` 3 (la normalización de
textos 2), todas filtradas por el rango de la tanda.

## Prueba
`python3 control_pais/tests/test_control_pais.py`: usa los datos de la prueba de la v8 (con Baba O'Riley real) y compara
obra por obra contra la v8 en Chile; también corre el UNLOAD des-escapado.
