-- =====================================================================
-- RECAUDACIÓN EMMAC + SMP LATIN DE LAS OBRAS CONTROLADAS EN LOS PAÍSES — v1
--
-- Una fila por obra de public.obras_controladas_pais_resultado (las obras
-- controladas en los países ya corridos con sp_obras_controladas_pais; si una obra
-- está en varios países, sale una sola vez con la lista de países) que tenga
-- importe en EMMAC o en SMP Latin.
--
-- De dónde sale cada dato (mismo criterio que las queries ya validadas):
--   * EMMAC (como financials/mexico_emmac.sql): dp_statement_lines.statement_lines_v,
--     oficina que procesó México, líneas Finalized, fuente o sub fuente con EMMAC en
--     cualquier forma ("EMMAC A EN P", "Emmac", "EMMAC/SACM", "Emmac / Maquilas"...;
--     verificado con los nombres reales el 12/11/2026).
--       emmac_gross_mxn = lc_gross_stmt_am (lo informado, antes de retención/comisión)
--       emmac_neto_mxn  = converted_net_am (lo que quedó en la oficina México)
--       *_usd          = con exchange_to_us_currency de cada statement (> 1 divide,
--                        < 1 multiplica).
--   * SMP Latin (como financials/song_financials_el.sql, verificado al centavo con
--     el front en la obra 6101269): dp_earnings_lines.earnings_lines_v, oficina
--     United States, fuente exacta "SMP Latin" / sub fuente "BackOffice - Latin"
--     (confirmado por el usuario el 12/11/2026; no otras intercompany como SMP UK,
--     SMP Mexico o SMP LATINA). Montos en USD:
--       smp_latin_gross_income = gross_client_share_of_income_amt (Gross Income)
--       affiliate_nps / domestic_nps / client_royalty como en el front
--       smp_latin_converted_net = converted_net_am una vez por línea de statement
--                                 (lo que llegó a Estados Unidos).
--   * SMP Latin en las demás oficinas (UK, México, Holanda, Corea, Argentina,
--     Colombia...): de statement_lines_v (las líneas de ganancia no traen tipo de
--     cambio), monto informado (lc_gross_stmt_am) y neto, convertidos a USD con el
--     tipo de cambio de cada statement; lista de oficinas en smp_latin_otras_oficinas.
--   * total_recaudado_usd          = emmac_gross_usd + smp_latin_gross_income (Estados Unidos).
--     total_con_otras_oficinas_usd = lo anterior + smp_latin_otras_oficinas_gross_usd.
--     PENDIENTE: el sentido de exchange_to_us_currency está verificado solo para el
--     peso (> 1 divide, < 1 multiplica). Para libra o euro (UK, Holanda...) puede ir
--     al revés: confirmar con la consulta de tipos de cambio de financials/README.md
--     antes de usar las columnas de otras oficinas.
--     Son dos flujos distintos: EMMAC es lo cobrado en México (fuente local) y SMP
--     Latin lo que las afiliadas de Latinoamérica giraron a Estados Unidos
--     (México llega a Estados Unidos como "SMP Mexico", no como SMP Latin).
--
-- EDITABLE (líneas marcadas): nombres de fuente, oficina y período. Confirmar
-- antes los nombres con la consulta de fuentes de financials/README.md
-- (mexico_emmac.sql dejó pendiente confirmar 'Mexico...' y 'EMMAC').
-- Rendimiento: cada vista de montos se lee una vez, filtrada por fuente y oficina.
-- =====================================================================
WITH
-- 1. Obras controladas (todos los países cargados en la tabla).
obras AS (
    SELECT
        CAST(r.song_id AS BIGINT)                                  AS song_id,
        MAX(r.song_title_tx)                                       AS song_title_tx,
        COUNT(*)                                                   AS cantidad_paises,
        LISTAGG(r.pais, ', ') WITHIN GROUP (ORDER BY r.pais)       AS paises_controlados
    FROM public.obras_controladas_pais_resultado r
    GROUP BY r.song_id
),

-- 2. Líneas de statement (una sola lectura): EMMAC en la oficina México (E) y
--    SMP Latin en las oficinas que no son Estados Unidos (L). Los nombres se comparan
--    en mayúsculas: Tempo escribe "EMMAC A EN P", "Emmac", "EMMAC/SACM",
--    "Emmac / Maquilas", etc., y LIKE distingue mayúsculas.
stmt AS (
    SELECT
        CAST(song_id AS BIGINT)                                                   AS song_id,
        SUM(CASE WHEN tipo = 'E' THEN 1 ELSE 0 END)                               AS emmac_lineas,
        MIN(CASE WHEN tipo = 'E' THEN semiannual_statement_period END)            AS emmac_primer_periodo,
        MAX(CASE WHEN tipo = 'E' THEN semiannual_statement_period END)            AS emmac_ultimo_periodo,
        SUM(CASE WHEN tipo = 'E' THEN lc_gross_stmt_am END)                       AS emmac_gross_mxn,
        SUM(CASE WHEN tipo = 'E' THEN converted_net_am END)                       AS emmac_neto_mxn,
        SUM(CASE WHEN tipo = 'E' THEN lc_gross_stmt_am * factor_usd END)          AS emmac_gross_usd,
        SUM(CASE WHEN tipo = 'E' THEN converted_net_am * factor_usd END)          AS emmac_neto_usd,
        SUM(CASE WHEN tipo = 'E' AND factor_usd IS NULL THEN 1 ELSE 0 END)        AS emmac_lineas_sin_tc,
        SUM(CASE WHEN tipo = 'L' THEN 1 ELSE 0 END)                               AS latin_otras_lineas,
        SUM(CASE WHEN tipo = 'L' THEN lc_gross_stmt_am * factor_usd END)          AS latin_otras_gross_usd,
        SUM(CASE WHEN tipo = 'L' THEN converted_net_am * factor_usd END)          AS latin_otras_neto_usd,
        SUM(CASE WHEN tipo = 'L' AND factor_usd IS NULL THEN 1 ELSE 0 END)        AS latin_otras_lineas_sin_tc,
        LISTAGG(CASE WHEN tipo = 'L' AND rn_oficina = 1 THEN processing_office_name END, ', ')
            WITHIN GROUP (ORDER BY processing_office_name)                        AS latin_otras_oficinas
    FROM (
        SELECT
            y.*,
            ROW_NUMBER() OVER (PARTITION BY y.song_id, y.tipo, y.processing_office_name
                               ORDER BY y.semiannual_statement_period) AS rn_oficina
        FROM (
            SELECT
                s.song_id, s.processing_office_name, s.semiannual_statement_period, s.lc_gross_stmt_am, s.converted_net_am,
                CASE WHEN s.source_name = 'SMP Latin' AND s.sub_source_name = 'BackOffice - Latin' THEN 'L' ELSE 'E' END AS tipo,
                CASE
                    WHEN s.exchange_to_us_currency IS NULL OR s.exchange_to_us_currency = 0 THEN NULL
                    WHEN s.exchange_to_us_currency > 1 THEN 1 / s.exchange_to_us_currency
                    ELSE s.exchange_to_us_currency
                END AS factor_usd
            FROM dp_statement_lines.statement_lines_v s
            WHERE s.statement_line_status = 'Finalized'
              AND s.song_id IS NOT NULL
              AND (
                    -- EMMAC: oficina México, cualquier variante de EMMAC en fuente o sub fuente     -- EDITABLE
                    (s.processing_office_name LIKE 'Mexico%'
                     AND s.source_name <> 'SMP Latin'
                     AND (UPPER(s.source_name) LIKE '%EMMAC%' OR UPPER(s.sub_source_name) LIKE '%EMMAC%'))
                    -- SMP Latin en las demás oficinas (Estados Unidos sale de las líneas de ganancia) -- EDITABLE
                 OR (s.source_name = 'SMP Latin' AND s.sub_source_name = 'BackOffice - Latin'
                     AND s.processing_office_name <> 'United States')
                  )
              -- AND s.semiannual_statement_period BETWEEN DATE '2024-01-01' AND DATE '2026-12-31'   -- EDITABLE: período
        ) y
    ) x
    GROUP BY song_id
),

-- 3. SMP Latin: líneas de ganancia de la oficina Estados Unidos (montos en USD).
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
        WHERE e.processing_office_name = 'United States'                               -- EDITABLE: oficina
          AND e.source_name = 'SMP Latin'                                              -- EDITABLE: fuente SMP Latin
          AND e.sub_source_name = 'BackOffice - Latin'                                 --   (no SMP UK, SMP Mexico, SMP LATINA...)
          AND e.song_id IS NOT NULL
          -- AND e.accounting_period_dt BETWEEN DATE '2024-01-01' AND DATE '2026-12-31'          -- EDITABLE: período
    ) x
    GROUP BY song_id
),

-- 4. ISWC preferido ('Yes'; si no hay, el menor sin conflicto).
iswc AS (
    SELECT song_id, iswc, preferido AS iswc_preferido
    FROM (
        SELECT
            CAST(i.tempo_song_id AS BIGINT) AS song_id,
            i.ident_iswc_cd                 AS iswc,
            CASE WHEN i.preferred_indicator IN ('Yes', 'Y') THEN 'Yes' ELSE 'No' END AS preferido,
            ROW_NUMBER() OVER (
                PARTITION BY i.tempo_song_id
                ORDER BY CASE WHEN i.preferred_indicator IN ('Yes', 'Y') THEN 0 ELSE 1 END,
                         CASE WHEN i.conflict_indicator IN ('Yes', 'Y') THEN 1 ELSE 0 END,
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
    -- EMMAC (oficina México)
    CAST(s.emmac_gross_mxn AS NUMERIC(18,2))          AS emmac_gross_mxn,
    CAST(s.emmac_neto_mxn  AS NUMERIC(18,2))          AS emmac_neto_mxn,
    CAST(s.emmac_gross_usd AS NUMERIC(18,2))          AS emmac_gross_usd,
    CAST(s.emmac_neto_usd  AS NUMERIC(18,2))          AS emmac_neto_usd,
    s.emmac_lineas,
    s.emmac_lineas_sin_tc,
    s.emmac_primer_periodo,
    s.emmac_ultimo_periodo,
    -- SMP Latin (oficina Estados Unidos, USD)
    CAST(l.smp_latin_gross_income   AS NUMERIC(18,2)) AS smp_latin_gross_income_usd,
    CAST(l.smp_latin_affiliate_nps  AS NUMERIC(18,2)) AS smp_latin_affiliate_nps_usd,
    CAST(l.smp_latin_domestic_nps   AS NUMERIC(18,2)) AS smp_latin_domestic_nps_usd,
    CAST(l.smp_latin_client_royalty AS NUMERIC(18,2)) AS smp_latin_client_royalty_usd,
    CAST(l.smp_latin_converted_net  AS NUMERIC(18,2)) AS smp_latin_converted_net_usd,
    l.smp_latin_lineas_statement,
    l.smp_latin_primer_periodo,
    l.smp_latin_ultimo_periodo,
    -- SMP Latin en las demás oficinas (statement lines, convertido a USD)
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
;
