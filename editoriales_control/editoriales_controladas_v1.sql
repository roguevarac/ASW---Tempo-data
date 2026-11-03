-- =====================================================================
-- EDITORIALES CON CONTROL SMP POR OBRA Y TERRITORIO — v1 (una sola sentencia)
--
-- Una fila por obra + territorio IP + editorial controlada, con su IPI. Una obra
-- que se controla distinto según el territorio sale con una fila por territorio IP
-- (ej. Baba O'Riley 2701309: "All Other Contractual Territories" y
-- "MEXICO, PHILIPPINES (REG)").
--
-- Qué cuenta como controlada (03/11/2026, pedido del usuario: lo vencido no es
-- control):
--   * Obra vencida (NOP): song_v.song_not_ours_dt <= hoy -> la obra no sale.
--   * La obra necesita al menos una línea de control (contract_territories) con
--     contrato vigente o sin vencimiento (contract_v.contract_expiration_dt).
--   * Editorial controlada = participación con smp_controlled_ind = 'Y' cuyo
--     contrato asociado no está vencido (sin contrato o sin vencimiento cuenta).
--   Si no queda ninguna editorial controlada, la obra no sale.
--
-- Columnas de territorio:
--   * territorio_ip        : grupo de territorio IP de Tempo (song_ip_territory_nm).
--   * contrato_asociado    : contrato de la participación con su Include / Exclude
--                            y su vencimiento.
--   * lineas_control_obra  : TODAS las líneas de control de la obra con Include /
--                            Exclude y vencimiento ([vig.], [sin venc.], [VENCIDO]).
--   El grupo "All (Other) Contractual Territories" significa "los demás
--   territorios contratados" (los de las líneas de control).
--
-- OBRAS: se escriben en el único IN de la query (buscar "EDITABLE"). Una obra
-- sin ninguna línea en contract_territories no sale (no tiene control activo).
--
-- IPI de la editorial: dp_writer_data.publisher_v.cae_num (LEFT JOIN; vacío si
-- no está cargado; numérico, sin ceros a la izquierda).
--
-- Lecturas: contract_territories (tabla, liviana) filtrada por el IN;
-- song_share_detail_mv 2 veces (participaciones y lista de contratos para
-- contract_v), song_v 1, contract_v 1, siempre filtradas a esas obras. Todos los LISTAGG del bloque de
-- agrupación ordenan por "orden".
-- =====================================================================
WITH
-- 0. Obras pedidas: líneas de control de contract_territories.
ct_in AS (
    SELECT ct.song_id, ct.contract_id, ct.contract_nm, ct.inclusions, ct.exclusions
    FROM dp_song_metadata.contract_territories ct
    -- EDITABLE: Tempo ID de las obras, separados por coma.
    WHERE ct.song_id IN (111111, 222222, 333333)
),
-- 1. Vencimiento de los contratos (líneas de control y contratos asociados).
vinfo AS (
    SELECT contract_id, MAX(contract_expiration_dt) AS venc
    FROM dp_deal_metadata.contract_v
    WHERE contract_id IN (
              SELECT contract_id FROM ct_in
              UNION
              SELECT associated_contract_id
              FROM dp_song_metadata.song_share_detail_mv
              WHERE song_id IN (SELECT song_id FROM ct_in)
                AND associated_contract_id IS NOT NULL
          )
    GROUP BY contract_id
),
-- 2. Obra vencida (NOP).
song_info AS (
    SELECT song_id, MAX(song_not_ours_dt) AS song_not_ours_dt
    FROM dp_song_metadata.song_v
    WHERE song_id IN (SELECT song_id FROM ct_in)
    GROUP BY song_id
),
-- 3. Flujo único: participaciones (M) y líneas de control (L); vencimientos y
--    NOP se cruzan una sola vez, después de unir.
base AS (
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
        CAST(NULL AS VARCHAR(65535))          AS territorio_txt
    FROM dp_song_metadata.song_share_detail_mv s
    WHERE s.song_id IN (SELECT song_id FROM ct_in)
    UNION ALL
    SELECT
        'L',
        ct.song_id,
        NULL, NULL, NULL, NULL, NULL, NULL,
        ct.contract_id,
        ct.contract_nm,
        NULL,
        COALESCE(ct.inclusions, '') || COALESCE(' / ' || NULLIF(TRIM(ct.exclusions), ''), '')
    FROM ct_in ct
),
fuente AS (
    SELECT
        b.*,
        v.venc,
        si.song_not_ours_dt,
        CASE WHEN b.tipo = 'L'
             THEN b.contract_nm || ' (' || b.territorio_txt || ') ['
                  || CASE
                         WHEN v.venc IS NULL         THEN 'sin venc.'
                         WHEN v.venc < CURRENT_DATE  THEN 'VENCIDO ' || CAST(CAST(v.venc AS DATE) AS VARCHAR(10))
                         ELSE 'vig. ' || CAST(CAST(v.venc AS DATE) AS VARCHAR(10))
                     END || ']'
        END AS texto_linea
    FROM base b
    LEFT JOIN vinfo v      ON v.contract_id = b.contract_id
    LEFT JOIN song_info si ON si.song_id = b.song_id
),
-- 4. Marcas: participación controlada vigente, línea activa, obra vencida.
marcado AS (
    SELECT
        f.*,
        CASE WHEN f.tipo = 'M' AND f.ctrl = 'Y'
                  AND (f.contract_id IS NULL OR f.venc IS NULL OR f.venc >= CURRENT_DATE)
             THEN 1 ELSE 0 END                                                                   AS es_ctrl,
        MAX(CASE WHEN f.tipo = 'L' AND (f.venc IS NULL OR f.venc >= CURRENT_DATE) THEN 1 ELSE 0 END)
            OVER (PARTITION BY f.song_id)                                                        AS hay_linea_activa,
        MAX(CASE WHEN f.song_not_ours_dt IS NOT NULL AND f.song_not_ours_dt <= CURRENT_DATE THEN 1 ELSE 0 END)
            OVER (PARTITION BY f.song_id)                                                        AS obra_vencida,
        MAX(f.song_title_tx) OVER (PARTITION BY f.song_id)                                       AS titulo,
        MAX(CASE WHEN f.tipo = 'L' THEN f.texto_linea END) OVER (PARTITION BY f.song_id, f.contract_id) AS texto_contrato,
        ROW_NUMBER() OVER (PARTITION BY f.song_id, f.tipo, f.contract_id ORDER BY f.contract_nm)  AS rn_linea,
        ROW_NUMBER() OVER (PARTITION BY f.song_id, f.tipo, f.territorio_ip, f.publisher_id, f.writer_id
                           ORDER BY f.contract_id)                                               AS rn_writer,
        ROW_NUMBER() OVER (PARTITION BY f.song_id, f.tipo, f.territorio_ip, f.publisher_id, f.contract_id
                           ORDER BY f.writer_id)                                                 AS rn_contrato
    FROM fuente f
),
-- 5. Obra controlada: alguna participación controlada vigente, alguna línea
--    activa y la obra no vencida.
obra AS (
    SELECT
        m.*,
        CASE WHEN MAX(m.es_ctrl) OVER (PARTITION BY m.song_id) = 1
                  AND m.hay_linea_activa = 1 AND m.obra_vencida = 0
             THEN 1 ELSE 0 END AS obra_ctrl
    FROM marcado m
),
filas AS (
    SELECT *
    FROM obra
    WHERE obra_ctrl = 1
      AND ((tipo = 'M' AND es_ctrl = 1) OR (tipo = 'L' AND rn_linea = 1))
),
-- 6. Una fila por obra + territorio IP + editorial (M) y una por obra con sus líneas (L).
agrupado AS (
    SELECT
        f.song_id,
        f.tipo,
        f.territorio_ip,
        f.publisher_id,
        MAX(f.titulo)            AS titulo,
        MAX(f.publisher_name_tx) AS publisher_name_tx,
        LISTAGG(CASE WHEN f.tipo = 'M' AND f.rn_writer = 1 AND f.writer_id IS NOT NULL
                     THEN f.writer_nm || ' (' || CAST(f.writer_id AS VARCHAR(20)) || ')' END, ' | ')
            WITHIN GROUP (ORDER BY f.orden) AS writers_representados,
        LISTAGG(CASE WHEN f.tipo = 'M' AND f.rn_contrato = 1 AND f.contract_id IS NOT NULL
                     THEN COALESCE(f.texto_contrato,
                                   f.contract_nm || ' (sin línea de control activa) ['
                                   || CASE WHEN f.venc IS NULL THEN 'sin venc.'
                                           ELSE 'vig. ' || CAST(CAST(f.venc AS DATE) AS VARCHAR(10)) END || ']') END, ' | ')
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
con_lineas AS (
    SELECT
        a.*,
        MAX(CASE WHEN a.tipo = 'L' THEN a.lineas_control END) OVER (PARTITION BY a.song_id) AS lineas_control_obra
    FROM agrupado a
)

-- 7. Resultado: solo editoriales controladas con contrato vigente, en obras no vencidas.
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
ORDER BY tempo_id, territorio_ip, editorial_controlada
;
