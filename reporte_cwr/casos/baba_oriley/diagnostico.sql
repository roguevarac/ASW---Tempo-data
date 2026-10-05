-- DIAGNOSTICO obra 2701309 (Baba O'Riley). Correr cada consulta por separado y pasar los resultados.
-- Esperado segun el front (Song2701309_IPInfo_front.xlsx), grupo "All Other Contractual Territories",
-- contrato 1525818, publisher Westminster Music Ltd, control Yes: Mecanico 100 / Performance 50 / Sync 100.

-- 1) Texto de territorio que tiene la tabla para esta obra (una fila por contrato y nombre).
SELECT
    ct.contract_id,
    ct.contract_nm,
    LEN(ct.inclusions)                                          AS largo_inclusions,
    LEN(ct.exclusions)                                          AS largo_exclusions,
    UPPER(ct.inclusions) LIKE '%WORLD%'                         AS incl_world,
    UPPER(ct.inclusions) LIKE '%ARGENTINA%'                     AS incl_argentina,
    UPPER(ct.inclusions) LIKE '%CHILE%'                         AS incl_chile,
    UPPER(ct.inclusions) LIKE '%COLOMBIA%'                      AS incl_colombia,
    UPPER(ct.inclusions) LIKE '%PERU%'                          AS incl_peru,
    UPPER(ct.inclusions) LIKE '%URUGUAY%'                       AS incl_uruguay,
    UPPER(ct.exclusions) LIKE '%ARGENTINA%'                     AS excl_argentina,
    UPPER(ct.exclusions) LIKE '%CHILE%'                         AS excl_chile,
    UPPER(ct.exclusions) LIKE '%COLOMBIA%'                      AS excl_colombia,
    UPPER(ct.exclusions) LIKE '%PERU%'                          AS excl_peru,
    UPPER(ct.exclusions) LIKE '%URUGUAY%'                       AS excl_uruguay,
    SUBSTRING(ct.inclusions, 1, 400)                            AS inclusions_inicio,
    SUBSTRING(ct.exclusions, 1, 400)                            AS exclusions_inicio
FROM dp_song_metadata.contract_territories ct
WHERE ct.song_id = 2701309
ORDER BY ct.contract_id, ct.contract_nm;

-- 2) Filas de participacion que ve la MV para esta obra (incluye el texto concatenado de la MV,
--    que es NULL cuando exclusions es NULL).
SELECT
    s.song_ip_territory_nm, s.associated_contract_id, s.associated_contract_nm, s.smp_controlled_ind,
    s.writer_nm, s.publisher_name_tx, s.publisher_id,
    s.publisher_mechanical_pc, s.publisher_performance_pc, s.publisher_sync_pc,
    SUBSTRING(s.song_contract_territory_nm, 1, 200) AS texto_mv_inicio
FROM dp_song_metadata.song_share_detail_mv s
WHERE s.song_id = 2701309
ORDER BY s.song_ip_territory_nm, s.associated_contract_id, s.publisher_name_tx;

-- 3) ¿Este texto es un caso aislado? Mismo contrato en otras obras: cuantos textos distintos hay.
SELECT
    ct.contract_id,
    LEN(ct.inclusions)  AS largo_inclusions,
    LEN(ct.exclusions)  AS largo_exclusions,
    SUBSTRING(ct.inclusions, 1, 120) AS inclusions_inicio,
    COUNT(DISTINCT ct.song_id) AS obras,
    COUNT(DISTINCT ct.contract_nm) AS nombres_distintos
FROM dp_song_metadata.contract_territories ct
WHERE ct.contract_id IN (1525818, 1551999)
GROUP BY ct.contract_id, LEN(ct.inclusions), LEN(ct.exclusions), SUBSTRING(ct.inclusions, 1, 120)
ORDER BY ct.contract_id, obras DESC;
