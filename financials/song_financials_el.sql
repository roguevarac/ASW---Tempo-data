-- =====================================================================
-- SONG FINANCIALS POR OBRA, FUENTE E INCOME TYPE (desde líneas de ganancia)
--
-- Reproduce el "Song Sub Source Summary" del front para muchas obras a la vez.
-- Las obras se leen de public.rankingdigital_song_id (columna song_id).
-- Se filtra directo por obra (y, si se quiere, por oficina, fuente o período);
-- no depende de statement headers.
--
-- Columnas y equivalencia con el front (verificado al centavo con la obra
-- 6101269, fuente SMP Latin, oficina United States):
--   gross_income      = gross_client_share_of_income_amt   (front: Gross Income)
--   affiliate_nps     = foreign_nps_am                     (front: Affiliate NPS)
--   domestic_nps      = gross_nps                          (front: Domestic NPS)
--   client_royalty    = gross_royalty_payable              (front: Client Royalty)
--   converted_net     = converted_net_am de cada línea de statement, sumado una
--                       sola vez por línea (una línea genera varias de ganancia).
--                       Es lo que da statement_lines_v.
--   withholding_tax_estimado = gross - affiliate_nps - domestic_nps - client_royalty
--                       En fuentes locales coincide con el Withholding Tax del
--                       front. En fuentes intercompany ("SMP ...") puede no
--                       coincidir por diferencias de tipo de cambio: usarlo como
--                       referencia, no como dato exacto.
--
-- Moneda: cada monto está en la moneda de la oficina que procesó
-- (processing_office_name). El front en USD corresponde a 'United States'.
-- No sumar montos de oficinas distintas.
-- =====================================================================
WITH
el AS (
    SELECT
        e.song_id,
        e.song_title,
        e.processing_office_name,
        e.source_name,
        e.sub_source_name,
        e.sl_income_type_name,
        e.rate_type_id,
        e.gross_client_share_of_income_amt,
        e.foreign_nps_am,
        e.gross_nps,
        e.gross_royalty_payable,
        e.converted_net_am,
        ROW_NUMBER() OVER (PARTITION BY e.statement_header_id, e.processing_office_id, e.statement_line_id
                           ORDER BY e.earnings_line_id) AS rn_linea
    FROM dp_earnings_lines.earnings_lines_v e
    WHERE e.song_id IN (SELECT song_id FROM public.rankingdigital_song_id WHERE song_id IS NOT NULL)
      -- Filtros opcionales (sacar el -- para usarlos):
      -- AND e.processing_office_name = 'United States'
      -- AND e.source_name LIKE 'SMP Latin%'
      -- AND e.accounting_period_dt BETWEEN DATE '2024-01-01' AND DATE '2026-06-30'
)
SELECT
    song_id,
    MAX(song_title)                                                        AS song_title,
    processing_office_name,
    source_name,
    sub_source_name,
    sl_income_type_name                                                    AS income_type,
    CAST(SUM(gross_client_share_of_income_amt) AS NUMERIC(18,2))           AS gross_income,
    CAST(SUM(foreign_nps_am)                   AS NUMERIC(18,2))           AS affiliate_nps,
    CAST(SUM(gross_nps)                        AS NUMERIC(18,2))           AS domestic_nps,
    CAST(SUM(gross_royalty_payable)            AS NUMERIC(18,2))           AS client_royalty,
    CAST(SUM(gross_client_share_of_income_amt) - SUM(foreign_nps_am)
         - SUM(gross_nps) - SUM(gross_royalty_payable) AS NUMERIC(18,2))   AS withholding_tax_estimado,
    CAST(SUM(CASE WHEN rn_linea = 1 THEN converted_net_am END) AS NUMERIC(18,2)) AS converted_net,
    SUM(CASE WHEN rn_linea = 1 THEN 1 ELSE 0 END)                          AS lineas_statement,
    COUNT(*)                                                               AS lineas_ganancia,
    SUM(CASE WHEN rate_type_id = 4 THEN 1 ELSE 0 END)                      AS lineas_participante_rt4
FROM el
GROUP BY song_id, processing_office_name, source_name, sub_source_name, sl_income_type_name
ORDER BY song_id, processing_office_name, source_name, sub_source_name, sl_income_type_name;
