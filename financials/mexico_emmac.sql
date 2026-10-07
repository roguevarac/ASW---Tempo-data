-- =====================================================================
-- CUÁNTO GENERÓ CADA OBRA EN MÉXICO (fuente EMMAC), EN PESOS Y EN DÓLARES
--
-- Obras: public.rankingdigital_song_id (columna song_id).
-- Lee dp_statement_lines.statement_lines_v una sola vez, filtrando directo por
-- obra, oficina que procesó (México) y fuente (EMMAC). Mismo criterio que la
-- query de YouTube - USA: líneas de statement finalizadas.
--
-- Por qué la oficina México y no la de Estados Unidos: EMMAC se cobra en México.
-- Las líneas de la oficina México tienen TODO lo que recaudó la obra ahí. A
-- Estados Unidos llega después, como "SMP Mexico / EMMAC A EN P", solo la parte
-- de los clientes de Estados Unidos y ya descontado lo que retuvo México (ver
-- mexico_emmac_validacion_usa.sql).
--
-- Columnas:
--   gross_moneda_local   lc_gross_stmt_am: lo que informó EMMAC, antes de
--                        retenciones y comisiones (en la moneda del statement).
--   neto_moneda_local    converted_net_am: lo que quedó para repartir en la oficina
--                        México, después de conversión, comisión y retención.
--   gross_usd, neto_usd  lo mismo en dólares, con el tipo de cambio a USD de cada
--                        statement (exchange_to_us_currency).
--   tc_usd_min/max       rango de tipos de cambio usados.
--   neto_sobre_gross     control: debería estar entre 0,7 y 1. Si da cerca de 0,05
--                        o de 20, gross y neto están en monedas distintas: avisar.
--
-- Tipo de cambio: Tempo no documenta si exchange_to_us_currency multiplica o
-- divide. Para el peso no hay duda: si el valor es mayor a 1 (ej. 18,5 pesos por
-- dólar) se divide; si es menor a 1 (ej. 0,054 dólares por peso) se multiplica.
-- Si la oficina ya trabajara en dólares, el tipo es 1 y el monto queda igual.
-- =====================================================================
WITH
sl AS (
    SELECT
        s.song_id,
        s.song_title,
        s.processing_office_name,
        s.source_name,
        s.sub_source_name,
        s.income_type_name,
        s.semiannual_statement_period,
        s.lc_gross_stmt_am,
        s.converted_net_am,
        s.exchange_to_us_currency AS tc_usd,
        CASE
            WHEN s.exchange_to_us_currency IS NULL OR s.exchange_to_us_currency = 0 THEN NULL
            WHEN s.exchange_to_us_currency > 1 THEN 1 / s.exchange_to_us_currency
            ELSE s.exchange_to_us_currency
        END AS factor_usd
    FROM dp_statement_lines.statement_lines_v s
    WHERE s.song_id IN (SELECT song_id FROM public.rankingdigital_song_id WHERE song_id IS NOT NULL)
      AND s.processing_office_name LIKE 'Mexico%'
      AND (s.source_name LIKE '%EMMAC%' OR s.sub_source_name LIKE '%EMMAC%')
      AND s.statement_line_status = 'Finalized'
      -- Filtro opcional por período (sacar el -- para usarlo):
      -- AND s.semiannual_statement_period BETWEEN DATE '2024-01-01' AND DATE '2026-12-31'
)
SELECT
    song_id,
    MAX(song_title)                                                      AS song_title,
    processing_office_name,
    source_name,
    sub_source_name,
    income_type_name,
    MIN(semiannual_statement_period)                                     AS primer_periodo,
    MAX(semiannual_statement_period)                                     AS ultimo_periodo,
    COUNT(*)                                                             AS lineas,
    CAST(SUM(lc_gross_stmt_am)               AS NUMERIC(18,2))           AS gross_moneda_local,
    CAST(SUM(converted_net_am)               AS NUMERIC(18,2))           AS neto_moneda_local,
    CAST(SUM(lc_gross_stmt_am * factor_usd)  AS NUMERIC(18,2))           AS gross_usd,
    CAST(SUM(converted_net_am * factor_usd)  AS NUMERIC(18,2))           AS neto_usd,
    MIN(tc_usd)                                                          AS tc_usd_min,
    MAX(tc_usd)                                                          AS tc_usd_max,
    SUM(CASE WHEN factor_usd IS NULL THEN 1 ELSE 0 END)                  AS lineas_sin_tc,
    CAST(SUM(converted_net_am) / NULLIF(SUM(lc_gross_stmt_am), 0) AS NUMERIC(8,4)) AS neto_sobre_gross
FROM sl
GROUP BY song_id, processing_office_name, source_name, sub_source_name, income_type_name
ORDER BY song_id, source_name, sub_source_name, income_type_name;
