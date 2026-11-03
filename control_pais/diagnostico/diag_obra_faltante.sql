-- =====================================================================
-- DIAGNÓSTICO: por qué una obra no sale en obras_controladas_pais_v1 (Chile)
-- EDITABLE: el Tempo ID en el IN (una sola vez). Un solo resultado, por pasos:
--   1_MV       filas de song_share_detail_mv (grupo IP, control, publisher, contrato)
--   2_LINEA    filas de contract_territories (texto Include / Exclude)
--   3_EVAL     cómo evalúa la query cada línea para Chile (texto normalizado y si cubre)
--   4_CONTEO   cantidad de filas en cada fuente
-- Si 1_MV no trae filas: la obra no está en la MV (writer sin sociedad o secuencia).
-- Si 2_LINEA no trae filas: la obra no tiene líneas de control (contrato sin rate
-- client / payment option / office group activo).
-- =====================================================================
WITH
claves AS (
              SELECT 'P' AS tipo, 'CHILE' AS clave
    UNION ALL SELECT 'R', 'LATIN AMERICA'
    UNION ALL SELECT 'R', 'SOUTH AMERICA'
),
fuente AS (
    SELECT *
    FROM (
        SELECT 'M' AS t, s.song_id, s.song_ip_territory_nm AS grupo, s.smp_controlled_ind AS ctrl,
               s.publisher_name_tx AS publisher, s.writer_nm AS writer,
               s.associated_contract_id AS contract_id, s.associated_contract_nm AS contract_nm,
               CAST(NULL AS VARCHAR(65535)) AS inclusions, CAST(NULL AS VARCHAR(65535)) AS exclusions,
               s.publisher_performance_pc AS perf
        FROM dp_song_metadata.song_share_detail_mv s
        UNION ALL
        SELECT 'L', ct.song_id, NULL, NULL, NULL, NULL, ct.contract_id, ct.contract_nm,
               ct.inclusions, ct.exclusions, NULL
        FROM dp_song_metadata.contract_territories ct
    ) u
    WHERE u.song_id IN (274220)
),
eval AS (
    SELECT
        f.*,
        ';' || REGEXP_REPLACE(
                   TRIM(REGEXP_REPLACE(
                       REGEXP_REPLACE(
                           UPPER(TRANSLATE(COALESCE(f.inclusions, ''), 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun')),
                           '[[:space:]]*[(]REG[)]', ''),
                       '^[[:space:]]*INCLUDE:[[:space:]]*', '')),
                   '[[:space:]]*;[[:space:]]*', ';') || ';' AS incl,
        ';' || REGEXP_REPLACE(
                   TRIM(REGEXP_REPLACE(
                       REGEXP_REPLACE(
                           UPPER(TRANSLATE(COALESCE(f.exclusions, ''), 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun')),
                           '[[:space:]]*[(]REG[)]', ''),
                       '^[[:space:]]*EXCLUDE:[[:space:]]*', '')),
                   '[[:space:]]*;[[:space:]]*', ';') || ';' AS excl,
        COUNT(CASE WHEN f.t = 'M' THEN 1 END) OVER () AS n_mv,
        COUNT(CASE WHEN f.t = 'L' THEN 1 END) OVER () AS n_lineas
    FROM fuente f
)
SELECT '1_MV' AS paso, CAST(song_id AS BIGINT) AS song_id,
       grupo || ' | ctrl=' || COALESCE(ctrl, '(nulo)') || ' | ' || COALESCE(publisher, '(sin publisher)')
       || ' | writer=' || COALESCE(writer, '(nulo)') || ' | perf=' || COALESCE(CAST(perf AS VARCHAR(20)), '(nulo)') AS detalle,
       COALESCE(CAST(contract_id AS VARCHAR(20)), 'SIN CONTRATO') || ' - ' || COALESCE(contract_nm, '') AS contrato
FROM eval WHERE t = 'M'
UNION ALL
SELECT '2_LINEA', CAST(song_id AS BIGINT),
       'INC: ' || COALESCE(SUBSTRING(inclusions, 1, 300), '(nulo)') || ' | EXC: ' || COALESCE(SUBSTRING(exclusions, 1, 300), '(nulo)'),
       CAST(contract_id AS VARCHAR(20)) || ' - ' || COALESCE(contract_nm, '')
FROM eval WHERE t = 'L'
UNION ALL
SELECT '3_EVAL', CAST(e.song_id AS BIGINT),
       'incl=' || SUBSTRING(e.incl, 1, 200) || ' | world=' || MAX(CASE WHEN e.incl LIKE '%;WORLD;%' THEN 'SI' ELSE 'no' END)
       || ' | incluye_clave=' || MAX(CASE WHEN e.incl LIKE '%;' || k.clave || ';%' THEN 'SI' ELSE 'no' END)
       || ' | excluye_clave=' || MAX(CASE WHEN e.excl LIKE '%;' || k.clave || ';%' THEN 'SI' ELSE 'no' END),
       CAST(e.contract_id AS VARCHAR(20))
FROM eval e CROSS JOIN claves k
WHERE e.t = 'L'
GROUP BY e.song_id, e.contract_id, e.incl
UNION ALL
SELECT '4_CONTEO', NULL,
       'filas MV=' || CAST(COALESCE(MAX(n_mv), 0) AS VARCHAR(10)) || ' | lineas de control=' || CAST(COALESCE(MAX(n_lineas), 0) AS VARCHAR(10)),
       NULL
FROM eval
ORDER BY paso, contrato, detalle
;
