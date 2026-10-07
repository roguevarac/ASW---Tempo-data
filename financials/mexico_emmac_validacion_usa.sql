-- =====================================================================
-- VALIDACIÓN: lo que llegó a Estados Unidos desde México (EMMAC), en USD.
-- Mismo armado que song_financials_el.sql, filtrado a la oficina Estados Unidos y
-- a la sub fuente EMMAC. Columnas como el front "Song Financials".
--
-- Cómo se relaciona con mexico_emmac.sql:
--   - gross_income de acá debería ser MENOR o igual que neto_usd de México: solo
--     incluye la parte de los clientes de Estados Unidos.
--   - affiliate_nps es lo que retuvo la oficina México; withholding_tax_estimado,
--     la retención (aproximada, por diferencia).
-- =====================================================================
SELECT
    e.song_id,
    MAX(e.song_title)                                                    AS song_title,
    e.source_name,
    e.sub_source_name,
    e.sl_income_type_name                                                AS income_type,
    CAST(SUM(e.gross_client_share_of_income_amt) AS NUMERIC(18,2))       AS gross_income,
    CAST(SUM(e.foreign_nps_am)                   AS NUMERIC(18,2))       AS affiliate_nps,
    CAST(SUM(e.gross_nps)                        AS NUMERIC(18,2))       AS domestic_nps,
    CAST(SUM(e.gross_royalty_payable)            AS NUMERIC(18,2))       AS client_royalty,
    CAST(SUM(e.gross_client_share_of_income_amt) - SUM(e.foreign_nps_am)
         - SUM(e.gross_nps) - SUM(e.gross_royalty_payable) AS NUMERIC(18,2)) AS withholding_tax_estimado,
    COUNT(*)                                                             AS lineas_ganancia
FROM dp_earnings_lines.earnings_lines_v e
WHERE e.song_id IN (SELECT song_id FROM public.rankingdigital_song_id WHERE song_id IS NOT NULL)
  AND e.processing_office_name = 'United States'
  AND e.sub_source_name LIKE '%EMMAC%'
GROUP BY e.song_id, e.source_name, e.sub_source_name, e.sl_income_type_name
ORDER BY e.song_id, e.source_name, e.sub_source_name, e.sl_income_type_name;
