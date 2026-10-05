-- =====================================================================
-- CONTROL PREVIO v3 — dos consultas, correr cada una por separado
-- =====================================================================

-- A) ¿Cuántas de tus obras tienen datos de participaciones?
--    Si "obras_con_participaciones" es mucho menor que "obras_en_lista",
--    las que faltan van a salir NVFT en todos los países por falta de
--    datos (no por la query). La columna "obras_sin_datos" las lista.
WITH lista AS (
    SELECT DISTINCT song_id
    FROM dp_song_metadata.song_v
    WHERE song_id IN (
        7777841,7777839,2582605,6146322,6757163,7610448,5064830,7182530,4561711,5587099,5294797,28755,7525701,7682215,7086827,5092800,7256352,5196177,7536155,327237,7777854,7525686,7714996,191014,5026723,6740634,2649208,2660988,7159221,5026737,7594612,4555478,550810,5751389,1303178,4273597,5687811,7184775,2661049,4823212,2316641,7142299,7506515,2658835,7490088,6012929,6261420,2590841,5073349,6176302,6640425,4386644,6760420,7875164,6887017,7760567,6989652,7710563,7204081,2145411,5938752,6989105,7808656,7485419,6802711,112996,7525924,5770053,6452138,5106087,7450744,6945418,5527423,7900799,6686578,2589549
    )
),
con_datos AS (
    SELECT DISTINCT s.song_id
    FROM dp_song_metadata.song_share_detail_mv s
    JOIN lista l ON l.song_id = s.song_id
)
SELECT
    (SELECT COUNT(*) FROM lista)     AS obras_en_lista,
    (SELECT COUNT(*) FROM con_datos) AS obras_con_participaciones,
    (SELECT LISTAGG(CAST(l.song_id AS VARCHAR(20)), ', ') WITHIN GROUP (ORDER BY l.song_id)
       FROM lista l
       WHERE l.song_id NOT IN (SELECT song_id FROM con_datos)) AS obras_sin_datos;


-- B) Textos de territorio de los contratos de tus obras.
--    Revisá si en "inclusions" o "exclusions" aparece alguna REGIÓN
--    (no un país) que contenga a Argentina, Chile, Perú, Uruguay o
--    Colombia. Si aparece alguna distinta de "Latin America" o
--    "South America", pasámela para sumarla al diccionario de la v3.
SELECT DISTINCT
    ct.contract_id,
    ct.contract_nm,
    ct.inclusions,
    ct.exclusions
FROM dp_song_metadata.contract_territories ct
WHERE ct.contract_id IN (
    SELECT DISTINCT associated_contract_id
    FROM dp_song_metadata.song_share_detail_mv
    WHERE smp_controlled_ind = 'Y'
      AND song_id IN (
        7777841,7777839,2582605,6146322,6757163,7610448,5064830,7182530,4561711,5587099,5294797,28755,7525701,7682215,7086827,5092800,7256352,5196177,7536155,327237,7777854,7525686,7714996,191014,5026723,6740634,2649208,2660988,7159221,5026737,7594612,4555478,550810,5751389,1303178,4273597,5687811,7184775,2661049,4823212,2316641,7142299,7506515,2658835,7490088,6012929,6261420,2590841,5073349,6176302,6640425,4386644,6760420,7875164,6887017,7760567,6989652,7710563,7204081,2145411,5938752,6989105,7808656,7485419,6802711,112996,7525924,5770053,6452138,5106087,7450744,6945418,5527423,7900799,6686578,2589549
      )
)
ORDER BY ct.contract_id;
