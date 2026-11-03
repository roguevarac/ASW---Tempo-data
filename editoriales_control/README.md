# Editoriales con control SMP por obra y territorio

`editoriales_controladas_v1.sql`: una fila por obra + territorio IP + editorial con control **Yes** en Tempo
(`song_share_detail_mv.smp_controlled_ind = 'Y'`). Los Tempo ID se escriben en el único `IN` de la query (marcado
`EDITABLE`), a pedido del usuario.

Columnas: `tempo_id`, `song_title`, `territorio_ip` (grupo IP de Tempo, ej. "All Other Contractual Territories",
"MEXICO, PHILIPPINES (REG)"), `editorial_controlada`, `ipi_editorial` (`dp_writer_data.publisher_v.cae_num`: numérico,
puede venir vacío), `publisher_id`, `writers_representados`, `contrato_asociado` (contrato de la participación
con su Include / Exclude de `contract_territories`, o "sin línea de control activa") y `lineas_control_obra` (todas las
líneas de control de la obra con su Include / Exclude; es la referencia del territorio controlado y puede incluir
contratos que la participación no menciona, como ABKCO Music International Limited en Baba O'Riley).

Solo salen editoriales controladas **vigentes** (pedido del usuario): `smp_controlled_ind = 'Y'` con contrato asociado
no vencido (`contract_v.contract_expiration_dt`; sin contrato o sin vencimiento cuenta), en obras que no son NOP
(`song_v.song_not_ours_dt`) y que tienen al menos una línea de control vigente. Las líneas muestran [vig.], [sin venc.]
o [VENCIDO]. Las obras no controladas no aparecen. Un ID que no
está en la MV tampoco aparece. Sin porcentajes ni capacidad (pedido del usuario).

El `IN` filtra `contract_territories`; la MV se lee 2 veces, `song_v` y `contract_v` 1 vez, todas filtradas.
Prueba (incluye el caso real 2701309): `python3 editoriales_control/tests/test_editoriales.py`.
