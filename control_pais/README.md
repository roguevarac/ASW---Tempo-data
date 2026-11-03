# Obras controladas en un país (todo el catálogo)

`obras_controladas_pais_v1.sql`: una fila por obra controlada por SMP en un país (hoy **CHILE**), sin lista de obras.
`unload_obras_controladas_pais_v1.sql`: la misma query dentro de un `UNLOAD` a
`s3://dw-export-prod/7000042560/obras_controladas_pais_000.csv`. Se genera con
`python3 control_pais/tools/generar_unload.py`; nunca editarlo a mano.

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
`song_share_detail_mv` 1 (filtrada a obras con línea que cubre el país), `contract_v` 1 (filtrada),
`identifiers_iswc_v` 1 (filtrada), `contract_territories` 4 (tabla).

## Prueba
`python3 control_pais/tests/test_control_pais.py`: usa los datos de la prueba de la v8 (con Baba O'Riley real) y compara
obra por obra contra la v8 en Chile; también corre el UNLOAD des-escapado.
