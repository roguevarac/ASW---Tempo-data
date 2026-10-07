-- =====================================================================
-- DIAGNÓSTICO: ¿qué columna de statement_lines_v da el Gross Income del
-- front en fuentes intercompany (SMP Latin, SMP Argentina...)?
--
-- Valores del front para la obra 6101269 (USD):
--   Fuente          Income type            Gross Income   Affiliate NPS  WHT
--   SMP Latin       Download Mechanical          18,29        3,18      0
--   SMP Latin       Stream - Mechanical      12.203,02      734,97      0
--   SMP Latin       Synch Online             22.415,47    1.445,18      0
--   SMP Argentina   (total de la fuente)     29.938,83    2.903,28  8.500,23
--   YouTube - USA   (control, fuente local)  118.078,88       0         0
--
-- Cada columna c_... es un candidato. La que reproduzca el Gross Income es la
-- que hay que usar. c_converted_net es lo que ya teníamos (da el neto, no el gross).
-- =====================================================================
SELECT
    source_name,
    income_type_name,
    processing_office_name,
    COUNT(*)                                                        AS lineas,
    SUM(CASE WHEN intercompany_sl IS NOT NULL THEN 1 ELSE 0 END)    AS lineas_con_ref_intercompany,
    CAST(SUM(converted_net_am) AS NUMERIC(18,2))                    AS c_converted_net,
    CAST(SUM(lc_gross_stmt_am) AS NUMERIC(18,2))                    AS c_lc_gross_stmt,
    CAST(SUM(lc_at_source_net_am) AS NUMERIC(18,2))                 AS c_lc_at_source_net,
    CAST(SUM(lc_gross_stmt_am * exchange_to_us_currency) AS NUMERIC(18,2))     AS c_lc_gross_x_tc_us,
    CAST(SUM(lc_gross_stmt_am / NULLIF(exchange_to_us_currency, 0)) AS NUMERIC(18,2)) AS c_lc_gross_div_tc_us,
    CAST(SUM(lc_at_source_net_am * exchange_to_us_currency) AS NUMERIC(18,2))  AS c_lc_at_source_x_tc_us,
    CAST(SUM(lc_at_source_net_am / NULLIF(exchange_to_us_currency, 0)) AS NUMERIC(18,2)) AS c_lc_at_source_div_tc_us,
    MIN(exchange_to_us_currency)                                    AS tc_us_min,
    MAX(exchange_to_us_currency)                                    AS tc_us_max,
    MIN(withholding_tax_rate)                                       AS wht_min,
    MAX(withholding_tax_rate)                                       AS wht_max,
    MIN(conversion_comm_rt)                                         AS comision_min,
    MAX(conversion_comm_rt)                                         AS comision_max
FROM dp_statement_lines.statement_lines_v
WHERE song_id = 6101269
  AND statement_line_status = 'Finalized'
  AND (source_name LIKE 'SMP Latin%' OR source_name LIKE 'SMP Argentina%' OR source_name LIKE 'YouTube - USA%')
GROUP BY source_name, income_type_name, processing_office_name
ORDER BY source_name, income_type_name, processing_office_name;
