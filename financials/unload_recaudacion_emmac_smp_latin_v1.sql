-- =====================================================================
-- UNLOAD: recaudación EMMAC + SMP Latin de las obras controladas
--
-- Misma query que recaudacion_emmac_smp_latin_v1.sql dentro de un UNLOAD. No
-- editar acá: cambiar la query y regenerar con
--   python3 financials/tools/generar_unload.py
-- Obras: todas las de public.obras_controladas_pais_resultado (todos los países
-- ya corridos). Resultado: s3://dw-export-prod/7000042560/recaudacion_emmac_smp_latin_000.csv
-- (si pasa de 1 GB, _001, _002...). Dura 7 días; correrlo de nuevo lo pisa.
-- =====================================================================
UNLOAD ('
WITH
obras AS (
    SELECT
        CAST(r.song_id AS BIGINT)                                  AS song_id,
        MAX(r.song_title_tx)                                       AS song_title_tx,
        COUNT(*)                                                   AS cantidad_paises,
        LISTAGG(r.pais, '', '') WITHIN GROUP (ORDER BY r.pais)       AS paises_controlados
    FROM public.obras_controladas_pais_resultado r
    GROUP BY r.song_id
),

stmt AS (
    SELECT
        CAST(song_id AS BIGINT)                                                   AS song_id,
        SUM(CASE WHEN tipo = ''E'' THEN 1 ELSE 0 END)                               AS emmac_lineas,
        MIN(CASE WHEN tipo = ''E'' THEN semiannual_statement_period END)            AS emmac_primer_periodo,
        MAX(CASE WHEN tipo = ''E'' THEN semiannual_statement_period END)            AS emmac_ultimo_periodo,
        SUM(CASE WHEN tipo = ''E'' THEN lc_gross_stmt_am END)                       AS emmac_gross_mxn,
        SUM(CASE WHEN tipo = ''E'' THEN converted_net_am END)                       AS emmac_neto_mxn,
        SUM(CASE WHEN tipo = ''E'' THEN lc_gross_stmt_am * factor_usd END)          AS emmac_gross_usd,
        SUM(CASE WHEN tipo = ''E'' THEN converted_net_am * factor_usd END)          AS emmac_neto_usd,
        SUM(CASE WHEN tipo = ''E'' AND factor_usd IS NULL THEN 1 ELSE 0 END)        AS emmac_lineas_sin_tc,
        SUM(CASE WHEN tipo = ''L'' THEN 1 ELSE 0 END)                               AS latin_otras_lineas,
        SUM(CASE WHEN tipo = ''L'' THEN lc_gross_stmt_am * factor_usd END)          AS latin_otras_gross_usd,
        SUM(CASE WHEN tipo = ''L'' THEN converted_net_am * factor_usd END)          AS latin_otras_neto_usd,
        SUM(CASE WHEN tipo = ''L'' AND factor_usd IS NULL THEN 1 ELSE 0 END)        AS latin_otras_lineas_sin_tc,
        LISTAGG(CASE WHEN tipo = ''L'' AND rn_oficina = 1 THEN processing_office_name END, '', '')
            WITHIN GROUP (ORDER BY processing_office_name)                        AS latin_otras_oficinas
    FROM (
        SELECT
            y.*,
            ROW_NUMBER() OVER (PARTITION BY y.song_id, y.tipo, y.processing_office_name
                               ORDER BY y.semiannual_statement_period) AS rn_oficina
        FROM (
            SELECT
                s.song_id, s.processing_office_name, s.semiannual_statement_period, s.lc_gross_stmt_am, s.converted_net_am,
                CASE WHEN s.source_name = ''SMP Latin'' AND s.sub_source_name = ''BackOffice - Latin'' THEN ''L'' ELSE ''E'' END AS tipo,
                CASE
                    WHEN s.exchange_to_us_currency IS NULL OR s.exchange_to_us_currency = 0 THEN NULL
                    WHEN s.exchange_to_us_currency > 1 THEN 1 / s.exchange_to_us_currency
                    ELSE s.exchange_to_us_currency
                END AS factor_usd
            FROM dp_statement_lines.statement_lines_v s
            WHERE s.statement_line_status = ''Finalized''
              AND s.song_id IS NOT NULL
              AND (
                    (s.processing_office_name LIKE ''Mexico%''
                     AND s.source_name <> ''SMP Latin''
                     AND (UPPER(s.source_name) LIKE ''%EMMAC%'' OR UPPER(s.sub_source_name) LIKE ''%EMMAC%''))
                 OR (s.source_name = ''SMP Latin'' AND s.sub_source_name = ''BackOffice - Latin''
                     AND s.processing_office_name <> ''United States'')
                  )
        ) y
    ) x
    GROUP BY song_id
),

latin AS (
    SELECT
        CAST(song_id AS BIGINT)                                    AS song_id,
        SUM(CASE WHEN rn_linea = 1 THEN 1 ELSE 0 END)              AS smp_latin_lineas_statement,
        MIN(accounting_period_dt)                                  AS smp_latin_primer_periodo,
        MAX(accounting_period_dt)                                  AS smp_latin_ultimo_periodo,
        SUM(gross_client_share_of_income_amt)                      AS smp_latin_gross_income,
        SUM(foreign_nps_am)                                        AS smp_latin_affiliate_nps,
        SUM(gross_nps)                                             AS smp_latin_domestic_nps,
        SUM(gross_royalty_payable)                                 AS smp_latin_client_royalty,
        SUM(CASE WHEN rn_linea = 1 THEN converted_net_am END)      AS smp_latin_converted_net
    FROM (
        SELECT
            e.song_id, e.accounting_period_dt, e.gross_client_share_of_income_amt, e.foreign_nps_am,
            e.gross_nps, e.gross_royalty_payable, e.converted_net_am,
            ROW_NUMBER() OVER (PARTITION BY e.statement_header_id, e.processing_office_id, e.statement_line_id
                               ORDER BY e.earnings_line_id) AS rn_linea
        FROM dp_earnings_lines.earnings_lines_v e
        WHERE e.processing_office_name = ''United States''
          AND e.source_name = ''SMP Latin''
          AND e.sub_source_name = ''BackOffice - Latin''
          AND e.song_id IS NOT NULL
    ) x
    GROUP BY song_id
),

iswc AS (
    SELECT song_id, iswc, preferido AS iswc_preferido
    FROM (
        SELECT
            CAST(i.tempo_song_id AS BIGINT) AS song_id,
            i.ident_iswc_cd                 AS iswc,
            CASE WHEN i.preferred_indicator IN (''Yes'', ''Y'') THEN ''Yes'' ELSE ''No'' END AS preferido,
            ROW_NUMBER() OVER (
                PARTITION BY i.tempo_song_id
                ORDER BY CASE WHEN i.preferred_indicator IN (''Yes'', ''Y'') THEN 0 ELSE 1 END,
                         CASE WHEN i.conflict_indicator IN (''Yes'', ''Y'') THEN 1 ELSE 0 END,
                         i.ident_iswc_cd) AS rn
        FROM dp_song_metadata.identifiers_iswc_v i
        WHERE i.tempo_song_id IN (SELECT song_id FROM public.obras_controladas_pais_resultado)
          AND i.ident_iswc_cd IS NOT NULL
    ) x
    WHERE rn = 1
)

SELECT
    o.song_id,
    o.song_title_tx,
    iw.iswc,
    iw.iswc_preferido,
    o.paises_controlados,
    o.cantidad_paises,
    CAST(COALESCE(s.emmac_gross_usd, 0) + COALESCE(l.smp_latin_gross_income, 0) AS NUMERIC(18,2)) AS total_recaudado_usd,
    CAST(COALESCE(s.emmac_gross_usd, 0) + COALESCE(l.smp_latin_gross_income, 0)
         + COALESCE(s.latin_otras_gross_usd, 0) AS NUMERIC(18,2))                        AS total_con_otras_oficinas_usd,
    CAST(s.emmac_gross_mxn AS NUMERIC(18,2))          AS emmac_gross_mxn,
    CAST(s.emmac_neto_mxn  AS NUMERIC(18,2))          AS emmac_neto_mxn,
    CAST(s.emmac_gross_usd AS NUMERIC(18,2))          AS emmac_gross_usd,
    CAST(s.emmac_neto_usd  AS NUMERIC(18,2))          AS emmac_neto_usd,
    s.emmac_lineas,
    s.emmac_lineas_sin_tc,
    s.emmac_primer_periodo,
    s.emmac_ultimo_periodo,
    CAST(l.smp_latin_gross_income   AS NUMERIC(18,2)) AS smp_latin_gross_income_usd,
    CAST(l.smp_latin_affiliate_nps  AS NUMERIC(18,2)) AS smp_latin_affiliate_nps_usd,
    CAST(l.smp_latin_domestic_nps   AS NUMERIC(18,2)) AS smp_latin_domestic_nps_usd,
    CAST(l.smp_latin_client_royalty AS NUMERIC(18,2)) AS smp_latin_client_royalty_usd,
    CAST(l.smp_latin_converted_net  AS NUMERIC(18,2)) AS smp_latin_converted_net_usd,
    l.smp_latin_lineas_statement,
    l.smp_latin_primer_periodo,
    l.smp_latin_ultimo_periodo,
    CAST(s.latin_otras_gross_usd AS NUMERIC(18,2))   AS smp_latin_otras_oficinas_gross_usd,
    CAST(s.latin_otras_neto_usd  AS NUMERIC(18,2))   AS smp_latin_otras_oficinas_neto_usd,
    s.latin_otras_oficinas                           AS smp_latin_otras_oficinas,
    s.latin_otras_lineas                             AS smp_latin_otras_oficinas_lineas,
    s.latin_otras_lineas_sin_tc                      AS smp_latin_otras_oficinas_lineas_sin_tc
FROM obras o
LEFT JOIN stmt s  ON s.song_id = o.song_id
LEFT JOIN latin l ON l.song_id = o.song_id
LEFT JOIN iswc iw ON iw.song_id = o.song_id
WHERE s.song_id IS NOT NULL OR l.song_id IS NOT NULL
ORDER BY total_recaudado_usd DESC, o.song_id
')
TO 's3://dw-export-prod/7000042560/recaudacion_emmac_smp_latin_'
IAM_ROLE 'arn:aws:iam::991042281579:role/DataWarehouse/RedShift-S3-Unload'
FORMAT AS CSV
HEADER
EXTENSION 'csv'
PARALLEL OFF
MAXFILESIZE 1 GB
ALLOWOVERWRITE;
