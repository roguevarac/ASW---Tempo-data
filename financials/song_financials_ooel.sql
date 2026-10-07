-- =====================================================================
-- SONG FINANCIALS DESDE LAS LÍNEAS DE GANANCIA (originating office)
--
-- Objetivo: reproducir el "Song Sub Source Summary (Worldwide)" del front
-- (Gross Income, Affiliate NPS, Withholding Tax, Domestic NPS, Client Royalty)
-- para una obra y una fuente, y ver qué columna de Tempo da cada número.
--
-- Caso de referencia: obra 6101269 (Bailando Bachata), fuente SMP Latin.
--   Front (USD)           Download Mech   Stream - Mech   Synch Online
--   Gross Income                  18,29       12.203,02      22.415,47
--   Affiliate NPS                  3,18          734,97       1.445,18
--   Domestic NPS                   2,85        1.201,58       2.501,51
--   Client Royalty                15,73       10.382,11      18.669,94
--   (Domestic NPS + Client Royalty = converted_net_am de statement_lines_v, exacto)
--
-- Cómo leer el resultado: cada columna "c_..." es un candidato. La que dé
-- 12.203,02 en Stream - Mechanical es la que usa el front como Gross Income.
-- Si ninguna da, el front convierte a USD con otro tipo de cambio (ver
-- processing_office_name / client_originating_office_nm).
--
-- Grano: originating_office_earnings_lines_v tiene una fila por línea de
-- ganancia y oficina. Los montos sl_* son de la línea de statement y se
-- repiten en cada línea de ganancia que genera, por eso se suman una sola vez
-- por línea de statement (columna es_primera).
-- =====================================================================
WITH
parametros AS (
    SELECT 6101269 AS song_id, 'SMP Latin%' AS fuente
),
ooel AS (
    SELECT
        o.*,
        ROW_NUMBER() OVER (PARTITION BY o.statement_header_id, o.processing_office_id, o.statement_line_id
                           ORDER BY o.earnings_line_id) AS rn_sl
    FROM dp_earnings_lines.originating_office_earnings_lines_v o
    JOIN parametros p ON p.song_id = o.song_id
    WHERE o.source_name LIKE p.fuente
)
SELECT
    sub_source_name,
    income_type_name,
    processing_office_name,
    client_originating_office_nm,
    rate_type_id,
    COUNT(*)                                                           AS lineas_ganancia,
    SUM(CASE WHEN rn_sl = 1 THEN 1 ELSE 0 END)                         AS lineas_statement,

    -- Candidatos a "Gross Income"
    SUM(at_source_converted_net_am)                                    AS c_at_source_converted_net_am,
    SUM(intrco_client_shr_incm_am)                                     AS c_intrco_client_shr_incm_am,
    SUM(originating_office_gross_statement_am)                         AS c_originating_office_gross_statement_am,
    SUM(CASE WHEN rn_sl = 1 THEN converted_at_src_net_amt END)         AS c_sl_converted_at_src_net_amt,
    SUM(CASE WHEN rn_sl = 1 THEN lc_at_src_net_amt END)                AS c_sl_lc_at_src_net_amt,
    SUM(CASE WHEN rn_sl = 1 THEN lc_gross_stmt_amt END)                AS c_sl_lc_gross_stmt_amt,

    -- Columnas que deberían dar Affiliate NPS, Domestic NPS y Client Royalty
    SUM(foreign_nps_am)                                                AS c_foreign_nps_am,
    SUM(originating_office_nps_am)                                     AS c_originating_office_nps_am,
    SUM(client_royalty_payable_am)                                     AS c_client_royalty_payable_am,

    -- Control: debería dar igual que tu query de statement_lines_v
    SUM(CASE WHEN rn_sl = 1 THEN sl_converted_net_amt END)             AS ctrl_sl_converted_net_amt
FROM ooel
GROUP BY sub_source_name, income_type_name, processing_office_name, client_originating_office_nm, rate_type_id
ORDER BY sub_source_name, income_type_name, processing_office_name, client_originating_office_nm, rate_type_id;
