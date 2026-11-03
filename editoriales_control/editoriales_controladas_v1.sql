-- =====================================================================
-- EDITORIALES CON CONTROL SMP POR OBRA Y TERRITORIO — v1 (una sola sentencia)
--
-- Una fila por obra + territorio IP + editorial con control "Yes" en Tempo
-- (song_share_detail_mv.smp_controlled_ind = 'Y'), con su IPI. Una obra que se
-- controla distinto según el territorio sale con una fila por territorio IP
-- (ej. Baba O'Riley 2701309: "All Other Contractual Territories" y
-- "MEXICO, PHILIPPINES (REG)").
--
-- Territorio de control:
--   * territorio_ip        : grupo de territorio IP de Tempo (song_ip_territory_nm).
--   * contrato_asociado    : contrato de la participación con su texto de
--                            territorio (Include / Exclude) de contract_territories.
--                            Si el contrato no tiene línea de control activa, lo indica.
--   * lineas_control_obra  : TODAS las líneas de control de la obra con su
--                            Include / Exclude. Es la referencia para el territorio
--                            controlado: puede incluir contratos que la participación
--                            no menciona (Baba O'Riley: ABKCO Music International
--                            Limited, Include: World / Exclude: ...).
--   El grupo "All (Other) Contractual Territories" significa "los demás
--   territorios contratados" (los de las líneas de control).
--
-- Las obras sin ninguna editorial controlada NO salen (pedido del usuario,
-- 03/11/2026). Un Tempo ID que no figura en song_share_detail_mv NO
-- aparece (no es song_type 1 / secuencia 0, o un writer sin sociedad la saca de
-- la MV): comparar la cantidad de obras del resultado con la de la lista.
--
-- OBRAS: se escriben en el único IN de la query (buscar "EDITABLE").
--
-- IPI de la editorial: dp_writer_data.publisher_v.cae_num (LEFT JOIN; vacío si
-- no está cargado; numérico, sin ceros a la izquierda).
--
-- Rendimiento: song_share_detail_mv y contract_territories se leen UNA vez cada
-- una, en un único flujo filtrado por el IN; los cruces se resuelven con
-- funciones de ventana. Todos los LISTAGG del bloque 4 ordenan por "orden".
-- =====================================================================
WITH
-- 1. Única lectura de las dos fuentes. M = participaciones, L = líneas de control.
fuente AS (
    SELECT *
    FROM (
        SELECT
            'M'                                   AS tipo,
            s.song_id,
            s.song_title_tx,
            s.smp_controlled_ind                  AS ctrl,
            s.publisher_id,
            s.publisher_name_tx,
            s.writer_id,
            s.writer_nm,
            s.associated_contract_id              AS contract_id,
            s.associated_contract_nm              AS contract_nm,
            TRIM(s.song_ip_territory_nm)          AS territorio_ip,
            CAST(NULL AS VARCHAR(65535))          AS texto_linea
        FROM dp_song_metadata.song_share_detail_mv s
        UNION ALL
        SELECT
            'L',
            ct.song_id,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            ct.contract_id,
            ct.contract_nm,
            NULL,
            ct.contract_nm || ' (' || COALESCE(ct.inclusions, '') || COALESCE(' / ' || NULLIF(TRIM(ct.exclusions), ''), '') || ')'
        FROM dp_song_metadata.contract_territories ct
    ) u
    -- EDITABLE: Tempo ID de las obras, separados por coma.
    WHERE u.song_id IN (111111, 222222, 333333)
),

-- 2. Marcas sobre el flujo único.
marcado AS (
    SELECT
        f.*,
        MAX(CASE WHEN f.tipo = 'M' AND f.ctrl = 'Y' THEN 1 ELSE 0 END) OVER (PARTITION BY f.song_id) AS tiene_ctrl,
        MAX(f.song_title_tx) OVER (PARTITION BY f.song_id)                                       AS titulo,
        -- texto de territorio del contrato asociado (de la línea de control del mismo contrato)
        MAX(CASE WHEN f.tipo = 'L' THEN f.texto_linea END) OVER (PARTITION BY f.song_id, f.contract_id) AS texto_contrato,
        ROW_NUMBER() OVER (PARTITION BY f.song_id, f.tipo
                           ORDER BY f.publisher_id, f.territorio_ip, f.writer_id)               AS rn_obra,
        -- contract_territories puede repetir obra+contrato: una sola línea por contrato
        ROW_NUMBER() OVER (PARTITION BY f.song_id, f.tipo, f.contract_id ORDER BY f.contract_nm) AS rn_linea,
        ROW_NUMBER() OVER (PARTITION BY f.song_id, f.tipo, f.territorio_ip, f.publisher_id, f.writer_id
                           ORDER BY f.contract_id)                                              AS rn_writer,
        ROW_NUMBER() OVER (PARTITION BY f.song_id, f.tipo, f.territorio_ip, f.publisher_id, f.contract_id
                           ORDER BY f.writer_id)                                                AS rn_contrato
    FROM fuente f
),

-- 3. Filas útiles: participaciones controladas (o una fila para la obra sin
--    ninguna) y una línea de control por contrato.
filas AS (
    SELECT *
    FROM marcado
    WHERE (tipo = 'M' AND (ctrl = 'Y' OR (tiene_ctrl = 0 AND rn_obra = 1)))
       OR (tipo = 'L' AND rn_linea = 1)
),

-- 4. Una fila por obra + territorio IP + editorial (tipo M) y una fila por obra
--    con todas sus líneas de control (tipo L).
agrupado AS (
    SELECT
        f.song_id,
        f.tipo,
        f.territorio_ip,
        f.publisher_id,
        MAX(f.titulo)            AS titulo,
        MAX(f.tiene_ctrl)        AS tiene_ctrl,
        MAX(f.publisher_name_tx) AS publisher_name_tx,
        LISTAGG(CASE WHEN f.tipo = 'M' AND f.rn_writer = 1 AND f.writer_id IS NOT NULL
                     THEN f.writer_nm || ' (' || CAST(f.writer_id AS VARCHAR(20)) || ')' END, ' | ')
            WITHIN GROUP (ORDER BY f.orden) AS writers_representados,
        LISTAGG(CASE WHEN f.tipo = 'M' AND f.rn_contrato = 1 AND f.contract_id IS NOT NULL
                     THEN COALESCE(f.texto_contrato,
                                   f.contract_nm || ' (sin línea de control activa)') END, ' | ')
            WITHIN GROUP (ORDER BY f.orden) AS contrato_asociado,
        LISTAGG(CASE WHEN f.tipo = 'L' THEN f.texto_linea END, ' | ')
            WITHIN GROUP (ORDER BY f.orden) AS lineas_control
    FROM (
        SELECT x.*,
               CASE WHEN x.tipo = 'L' THEN COALESCE(x.contract_nm, '') ELSE COALESCE(x.writer_nm, '') END AS orden
        FROM filas x
    ) f
    GROUP BY f.song_id, f.tipo, f.territorio_ip, f.publisher_id
),

-- 5. Las líneas de control de la obra pasan a cada fila de editorial.
con_lineas AS (
    SELECT
        a.*,
        MAX(CASE WHEN a.tipo = 'L' THEN a.lineas_control END) OVER (PARTITION BY a.song_id) AS lineas_control_obra
    FROM agrupado a
)

-- 6. Resultado: solo obras con alguna editorial controlada (las no controladas no salen).
SELECT
    CAST(e.song_id AS BIGINT)  AS tempo_id,
    e.titulo                   AS song_title,
    e.territorio_ip            AS territorio_ip,
    e.publisher_name_tx        AS editorial_controlada,
    p.cae_num                  AS ipi_editorial,
    e.publisher_id             AS publisher_id,
    e.writers_representados    AS writers_representados,
    e.contrato_asociado        AS contrato_asociado,
    e.lineas_control_obra      AS lineas_control_obra
FROM con_lineas e
LEFT JOIN dp_writer_data.publisher_v p
       ON p.publisher_id = e.publisher_id
WHERE e.tipo = 'M'
  AND e.tiene_ctrl = 1
ORDER BY tempo_id, territorio_ip, editorial_controlada
;
