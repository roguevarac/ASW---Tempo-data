# Split de las obras de un cliente

`split_cliente_v1.sql`: todas las obras de un `client_id` (`dp_deal_metadata.client_contract_song_v`, activas e
inactivas) con su split completo de Tempo, una fila por obra + territorio del split (grupo IP) + writer + publisher.
El client_id se cambia en el bloque `parametros`.

Por obra: ISWC (preferido = `preferred_indicator = 'Yes'`; si hay varios, el menor; si no hay preferido, el menor
sin conflicto, marcado `iswc_preferido = 'No'`; `cantidad_iswc` y `otros_iswc`), contratos del cliente con
vencimiento y estado (VIGENTE / VENCIDO / MIXTO / SIN VENCIMIENTO), obra NOP y aviso si no tiene split en la MV.
Por fila: writer y publisher con sus %, control, contrato asociado con vencimiento y su Include / Exclude, si el
contrato es del cliente y el total controlado SMP del territorio (= "Publisher Controlled" de Tempo).

Lecturas: MV 2, `song_v` 1, `contract_v` 1, ISWC 1, `contract_territories` 1 (todas filtradas a las obras del
cliente). Para más de 100.000 filas, la misma query dentro de un UNLOAD (comillas simples duplicadas):
`UNLOAD ('<query sin ;>') TO 's3://dw-export-prod/7000042560/split_cliente_' IAM_ROLE '...RedShift-S3-Unload'
FORMAT AS CSV HEADER EXTENSION 'csv' PARALLEL OFF MAXFILESIZE 1 GB ALLOWOVERWRITE;`

Prueba: `python3 split_cliente/tests/test_split_cliente.py`.
