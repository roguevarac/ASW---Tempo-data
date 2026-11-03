# Editoriales con control SMP por obra y territorio

`editoriales_controladas_v1.sql`: una fila por obra + territorio IP + editorial con control **Yes** en Tempo
(`song_share_detail_mv.smp_controlled_ind = 'Y'`). Los Tempo ID se escriben en el único `IN` de la query (marcado
`EDITABLE`), a pedido del usuario.

Columnas: `tempo_id`, `song_title`, `territorio_ip` (grupo IP de Tempo, ej. "All Other Contractual Territories",
"MEXICO, PHILIPPINES (REG)"), `editorial_controlada`, `ipi_editorial` (`dp_writer_data.publisher_v.cae_num`: numérico,
puede venir vacío), `estado`, `publisher_id`, `writers_representados`, `contrato_asociado` (contrato de la participación
con su Include / Exclude de `contract_territories`, o "sin línea de control activa") y `lineas_control_obra` (todas las
líneas de control de la obra con su Include / Exclude; es la referencia del territorio controlado y puede incluir
contratos que la participación no menciona, como ABKCO Music International Limited en Baba O'Riley).

Estados: `CONTROLADA` y `SIN EDITORIAL CONTROLADA` (tiene participaciones, ninguna Yes; igual muestra sus líneas). Un ID
que no está en la MV (no es song_type 1 / secuencia 0, o un writer sin sociedad la saca) no aparece: comparar la
cantidad de obras. Sin porcentajes ni capacidad (pedido del usuario).

Lee `song_share_detail_mv` y `contract_territories` una vez cada una, en un solo flujo filtrado por el `IN`.
Prueba (incluye el caso real 2701309): `python3 editoriales_control/tests/test_editoriales.py`.
