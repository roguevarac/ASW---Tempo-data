# Editoriales con control SMP por obra

`editoriales_controladas_v1.sql`: una fila por obra + editorial con control **Yes** en Tempo
(`song_share_detail_mv.smp_controlled_ind = 'Y'`). Las obras se leen de `public.rankingdigital_song_id` (columna `song_id`).

Estados: `CONTROLADA`, `SIN EDITORIAL CONTROLADA` (tiene participaciones, ninguna Yes) y `SIN DATOS` (no está en la MV:
no es song_type 1 / secuencia 0, o un writer sin sociedad la saca de la MV).

Columnas: Tempo ID, título, estado, publisher_id, editorial, capacidad (OP/SE/AM...), writers que representa, contratos
asociados, cantidad de grupos IP, detalle `GRUPO: P x / M y / S z` y mínimo/máximo de perf, mech y sync entre grupos.
Los porcentajes son `publisher_*_pc` de la editorial sumados entre sus writers dentro de cada grupo IP; no se suman
grupos entre sí ni porcentajes `writer_*`.

Solo usa `dp_song_metadata.song_share_detail_mv` (una lectura). Prueba: `python3 editoriales_control/tests/test_editoriales.py`.
