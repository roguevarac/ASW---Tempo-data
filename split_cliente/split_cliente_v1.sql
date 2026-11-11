-- =====================================================================
-- SPLIT DE LAS OBRAS DE UN CLIENTE, POR TERRITORIO — v1 (una sola sentencia)
--
-- Todas las obras asociadas a un client_id (dp_deal_metadata.client_contract_song_v,
-- activas e inactivas, marcado) con su split completo de Tempo: una fila por obra
-- + territorio del split (grupo IP) + writer + publisher, como la pestaña IP.
-- El split no se expande por país: cada fila dice para qué territorios vale
-- (el grupo IP de Tempo, ej. "All Other Contractual Territories",
-- "MEXICO, PHILIPPINES (REG)") y el Include / Exclude del contrato asociado.
--
-- EDITABLE: el client_id, en el bloque "parametros".
--
-- Columnas por obra (se repiten en cada fila de la obra):
--   * ISWC: el preferido (preferred_indicator = 'Yes'); si hay más de uno, el
--     menor; si no hay preferido, el menor de todos y iswc_preferido = 'No'.
--     cantidad_iswc y otros_iswc muestran los demás.
--   * Vencimiento: contratos del cliente en la obra con su vencimiento
--     (contract_v.contract_expiration_dt), estado (VIGENTE / VENCIDO / MIXTO /
--     SIN VENCIMIENTO) y obra NOP (song_v.song_not_ours_dt).
-- Columnas por fila de split:
--   * writer, capacidad, contribución y % del writer (writer_*_pc se repiten en
--     cada publisher de su cadena: no sumarlos entre filas);
--   * publisher, capacidad, control (Yes/No) y % owned / mech / perf / sync;
--   * contrato asociado con vencimiento y su Include / Exclude
--     (contract_territories; vacío si no tiene línea de control activa);
--   * es_contrato_del_cliente: si el contrato asociado es de este cliente;
--   * total controlado SMP del territorio (suma de publishers con control Yes,
--     igual a "Publisher Controlled" de Tempo).
--
-- Lecturas: song_share_detail_mv 2 (split y lista de contratos para contract_v),
-- song_v 1, contract_v 1, identifiers_iswc_v 1, contract_territories 1, todas
-- filtradas a las obras del cliente. Si el resultado pasa de 100.000 filas, usar
-- un UNLOAD (ver split_cliente/README.md).
-- =====================================================================
WITH
parametros AS (
    SELECT CAST(1738984 AS BIGINT) AS client_id   -- EDITABLE: client_id
),

-- 1. Obras y contratos del cliente.
cliente_obras AS (
    SELECT DISTINCT
        CAST(c.client_id AS BIGINT)        AS client_id,
        c.client_name,
        CAST(c.contract_id AS BIGINT)      AS contract_id,
        c.contract_nm,
        CAST(c.song_id AS BIGINT)          AS song_id,
        c.active_ind
    FROM dp_deal_metadata.client_contract_song_v c
    WHERE c.client_id = (SELECT client_id FROM parametros)
),

-- 2. Vencimiento de los contratos del cliente y de los contratos asociados del split.
vinfo AS (
    SELECT CAST(contract_id AS BIGINT) AS contract_id, MAX(contract_expiration_dt) AS venc
    FROM dp_deal_metadata.contract_v
    WHERE contract_id IN (
              SELECT contract_id FROM cliente_obras
              UNION
              SELECT associated_contract_id
              FROM dp_song_metadata.song_share_detail_mv
              WHERE song_id IN (SELECT song_id FROM cliente_obras)
                AND associated_contract_id IS NOT NULL
          )
    GROUP BY contract_id
),

-- 4. Obra NOP y título.
song_info AS (
    SELECT CAST(song_id AS BIGINT) AS song_id,
           MAX(song_title_tx)      AS song_title_tx,
           MAX(song_not_ours_dt)   AS song_not_ours_dt
    FROM dp_song_metadata.song_v
    WHERE song_id IN (SELECT song_id FROM cliente_obras)
    GROUP BY song_id
),

-- 5. ISWC: preferido primero ('Yes'), sin conflicto antes que con conflicto, menor código.
iswc AS (
    SELECT
        song_id,
        MAX(CASE WHEN rn = 1 THEN iswc END)                                      AS iswc,
        MAX(CASE WHEN rn = 1 THEN preferido END)                                 AS iswc_preferido,
        COUNT(*)                                                                 AS cantidad_iswc,
        NULLIF(LISTAGG(CASE WHEN rn > 1 THEN iswc || CASE WHEN preferido = 'Yes' THEN ' (pref.)' ELSE '' END END, ' | ')
                   WITHIN GROUP (ORDER BY rn), '')                               AS otros_iswc
    FROM (
        SELECT
            CAST(i.tempo_song_id AS BIGINT) AS song_id,
            i.ident_iswc_cd                 AS iswc,
            CASE WHEN i.preferred_indicator IN ('Yes', 'Y') THEN 'Yes' ELSE 'No' END AS preferido,
            ROW_NUMBER() OVER (
                PARTITION BY i.tempo_song_id
                ORDER BY CASE WHEN i.preferred_indicator IN ('Yes', 'Y') THEN 0 ELSE 1 END,
                         CASE WHEN i.conflict_indicator IN ('Yes', 'Y') THEN 1 ELSE 0 END,
                         i.ident_iswc_cd
            ) AS rn
        FROM (
            SELECT DISTINCT tempo_song_id, ident_iswc_cd, preferred_indicator, conflict_indicator
            FROM dp_song_metadata.identifiers_iswc_v
            WHERE tempo_song_id IN (SELECT song_id FROM cliente_obras)
              AND ident_iswc_cd IS NOT NULL
        ) i
    ) r
    GROUP BY song_id
),

-- 6. Territorio de cada contrato en cada obra (una fila por obra + contrato).
territorio_ct AS (
    SELECT song_id, contract_id, texto
    FROM (
        SELECT
            CAST(ct.song_id AS BIGINT)     AS song_id,
            CAST(ct.contract_id AS BIGINT) AS contract_id,
            COALESCE(ct.inclusions, '') || COALESCE(' / ' || NULLIF(TRIM(ct.exclusions), ''), '') AS texto,
            ROW_NUMBER() OVER (PARTITION BY ct.song_id, ct.contract_id ORDER BY ct.contract_nm) AS rn
        FROM dp_song_metadata.contract_territories ct
        WHERE ct.song_id IN (SELECT song_id FROM cliente_obras)
    ) x
    WHERE rn = 1
),

-- 7. Flujo único: contratos del cliente (C) y split (S), con vencimiento cruzado una vez.
base AS (
    SELECT
        CAST('C' AS VARCHAR(1))                         AS tipo,
        co.song_id,
        CAST(co.client_name AS VARCHAR(1000))           AS client_name,
        CAST(co.active_ind AS VARCHAR(5))               AS active_ind,
        CAST(NULL AS VARCHAR(2000))                     AS song_title_tx,
        CAST(NULL AS VARCHAR(2000))                     AS territorio_split,
        CAST(NULL AS BIGINT)                            AS writer_id,
        CAST(NULL AS VARCHAR(1000))                     AS writer_nm,
        CAST(NULL AS VARCHAR(20))                       AS writer_capacidad,
        CAST(NULL AS DECIMAL(12,4))                     AS writer_contribution_pc,
        CAST(NULL AS DECIMAL(12,4))                     AS writer_mechanical_pc,
        CAST(NULL AS DECIMAL(12,4))                     AS writer_performance_pc,
        CAST(NULL AS DECIMAL(12,4))                     AS writer_sync_pc,
        CAST(NULL AS BIGINT)                            AS publisher_id,
        CAST(NULL AS VARCHAR(1000))                     AS publisher_name_tx,
        CAST(NULL AS VARCHAR(20))                       AS publisher_capacidad,
        CAST(NULL AS VARCHAR(10))                       AS ctrl,
        CAST(NULL AS DECIMAL(12,4))                     AS publisher_control_pc,
        CAST(NULL AS DECIMAL(12,4))                     AS publisher_mechanical_pc,
        CAST(NULL AS DECIMAL(12,4))                     AS publisher_performance_pc,
        CAST(NULL AS DECIMAL(12,4))                     AS publisher_sync_pc,
        co.contract_id,
        CAST(co.contract_nm AS VARCHAR(1000))           AS contract_nm
    FROM cliente_obras co
    UNION ALL
    SELECT
        CAST('S' AS VARCHAR(1)),
        CAST(s.song_id AS BIGINT),
        CAST(NULL AS VARCHAR(1000)),
        CAST(NULL AS VARCHAR(5)),
        CAST(s.song_title_tx AS VARCHAR(2000)),
        CAST(TRIM(s.song_ip_territory_nm) AS VARCHAR(2000)),
        CAST(s.writer_id AS BIGINT),
        CAST(s.writer_nm AS VARCHAR(1000)),
        CAST(s.writer_capacity_type_cd AS VARCHAR(20)),
        CAST(s.writer_contribution_pc AS DECIMAL(12,4)),
        CAST(s.writer_mechanical_pc AS DECIMAL(12,4)),
        CAST(s.writer_performance_pc AS DECIMAL(12,4)),
        CAST(s.writer_sync_pc AS DECIMAL(12,4)),
        CAST(s.publisher_id AS BIGINT),
        CAST(s.publisher_name_tx AS VARCHAR(1000)),
        CAST(s.publisher_capacity_type_cd AS VARCHAR(20)),
        CAST(s.smp_controlled_ind AS VARCHAR(10)),
        CAST(s.publisher_control_pc AS DECIMAL(12,4)),
        CAST(s.publisher_mechanical_pc AS DECIMAL(12,4)),
        CAST(s.publisher_performance_pc AS DECIMAL(12,4)),
        CAST(s.publisher_sync_pc AS DECIMAL(12,4)),
        CAST(s.associated_contract_id AS BIGINT),
        CAST(s.associated_contract_nm AS VARCHAR(1000))
    FROM dp_song_metadata.song_share_detail_mv s
    WHERE s.song_id IN (SELECT song_id FROM cliente_obras)
),
flujo AS (
    SELECT
        b.*,
        v.venc,
        CASE WHEN b.contract_id IS NULL THEN NULL
             WHEN v.venc IS NULL THEN 'sin venc.'
             WHEN v.venc < CURRENT_DATE THEN 'VENCIDO ' || CAST(CAST(v.venc AS DATE) AS VARCHAR(10))
             ELSE 'vig. ' || CAST(CAST(v.venc AS DATE) AS VARCHAR(10)) END AS venc_txt
    FROM base b
    LEFT JOIN vinfo v ON v.contract_id = b.contract_id
),
-- 8. Marcas por obra (contratos del cliente) y por territorio (total controlado).
marcado AS (
    SELECT
        f.*,
        MAX(f.client_name) OVER (PARTITION BY f.song_id)                                              AS cliente_nm,
        MAX(CASE WHEN f.tipo = 'C' AND f.active_ind = 'Y' THEN 'Y' ELSE 'N' END) OVER (PARTITION BY f.song_id) AS activa_en_cliente,
        SUM(CASE WHEN f.tipo = 'C' THEN 1 ELSE 0 END) OVER (PARTITION BY f.song_id)                   AS n_contratos,
        SUM(CASE WHEN f.tipo = 'C' AND f.venc < CURRENT_DATE THEN 1 ELSE 0 END) OVER (PARTITION BY f.song_id)  AS n_vencidos,
        SUM(CASE WHEN f.tipo = 'C' AND f.venc >= CURRENT_DATE THEN 1 ELSE 0 END) OVER (PARTITION BY f.song_id) AS n_vigentes,
        MIN(CASE WHEN f.tipo = 'C' THEN f.venc END) OVER (PARTITION BY f.song_id)                     AS venc_proximo,
        MAX(CASE WHEN f.tipo = 'C' THEN f.venc END) OVER (PARTITION BY f.song_id)                     AS venc_lejano,
        SUM(CASE WHEN f.tipo = 'S' THEN 1 ELSE 0 END) OVER (PARTITION BY f.song_id)                   AS n_split,
        MAX(f.song_title_tx) OVER (PARTITION BY f.song_id)                                            AS titulo_mv,
        MAX(CASE WHEN f.tipo = 'C' THEN 1 ELSE 0 END) OVER (PARTITION BY f.song_id, f.contract_id)    AS contrato_del_cliente,
        SUM(CASE WHEN f.tipo = 'S' AND f.ctrl = 'Y' THEN f.publisher_performance_pc ELSE 0 END)
            OVER (PARTITION BY f.song_id, f.territorio_split)                                         AS ctrl_perf_territorio,
        SUM(CASE WHEN f.tipo = 'S' AND f.ctrl = 'Y' THEN f.publisher_mechanical_pc ELSE 0 END)
            OVER (PARTITION BY f.song_id, f.territorio_split)                                         AS ctrl_mech_territorio,
        SUM(CASE WHEN f.tipo = 'S' AND f.ctrl = 'Y' THEN f.publisher_sync_pc ELSE 0 END)
            OVER (PARTITION BY f.song_id, f.territorio_split)                                         AS ctrl_sync_territorio,
        ROW_NUMBER() OVER (PARTITION BY f.song_id, f.tipo, f.contract_id ORDER BY f.active_ind DESC)  AS rn_contrato,
        ROW_NUMBER() OVER (PARTITION BY f.song_id, f.tipo
                           ORDER BY f.territorio_split, f.writer_nm, f.publisher_name_tx, f.publisher_id, f.contract_id) AS rid
    FROM flujo f
),
-- 9. Una fila por fila de split (S) y una por obra con la lista de contratos del cliente (C).
agrupado AS (
    SELECT
        m.song_id,
        m.tipo,
        CASE WHEN m.tipo = 'S' THEN m.rid ELSE 0 END AS rid,
        MAX(m.cliente_nm) AS cliente_nm, MAX(m.activa_en_cliente) AS activa_en_cliente,
        MAX(m.n_contratos) AS n_contratos, MAX(m.n_vencidos) AS n_vencidos, MAX(m.n_vigentes) AS n_vigentes,
        MAX(m.venc_proximo) AS venc_proximo, MAX(m.venc_lejano) AS venc_lejano, MAX(m.n_split) AS n_split,
        MAX(m.titulo_mv) AS titulo_mv,
        MAX(m.territorio_split) AS territorio_split, MAX(m.writer_id) AS writer_id, MAX(m.writer_nm) AS writer_nm,
        MAX(m.writer_capacidad) AS writer_capacidad, MAX(m.writer_contribution_pc) AS writer_contribution_pc,
        MAX(m.writer_mechanical_pc) AS writer_mechanical_pc, MAX(m.writer_performance_pc) AS writer_performance_pc,
        MAX(m.writer_sync_pc) AS writer_sync_pc, MAX(m.publisher_id) AS publisher_id,
        MAX(m.publisher_name_tx) AS publisher_name_tx, MAX(m.publisher_capacidad) AS publisher_capacidad,
        MAX(m.ctrl) AS ctrl, MAX(m.publisher_control_pc) AS publisher_control_pc,
        MAX(m.publisher_mechanical_pc) AS publisher_mechanical_pc, MAX(m.publisher_performance_pc) AS publisher_performance_pc,
        MAX(m.publisher_sync_pc) AS publisher_sync_pc,
        MAX(CASE WHEN m.tipo = 'S' THEN m.contract_id END) AS contract_id,
        MAX(CASE WHEN m.tipo = 'S' THEN m.contract_nm END) AS contract_nm,
        MAX(CASE WHEN m.tipo = 'S' THEN m.venc_txt END)    AS venc_txt,
        MAX(m.contrato_del_cliente) AS contrato_del_cliente,
        MAX(m.ctrl_perf_territorio) AS ctrl_perf_territorio, MAX(m.ctrl_mech_territorio) AS ctrl_mech_territorio,
        MAX(m.ctrl_sync_territorio) AS ctrl_sync_territorio,
        LISTAGG(CASE WHEN m.tipo = 'C' AND m.rn_contrato = 1
                     THEN CAST(m.contract_id AS VARCHAR(20)) || ' - ' || COALESCE(m.contract_nm, 'Sin nombre')
                          || ' [' || m.venc_txt || CASE WHEN m.active_ind = 'Y' THEN '' ELSE '; inactivo' END || ']' END, ' | ')
            WITHIN GROUP (ORDER BY m.contract_id) AS contratos_cliente
    FROM marcado m
    GROUP BY m.song_id, m.tipo, CASE WHEN m.tipo = 'S' THEN m.rid ELSE 0 END
),
con_obra AS (
    SELECT
        a.*,
        MAX(CASE WHEN a.tipo = 'C' THEN a.contratos_cliente END) OVER (PARTITION BY a.song_id) AS contratos_cliente_obra
    FROM agrupado a
)

SELECT
    (SELECT client_id FROM parametros)                          AS client_id,
    t.cliente_nm                                                AS client_name,
    t.song_id,
    COALESCE(si.song_title_tx, t.titulo_mv, 'Sin título')       AS song_title,
    iw.iswc,
    iw.iswc_preferido,
    COALESCE(iw.cantidad_iswc, 0)                               AS cantidad_iswc,
    iw.otros_iswc,
    CASE WHEN si.song_not_ours_dt IS NOT NULL AND si.song_not_ours_dt <= CURRENT_DATE
         THEN 'VENCIDA (NOP)' ELSE 'ACTIVA' END                 AS estado_obra,
    si.song_not_ours_dt,
    t.activa_en_cliente,
    t.contratos_cliente_obra                                    AS contratos_cliente,
    t.venc_proximo                                              AS contrato_cliente_venc_mas_proximo,
    t.venc_lejano                                               AS contrato_cliente_venc_mas_lejano,
    CASE
        WHEN t.n_vencidos = t.n_contratos THEN 'TODOS VENCIDOS'
        WHEN t.n_vencidos > 0             THEN 'MIXTO (alguno vencido)'
        WHEN t.n_vigentes = 0             THEN 'SIN VENCIMIENTO'
        ELSE 'VIGENTE'
    END                                                         AS estado_contratos_cliente,
    CASE WHEN t.n_split = 0 THEN 'OBRA SIN SPLIT EN song_share_detail_mv' END AS aviso,
    t.territorio_split,
    t.writer_id,
    t.writer_nm,
    t.writer_capacidad,
    t.writer_contribution_pc,
    t.writer_mechanical_pc,
    t.writer_performance_pc,
    t.writer_sync_pc,
    t.publisher_id,
    t.publisher_name_tx                                         AS publisher,
    t.publisher_capacidad,
    CASE WHEN t.ctrl = 'Y' THEN 'Yes' WHEN t.ctrl = 'N' THEN 'No' END AS control,
    t.publisher_control_pc                                      AS publisher_owned_pc,
    t.publisher_mechanical_pc,
    t.publisher_performance_pc,
    t.publisher_sync_pc,
    CASE WHEN t.contract_id IS NOT NULL
         THEN CAST(t.contract_id AS VARCHAR(20)) || ' - ' || COALESCE(t.contract_nm, 'Sin nombre') END AS contrato_asociado,
    t.venc_txt                                                  AS contrato_asociado_venc,
    tc.texto                                                    AS territorio_contrato_asociado,
    CASE WHEN t.contract_id IS NULL THEN NULL
         WHEN t.contrato_del_cliente = 1 THEN 'Y' ELSE 'N' END  AS es_contrato_del_cliente,
    CASE WHEN t.tipo = 'S' THEN t.ctrl_perf_territorio END      AS smp_controlado_perf_territorio,
    CASE WHEN t.tipo = 'S' THEN t.ctrl_mech_territorio END      AS smp_controlado_mech_territorio,
    CASE WHEN t.tipo = 'S' THEN t.ctrl_sync_territorio END      AS smp_controlado_sync_territorio
FROM con_obra t
LEFT JOIN song_info si          ON si.song_id = t.song_id
LEFT JOIN iswc iw               ON iw.song_id = t.song_id
LEFT JOIN territorio_ct tc      ON tc.song_id = t.song_id AND tc.contract_id = t.contract_id
WHERE t.tipo = 'S' OR t.n_split = 0
ORDER BY t.song_id, t.territorio_split, t.writer_nm, t.publisher_name_tx
;
