-- =====================================================================
-- RECAUDACIÓN SACM + SMP LATIN DE LAS OBRAS CONTROLADAS EN LOS PAÍSES — v1
--
-- Una fila por obra de public.obras_controladas_pais_resultado (las obras
-- controladas en los países ya corridos con sp_obras_controladas_pais; si una obra
-- está en varios países, sale una sola vez con la lista de países) que tenga
-- importe en SACM o en SMP Latin.
--
-- De dónde sale cada dato (mismo criterio que las queries ya validadas):
--   * SACM (como financials/mexico_emmac.sql): dp_statement_lines.statement_lines_v,
--     oficina que procesó México, fuente o sub fuente SACM, líneas Finalized.
--       sacm_gross_mxn = lc_gross_stmt_am (lo informado, antes de retención/comisión)
--       sacm_neto_mxn  = converted_net_am (lo que quedó en la oficina México)
--       *_usd          = con exchange_to_us_currency de cada statement (> 1 divide,
--                        < 1 multiplica).
--   * SMP Latin (como financials/song_financials_el.sql, verificado al centavo con
--     el front en la obra 6101269): dp_earnings_lines.earnings_lines_v, oficina
--     United States, fuente SMP Latin. Montos en USD:
--       smp_latin_gross_income = gross_client_share_of_income_amt (Gross Income)
--       affiliate_nps / domestic_nps / client_royalty como en el front
--       smp_latin_converted_net = converted_net_am una vez por línea de statement
--                                 (lo que llegó a Estados Unidos).
--   * total_recaudado_usd = sacm_gross_usd + smp_latin_gross_income.
--     Son dos flujos distintos: SACM es lo cobrado en México (fuente local) y SMP
--     Latin lo que las afiliadas de Latinoamérica giraron a Estados Unidos
--     (México llega a Estados Unidos como "SMP Mexico", no como SMP Latin).
--
-- EDITABLE (líneas marcadas): nombres de fuente, oficina y período. Confirmar
-- antes los nombres con la consulta de fuentes de financials/README.md.
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

-- 2. SACM: líneas de statement de la oficina México.
sacm AS (
    SELECT
        CAST(song_id AS BIGINT)                                    AS song_id,
        COUNT(*)                                                   AS sacm_lineas,
        MIN(semiannual_statement_period)                           AS sacm_primer_periodo,
        MAX(semiannual_statement_period)                           AS sacm_ultimo_periodo,
        SUM(lc_gross_stmt_am)                                      AS sacm_gross_mxn,
        SUM(converted_net_am)                                      AS sacm_neto_mxn,
        SUM(lc_gross_stmt_am * factor_usd)                         AS sacm_gross_usd,
        SUM(converted_net_am * factor_usd)                         AS sacm_neto_usd,
        SUM(CASE WHEN factor_usd IS NULL THEN 1 ELSE 0 END)        AS sacm_lineas_sin_tc
    FROM (
        SELECT
            s.song_id, s.semiannual_statement_period, s.lc_gross_stmt_am, s.converted_net_am,
            CASE
                WHEN s.exchange_to_us_currency IS NULL OR s.exchange_to_us_currency = 0 THEN NULL
                WHEN s.exchange_to_us_currency > 1 THEN 1 / s.exchange_to_us_currency
                ELSE s.exchange_to_us_currency
            END AS factor_usd
        FROM dp_statement_lines.statement_lines_v s
        WHERE s.processing_office_name LIKE 'Mexico%'                                  -- EDITABLE: oficina
          AND (s.source_name LIKE '%SACM%' OR s.sub_source_name LIKE '%SACM%')         -- EDITABLE: fuente SACM
          AND s.statement_line_status = 'Finalized'
          AND s.song_id IS NOT NULL
          -- AND s.semiannual_statement_period BETWEEN DATE '2024-01-01' AND DATE '2026-12-31'   -- EDITABLE: período
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
          AND e.source_name LIKE 'SMP Latin%'                                          -- EDITABLE: fuente SMP Latin
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
    CAST(COALESCE(s.sacm_gross_usd, 0) + COALESCE(l.smp_latin_gross_income, 0) AS NUMERIC(18,2)) AS total_recaudado_usd,
    -- SACM (oficina México)
    CAST(s.sacm_gross_mxn AS NUMERIC(18,2))          AS sacm_gross_mxn,
    CAST(s.sacm_neto_mxn  AS NUMERIC(18,2))          AS sacm_neto_mxn,
    CAST(s.sacm_gross_usd AS NUMERIC(18,2))          AS sacm_gross_usd,
    CAST(s.sacm_neto_usd  AS NUMERIC(18,2))          AS sacm_neto_usd,
    s.sacm_lineas,
    s.sacm_lineas_sin_tc,
    s.sacm_primer_periodo,
    s.sacm_ultimo_periodo,
    -- SMP Latin (oficina Estados Unidos, USD)
    CAST(l.smp_latin_gross_income   AS NUMERIC(18,2)) AS smp_latin_gross_income_usd,
    CAST(l.smp_latin_affiliate_nps  AS NUMERIC(18,2)) AS smp_latin_affiliate_nps_usd,
    CAST(l.smp_latin_domestic_nps   AS NUMERIC(18,2)) AS smp_latin_domestic_nps_usd,
    CAST(l.smp_latin_client_royalty AS NUMERIC(18,2)) AS smp_latin_client_royalty_usd,
    CAST(l.smp_latin_converted_net  AS NUMERIC(18,2)) AS smp_latin_converted_net_usd,
    l.smp_latin_lineas_statement,
    l.smp_latin_primer_periodo,
    l.smp_latin_ultimo_periodo
FROM obras o
LEFT JOIN sacm s  ON s.song_id = o.song_id
LEFT JOIN latin l ON l.song_id = o.song_id
LEFT JOIN iswc iw ON iw.song_id = o.song_id
WHERE s.song_id IS NOT NULL OR l.song_id IS NOT NULL
ORDER BY total_recaudado_usd DESC, o.song_id
;
