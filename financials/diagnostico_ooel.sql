-- =====================================================================
-- DIAGNÓSTICO: por qué song_financials_ooel.sql devolvió 0 filas.
-- Correr cada consulta por separado y pasar los resultados.
-- Los statement_header_id son los 12 que trajo la query de statement_lines_v
-- (obra 6101269, SMP Latin, Finalized).
-- =====================================================================

-- 1) ¿Hay líneas de ganancia de esos statements? (vista de oficina que procesa)
--    Muestra cómo se llama la fuente y qué song_id tienen en esta vista.
SELECT
    e.source_name, e.sub_source_name, e.song_id, e.processing_office_name,
    e.sl_statement_line_status_name,
    COUNT(*)                     AS lineas_ganancia,
    SUM(e.converted_net_am)      AS converted_net_am,
    SUM(e.gross_client_share_of_income_amt) AS gross_client_share,
    SUM(e.foreign_nps_am)        AS foreign_nps_am,
    SUM(e.gross_nps)             AS gross_nps,
    SUM(e.gross_royalty_payable) AS gross_royalty_payable
FROM dp_earnings_lines.earnings_lines_v e
WHERE e.statement_header_id IN (341606,343015,344708,346212,348014,349963,351913,354165,356355,358025,360650,362762)
  AND e.song_id = 6101269
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1, 2, 3, 4, 5;

-- 2) Lo mismo en la vista de oficina dueña del cliente (la que usaba la query).
SELECT
    o.source_name, o.sub_source_name, o.song_id, o.processing_office_name, o.client_originating_office_nm,
    COUNT(*)                                     AS lineas_ganancia,
    SUM(o.at_source_converted_net_am)            AS at_source_converted_net_am,
    SUM(o.originating_office_gross_statement_am) AS oo_gross_statement_am,
    SUM(o.foreign_nps_am)                        AS foreign_nps_am,
    SUM(o.originating_office_nps_am)             AS oo_nps_am,
    SUM(o.client_royalty_payable_am)             AS client_royalty_payable_am
FROM dp_earnings_lines.originating_office_earnings_lines_v o
WHERE o.statement_header_id IN (341606,343015,344708,346212,348014,349963,351913,354165,356355,358025,360650,362762)
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1, 2, 3, 4, 5;

-- 3) Si 1 y 2 dan vacío: ¿la obra tiene líneas de ganancia en general?
--    Fuentes con las que aparece la obra en cada vista.
SELECT 'earnings_lines_v' AS vista, source_name, sub_source_name, COUNT(*) AS lineas
FROM dp_earnings_lines.earnings_lines_v
WHERE song_id = 6101269
GROUP BY 1, 2, 3
UNION ALL
SELECT 'originating_office_earnings_lines_v', source_name, sub_source_name, COUNT(*)
FROM dp_earnings_lines.originating_office_earnings_lines_v
WHERE song_id = 6101269
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;
