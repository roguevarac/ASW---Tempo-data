# Editoriales con control SMP por obra

`editoriales_controladas_v1.sql`: una fila por obra + editorial con control **Yes** en Tempo
(`song_share_detail_mv.smp_controlled_ind = 'Y'`). Los Tempo ID se escriben en el `IN` del bloque 1 (marcado `EDITABLE`), a pedido del usuario.

Estados: `CONTROLADA` y `SIN EDITORIAL CONTROLADA` (tiene participaciones, ninguna Yes). Un ID que no está en la MV
(no es song_type 1 / secuencia 0, o un writer sin sociedad la saca) no aparece: comparar la cantidad de obras.

Columnas: Tempo ID, song title, editorial controlada, IPI de la editorial (`dp_writer_data.publisher_v.cae_num`, permiso
confirmado; es numérico y puede venir vacío), estado, publisher_id, capacidad
(OP/SE/AM...) y writers que representa. Sin contratos, grupos IP ni porcentajes (pedido del usuario).

Lee `dp_song_metadata.song_share_detail_mv` una sola vez y `dp_writer_data.publisher_v` para el IPI. Prueba: `python3 editoriales_control/tests/test_editoriales.py`.
