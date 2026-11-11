-- =====================================================================
-- UNLOAD: obras controladas en un país (todo el catálogo) a S3
--
-- Es la misma query que obras_controladas_pais_v1.sql dentro de un UNLOAD.
-- Adentro del texto las comillas simples van duplicadas ('' en vez de ').
-- No editar la query acá: cambiarla en obras_controladas_pais_v1.sql y
-- regenerar este archivo con:  python3 control_pais/tools/generar_unload.py
--
-- País: bloque "claves" de la query (hoy CHILE).
--
-- Datos según "Redshift Query Editor Instructions for Access":
--   conexión self-service-prod-wg, base selfsvcdb
--   destino  s3://dw-export-prod/<GID>/<archivo>   (GID 7000042560)
--   rol      arn:aws:iam::991042281579:role/DataWarehouse/RedShift-S3-Unload
--
-- Resultado: s3://dw-export-prod/7000042560/obras_controladas_pais_000.csv
--   CSV con encabezado, un solo archivo ordenado por obra (si pasa de 1 GB se
--   parte en _001, _002...). Para descargarlo: consola AWS > S3 > bucket
--   dw-export-prod > carpeta 7000042560 > Download. El archivo se borra solo a
--   los 7 días. Correrlo de nuevo lo pisa.
-- =====================================================================
UNLOAD ('
WITH

claves AS (
    SELECT c.pais, c.tipo, c.clave, c.orden
    FROM public.control_pais_claves c
    WHERE c.pais = ''CHILE''
),

ct_norm AS (
    SELECT
        ct.song_id,
        ct.contract_id,
        ct.contract_nm,
        ct.inclusions,
        ct.exclusions,
        '';'' || REGEXP_REPLACE(
                   TRIM(REGEXP_REPLACE(
                       REGEXP_REPLACE(
                           UPPER(TRANSLATE(COALESCE(ct.inclusions, ''''), ''ÁÉÍÓÚÜÑáéíóúüñ'', ''AEIOUUNaeiouun'')),
                           ''[[:space:]]*[(]REG[)]'', ''''),
                       ''^[[:space:]]*INCLUDE:[[:space:]]*'', '''')),
                   ''[[:space:]]*;[[:space:]]*'', '';'') || '';'' AS incl,
        '';'' || REGEXP_REPLACE(
                   TRIM(REGEXP_REPLACE(
                       REGEXP_REPLACE(
                           UPPER(TRANSLATE(COALESCE(ct.exclusions, ''''), ''ÁÉÍÓÚÜÑáéíóúüñ'', ''AEIOUUNaeiouun'')),
                           ''[[:space:]]*[(]REG[)]'', ''''),
                       ''^[[:space:]]*EXCLUDE:[[:space:]]*'', '''')),
                   ''[[:space:]]*;[[:space:]]*'', '';'') || '';'' AS excl
    FROM dp_song_metadata.contract_territories ct
    WHERE ct.song_id BETWEEN 0 AND 999999999999
      AND ct.contract_id IS NOT NULL
),
lineas_ok AS (
    SELECT song_id, contract_id, contract_nm
    FROM (
        SELECT
            c.song_id,
            c.contract_id,
            MAX(c.contract_nm)                                                   AS contract_nm,
            MAX(CASE WHEN c.incl LIKE ''%;WORLD;%'' THEN 1 ELSE 0 END)             AS inc_mundo,
            MAX(CASE WHEN c.incl LIKE ''%;'' || k.clave || '';%'' THEN 1 ELSE 0 END) AS inc_pais,
            MAX(CASE WHEN c.excl LIKE ''%;'' || k.clave || '';%'' THEN 1 ELSE 0 END) AS exc_pais
        FROM ct_norm c
        CROSS JOIN claves k
        GROUP BY c.song_id, c.contract_id
    ) x
    WHERE x.exc_pais = 0
      AND (x.inc_mundo = 1 OR x.inc_pais = 1)
),

mv_raw AS (
    SELECT
        s.song_id,
        s.song_title_tx,
        s.associated_contract_id                          AS contract_id,
        s.associated_contract_nm                          AS contract_nm,
        s.smp_controlled_ind                              AS ctrl,
        s.publisher_name_tx,
        UPPER(TRIM(COALESCE(s.song_ip_territory_nm, ''''))) AS grupo_ip,
        s.publisher_performance_pc                        AS perf,
        s.publisher_mechanical_pc                         AS mech,
        s.publisher_sync_pc                               AS sync,
        '' '' || TRIM(REGEXP_REPLACE(TRANSLATE(UPPER(TRIM(COALESCE(s.song_ip_territory_nm, ''''))), ''ÁÉÍÓÚÜÑ'', ''AEIOUUN''),
                                   ''[^A-Z0-9]+'', '' '')) || '' '' AS tok
    FROM dp_song_metadata.song_share_detail_mv s
    WHERE s.song_id BETWEEN 0 AND 999999999999
      AND s.song_id IN (SELECT song_id FROM lineas_ok)
),
mv_tok AS (
    SELECT
        m.*,
        CASE WHEN m.pos_excl > 0 THEN SUBSTRING(m.tok FROM 1 FOR m.pos_excl) ELSE m.tok END AS incl_tok,
        CASE WHEN m.pos_excl > 0 THEN SUBSTRING(m.tok FROM m.pos_excl)       ELSE ''''    END AS excl_tok
    FROM (
        SELECT r.*, REGEXP_INSTR(r.tok, '' (EX|EXCL|EXCLUDING|EXCEPT|EXCLUDE|EXCLUDES) '') AS pos_excl
        FROM mv_raw r
    ) m
),
mv_grupo AS (
    SELECT *
    FROM (
        SELECT
            m.song_id, m.song_title_tx, m.contract_id, m.contract_nm, m.ctrl, m.publisher_name_tx,
            m.grupo_ip, m.perf, m.mech, m.sync, k.orden AS k_orden,
            CASE WHEN TRIM(m.incl_tok) = '''' OR m.incl_tok LIKE '' ALL %'' OR m.incl_tok LIKE ''% WORLD %''
                      OR m.incl_tok LIKE ''% WORLDWIDE %'' OR m.incl_tok LIKE ''% UNIVERSE %'' OR m.incl_tok LIKE ''% MUNDO %''
                 THEN 1 ELSE 0 END AS es_generico,
            MAX(CASE WHEN k.tipo = ''P'' AND m.incl_tok LIKE ''% '' || k.clave || '' %'' THEN 1 ELSE 0 END)
                OVER (PARTITION BY m.song_id, m.grupo_ip) AS g_pais,
            MAX(CASE WHEN k.tipo = ''R'' AND m.incl_tok LIKE ''% '' || k.clave || '' %'' THEN 1 ELSE 0 END)
                OVER (PARTITION BY m.song_id, m.grupo_ip) AS g_region,
            MAX(CASE WHEN m.excl_tok <> '''' AND m.excl_tok LIKE ''% '' || k.clave || '' %'' THEN 1 ELSE 0 END)
                OVER (PARTITION BY m.song_id, m.grupo_ip) AS g_excluido
        FROM mv_tok m
        CROSS JOIN claves k
    ) x
    WHERE x.k_orden = 1
),

vinfo AS (
    SELECT contract_id, MAX(contract_expiration_dt) AS contract_expiration_dt
    FROM dp_deal_metadata.contract_v
    WHERE contract_id IN (SELECT ct.contract_id
                          FROM dp_song_metadata.contract_territories ct
                          WHERE ct.song_id BETWEEN 0 AND 999999999999)
    GROUP BY contract_id
),
u0 AS (
    SELECT
        ''M'' AS tipo, g.song_id, g.song_title_tx, g.contract_id, g.contract_nm, g.ctrl, g.publisher_name_tx,
        g.grupo_ip, g.perf, g.mech, g.sync,
        CASE
            WHEN g.g_excluido = 1                       THEN NULL
            WHEN g.es_generico = 0 AND g.g_pais = 1     THEN 1
            WHEN g.es_generico = 0 AND g.g_region = 1   THEN 2
            WHEN g.es_generico = 1                      THEN 3
        END AS spec,
        CAST(NULL AS DATE) AS contract_expiration_dt
    FROM mv_grupo g
    UNION ALL
    SELECT
        ''L'', l.song_id, NULL, l.contract_id, l.contract_nm, NULL, NULL,
        NULL, NULL, NULL, NULL,
        NULL,
        v.contract_expiration_dt
    FROM lineas_ok l
    LEFT JOIN vinfo v ON v.contract_id = l.contract_id
),
u1 AS (
    SELECT
        u.*,
        MIN(u.spec) OVER (PARTITION BY u.song_id) AS best_spec,
        MAX(CASE WHEN u.tipo = ''L'' THEN 1 ELSE 0 END) OVER (PARTITION BY u.song_id, u.contract_id) AS asoc_cubre
    FROM u0 u
),
u2 AS (
    SELECT
        u.*,
        MIN(CASE WHEN u.spec = u.best_spec THEN u.grupo_ip END) OVER (PARTITION BY u.song_id) AS grupo_elegido,
        DENSE_RANK() OVER (PARTITION BY u.song_id, CASE WHEN u.spec = u.best_spec THEN 1 ELSE 0 END
                           ORDER BY u.grupo_ip) AS dr_grupo
    FROM u1 u
),
u3 AS (
    SELECT
        u.*,
        MAX(CASE WHEN u.spec = u.best_spec THEN u.dr_grupo END) OVER (PARTITION BY u.song_id) AS n_empate,
        CASE WHEN u.tipo = ''M'' AND u.ctrl = ''Y'' AND u.grupo_ip = u.grupo_elegido THEN 1 ELSE 0 END AS es_ctrl
    FROM u2 u
),
u4 AS (
    SELECT
        u.*,
        MAX(u.es_ctrl) OVER (PARTITION BY u.song_id) AS obra_ctrl,
        ROW_NUMBER() OVER (PARTITION BY u.song_id, u.es_ctrl, u.publisher_name_tx ORDER BY u.contract_id) AS rn_pub,
        ROW_NUMBER() OVER (PARTITION BY u.song_id, u.es_ctrl, u.contract_id       ORDER BY u.publisher_name_tx) AS rn_casoc
    FROM u3 u
),
listas AS (
              SELECT ''base'' AS lst
    UNION ALL SELECT ''pub''
    UNION ALL SELECT ''casoc''
    UNION ALL SELECT ''linea''
),
u5 AS (
    SELECT
        u.*,
        x.lst,
        CASE x.lst
            WHEN ''pub''   THEN CASE WHEN u.es_ctrl = 1 AND u.rn_pub = 1 THEN u.publisher_name_tx END
            WHEN ''casoc'' THEN CASE WHEN u.es_ctrl = 1 AND u.rn_casoc = 1
                                   THEN COALESCE(CAST(u.contract_id AS VARCHAR(20)), ''SIN CONTRATO'') || '' - ''
                                        || CAST(COALESCE(u.contract_nm, ''Sin nombre'') AS VARCHAR(200)) END
            WHEN ''linea'' THEN CASE WHEN u.tipo = ''L''
                                   THEN CAST(u.contract_id AS VARCHAR(20)) || '' - ''
                                        || CAST(COALESCE(u.contract_nm, ''Sin nombre'') AS VARCHAR(200)) || '' [''
                                        || CASE
                                               WHEN u.contract_expiration_dt IS NULL THEN ''sin venc.''
                                               WHEN u.contract_expiration_dt < CURRENT_DATE
                                                   THEN ''VENCIDO '' || CAST(u.contract_expiration_dt AS VARCHAR(10))
                                               ELSE ''vig. '' || CAST(u.contract_expiration_dt AS VARCHAR(10))
                                           END || '']'' END
        END AS item,
        CASE x.lst
            WHEN ''pub''   THEN u.publisher_name_tx
            WHEN ''casoc'' THEN LPAD(COALESCE(CAST(u.contract_id AS VARCHAR(20)), ''''), 20, ''0'')
            ELSE LPAD(CAST(u.contract_id AS VARCHAR(20)), 20, ''0'')
        END AS orden
    FROM u4 u
    CROSS JOIN listas x
    WHERE u.obra_ctrl = 1
),
res AS (
    SELECT
        song_id,
        MAX(song_title_tx)                                                              AS song_title_tx,
        MAX(CASE WHEN lst = ''base'' THEN best_spec END)                                  AS especificidad,
        MAX(CASE WHEN lst = ''base'' THEN grupo_elegido END)                              AS grupo_ip,
        MAX(CASE WHEN lst = ''base'' THEN n_empate END)                                   AS n_empate,
        SUM(CASE WHEN lst = ''base'' AND es_ctrl = 1 THEN perf END)                       AS perf,
        SUM(CASE WHEN lst = ''base'' AND es_ctrl = 1 THEN mech END)                       AS mech,
        SUM(CASE WHEN lst = ''base'' AND es_ctrl = 1 THEN sync END)                       AS sync,
        MAX(CASE WHEN lst = ''base'' AND es_ctrl = 1 AND contract_id IS NULL THEN 1 ELSE 0 END) AS hay_sin_contrato,
        MAX(CASE WHEN lst = ''base'' AND es_ctrl = 1 AND contract_id IS NOT NULL AND asoc_cubre = 0 THEN 1 ELSE 0 END) AS hay_otra_linea,
        SUM(CASE WHEN lst = ''pub'' AND item IS NOT NULL THEN 1 ELSE 0 END)               AS cantidad_publishers,
        SUM(CASE WHEN lst = ''base'' AND tipo = ''L'' THEN 1 ELSE 0 END)                    AS n_lineas,
        SUM(CASE WHEN lst = ''base'' AND tipo = ''L'' AND contract_expiration_dt < CURRENT_DATE THEN 1 ELSE 0 END)  AS n_vencidos,
        SUM(CASE WHEN lst = ''base'' AND tipo = ''L'' AND contract_expiration_dt >= CURRENT_DATE THEN 1 ELSE 0 END) AS n_vigentes,
        MIN(CASE WHEN lst = ''base'' AND tipo = ''L'' THEN contract_expiration_dt END)       AS venc_proximo,
        MAX(CASE WHEN lst = ''base'' AND tipo = ''L'' THEN contract_expiration_dt END)       AS venc_lejano,
        NULLIF(LISTAGG(CASE WHEN lst = ''pub''   THEN item END, '' | '') WITHIN GROUP (ORDER BY orden), '''') AS publishers,
        NULLIF(LISTAGG(CASE WHEN lst = ''casoc'' THEN item END, '' | '') WITHIN GROUP (ORDER BY orden), '''') AS contratos_asociados,
        NULLIF(LISTAGG(CASE WHEN lst = ''linea'' THEN item END, '' | '') WITHIN GROUP (ORDER BY orden), '''') AS lineas_que_cubren_el_pais
    FROM u5
    GROUP BY song_id
),
iswc AS (
    SELECT
        tempo_song_id AS song_id,
        COALESCE(MAX(CASE WHEN preferred_indicator IN (''Yes'', ''Y'') THEN ident_iswc_cd END), MIN(ident_iswc_cd)) AS iswc
    FROM dp_song_metadata.identifiers_iswc_v
    WHERE tempo_song_id BETWEEN 0 AND 999999999999
      AND ident_iswc_cd IS NOT NULL
    GROUP BY tempo_song_id
)

SELECT
    CAST(r.song_id AS BIGINT)                             AS song_id,
    r.song_title_tx,
    iw.iswc,
    k.pais                                                AS pais,
    CAST(COALESCE(r.perf, 0) AS NUMERIC(10,2))            AS performance_pc_total,
    CAST(COALESCE(r.mech, 0) AS NUMERIC(10,2))            AS mechanical_pc_total,
    CAST(COALESCE(r.sync, 0) AS NUMERIC(10,2))            AS sync_pc_total,
    r.publishers,
    r.cantidad_publishers,
    r.contratos_asociados,
    CASE WHEN r.grupo_ip = '''' THEN ''(sin nombre)'' ELSE r.grupo_ip END AS grupo_ip_usado,
    CASE r.especificidad
        WHEN 1 THEN ''Grupo nombra al país''
        WHEN 2 THEN ''Grupo nombra una región que lo incluye''
        ELSE ''Grupo mundial''
    END                                                   AS como_se_eligio_grupo,
    r.lineas_que_cubren_el_pais,
    r.n_lineas                                            AS cantidad_lineas,
    r.venc_proximo                                        AS contrato_venc_mas_proximo,
    r.venc_lejano                                         AS contrato_venc_mas_lejano,
    CASE
        WHEN r.n_vencidos = r.n_lineas THEN ''TODOS VENCIDOS''
        WHEN r.n_vencidos > 0          THEN ''MIXTO (alguno vencido)''
        WHEN r.n_vigentes = 0          THEN ''SIN VENCIMIENTO''
        ELSE ''VIGENTE''
    END                                                   AS estado_contrato,
    NULLIF(
        CASE WHEN r.n_empate > 1 THEN ''VARIOS GRUPOS CON LA MISMA PRIORIDAD; '' ELSE '''' END
        || CASE WHEN r.hay_sin_contrato = 1 THEN ''PARTICIPACION SIN CONTRATO; '' ELSE '''' END
        || CASE WHEN COALESCE(r.perf, 0) > 100 OR COALESCE(r.mech, 0) > 100 OR COALESCE(r.sync, 0) > 100
                THEN ''TOTAL SUPERA 100 (posible doble conteo en la cadena de publishers); '' ELSE '''' END
        || CASE WHEN COALESCE(r.perf, 0) = 0 AND COALESCE(r.mech, 0) = 0 AND COALESCE(r.sync, 0) = 0
                THEN ''CONTROL CON PORCENTAJES EN 0; '' ELSE '''' END
        || CASE WHEN r.hay_otra_linea = 1
                THEN ''CONTROL SOSTENIDO POR OTRA LINEA DE CONTROL (el contrato asociado a la participacion no cubre el pais); '' ELSE '''' END
    , '''')                                                 AS alertas
FROM res r
JOIN claves k   ON k.orden = 1
LEFT JOIN iswc iw ON iw.song_id = r.song_id
ORDER BY song_id
')
TO 's3://dw-export-prod/7000042560/obras_controladas_pais_'
IAM_ROLE 'arn:aws:iam::991042281579:role/DataWarehouse/RedShift-S3-Unload'
FORMAT AS CSV
HEADER
EXTENSION 'csv'
PARALLEL OFF
MAXFILESIZE 1 GB
ALLOWOVERWRITE;
