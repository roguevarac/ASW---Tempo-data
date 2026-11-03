-- =====================================================================
-- EDITORIALES CON CONTROL SMP POR OBRA — v1 (una sola sentencia)
--
-- Una fila por obra + editorial con control "Yes" en Tempo
-- (song_share_detail_mv.smp_controlled_ind = 'Y').
-- Las obras que no tienen ninguna editorial controlada también salen, en una
-- sola fila, con estado SIN EDITORIAL CONTROLADA.
--   * CONTROLADA                 : editorial con control Yes.
--   * SIN EDITORIAL CONTROLADA   : la obra tiene participaciones, ninguna con control Yes.
-- Un Tempo ID que no figura en song_share_detail_mv NO aparece en el resultado
-- (no es song_type 1 / secuencia 0, o un writer sin sociedad la saca de la MV):
-- comparar la cantidad de obras del resultado con la de la lista.
--
-- OBRAS: se escriben en el IN del bloque 1 (buscar "EDITABLE"), separadas por coma.
--
-- Porcentajes: son los publisher_*_pc (collectable) de la editorial, sumados
-- entre los writers que representa DENTRO de cada grupo IP. Nunca se suman
-- grupos IP entre sí ni porcentajes writer_*. El detalle por grupo va en
-- "detalle_por_grupo_ip"; las columnas numéricas dan el mínimo y el máximo
-- entre grupos (si coinciden, el porcentaje es el mismo en todo el mundo).
--
-- IPI de la editorial: dp_writer_data.publisher_v.cae_num (CAE/IPI name number),
-- con LEFT JOIN: una editorial sin IPI cargado sale con el IPI vacío.
-- Requiere permiso de lectura sobre dp_writer_data; si no lo hay, la query falla
-- con "permission denied for schema dp_writer_data".
--
-- Rendimiento: song_share_detail_mv se nombra UNA vez (cadena lineal, cruces
-- con funciones de ventana). Todos los LISTAGG ordenan por la misma columna
-- "orden": cada fila se repite por tipo de lista (bloque "listas").
-- =====================================================================
WITH
-- 1. Única lectura de la MV, filtrada a las obras pedidas. DISTINCT quita
--    filas idénticas (misma editorial y writer repetidos por nivel).
mv AS (
    SELECT DISTINCT
        CAST(s.song_id AS BIGINT)                         AS song_id,
        s.song_title_tx,
        s.smp_controlled_ind                              AS ctrl,
        s.publisher_id,
        s.publisher_name_tx,
        s.publisher_capacity_type_cd                      AS capacidad,
        s.writer_id,
        s.writer_nm,
        s.associated_contract_id                          AS contract_id,
        s.associated_contract_nm                          AS contract_nm,
        UPPER(TRIM(COALESCE(s.song_ip_territory_nm, ''))) AS grupo_ip,
        COALESCE(s.publisher_performance_pc, 0)           AS perf,
        COALESCE(s.publisher_mechanical_pc, 0)            AS mech,
        COALESCE(s.publisher_sync_pc, 0)                  AS sync
    FROM dp_song_metadata.song_share_detail_mv s
    -- EDITABLE: Tempo ID de las obras, separados por coma.
    WHERE s.song_id IN (111111, 222222, 333333)
),

-- 2. Marcas sobre el flujo único: si la obra tiene alguna editorial
--    controlada, totales por editorial y grupo IP, y primeras apariciones
--    para las listas (en lugar de LISTAGG DISTINCT).
marcado AS (
    SELECT
        m.*,
        MAX(CASE WHEN m.ctrl = 'Y' THEN 1 ELSE 0 END) OVER (PARTITION BY m.song_id) AS tiene_ctrl,
        ROW_NUMBER() OVER (PARTITION BY m.song_id ORDER BY m.publisher_id, m.grupo_ip, m.writer_id) AS rn_obra,
        SUM(m.perf) OVER (PARTITION BY m.song_id, m.publisher_id, m.grupo_ip) AS perf_grupo,
        SUM(m.mech) OVER (PARTITION BY m.song_id, m.publisher_id, m.grupo_ip) AS mech_grupo,
        SUM(m.sync) OVER (PARTITION BY m.song_id, m.publisher_id, m.grupo_ip) AS sync_grupo,
        ROW_NUMBER() OVER (PARTITION BY m.song_id, m.publisher_id, m.grupo_ip
                           ORDER BY m.writer_id, m.contract_id)                AS rn_grupo,
        ROW_NUMBER() OVER (PARTITION BY m.song_id, m.publisher_id, m.writer_id
                           ORDER BY m.grupo_ip, m.contract_id)                 AS rn_writer,
        ROW_NUMBER() OVER (PARTITION BY m.song_id, m.publisher_id, m.contract_id
                           ORDER BY m.grupo_ip, m.writer_id)                   AS rn_contrato,
        ROW_NUMBER() OVER (PARTITION BY m.song_id, m.publisher_id, m.capacidad
                           ORDER BY m.grupo_ip, m.writer_id)                   AS rn_capacidad
    FROM mv m
),

-- 3. Filas útiles: las de editoriales controladas y, para las obras sin
--    ninguna, una sola fila que la represente.
filas AS (
    SELECT *
    FROM marcado
    WHERE ctrl = 'Y'
       OR (tiene_ctrl = 0 AND rn_obra = 1)
),

-- 4. Cada fila se repite por tipo de lista para que todos los LISTAGG ordenen
--    por la misma columna (restricción de Redshift).
tipos AS (
              SELECT 'G' AS tipo
    UNION ALL SELECT 'W'
    UNION ALL SELECT 'C'
    UNION ALL SELECT 'K'
),
listas AS (
    SELECT
        f.*,
        t.tipo,
        CASE t.tipo
            WHEN 'G' THEN f.grupo_ip
            WHEN 'W' THEN COALESCE(f.writer_nm, '')
            WHEN 'C' THEN COALESCE(f.contract_nm, '')
            ELSE COALESCE(f.capacidad, '')
        END AS orden
    FROM filas f
    CROSS JOIN tipos t
),

-- 5. Una fila por obra + editorial.
por_editorial AS (
    SELECT
        l.song_id,
        MAX(l.song_title_tx)                                        AS song_title_tx,
        MAX(l.tiene_ctrl)                                           AS tiene_ctrl,
        l.publisher_id,
        MAX(l.publisher_name_tx)                                    AS publisher_name_tx,
        LISTAGG(CASE WHEN l.tipo = 'K' AND l.rn_capacidad = 1 THEN l.capacidad END, ', ')
            WITHIN GROUP (ORDER BY l.orden)                         AS capacidad,
        LISTAGG(CASE WHEN l.tipo = 'W' AND l.rn_writer = 1 AND l.writer_id IS NOT NULL
                     THEN l.writer_nm || ' (' || CAST(l.writer_id AS VARCHAR(20)) || ')' END, ' | ')
            WITHIN GROUP (ORDER BY l.orden)                         AS writers_representados,
        LISTAGG(CASE WHEN l.tipo = 'C' AND l.rn_contrato = 1 AND l.contract_id IS NOT NULL
                     THEN l.contract_nm || ' (' || CAST(l.contract_id AS VARCHAR(20)) || ')' END, ' | ')
            WITHIN GROUP (ORDER BY l.orden)                         AS contratos_asociados,
        LISTAGG(CASE WHEN l.tipo = 'G' AND l.rn_grupo = 1
                     THEN COALESCE(NULLIF(l.grupo_ip, ''), '(SIN GRUPO)')
                          || ': P ' || CAST(CAST(l.perf_grupo AS DECIMAL(9,2)) AS VARCHAR(20))
                          || ' / M ' || CAST(CAST(l.mech_grupo AS DECIMAL(9,2)) AS VARCHAR(20))
                          || ' / S ' || CAST(CAST(l.sync_grupo AS DECIMAL(9,2)) AS VARCHAR(20)) END, ' | ')
            WITHIN GROUP (ORDER BY l.orden)                         AS detalle_por_grupo_ip,
        SUM(CASE WHEN l.tipo = 'G' AND l.rn_grupo = 1 THEN 1 ELSE 0 END) AS cant_grupos_ip,
        MIN(CASE WHEN l.tipo = 'G' THEN l.perf_grupo END)           AS perf_pc_min,
        MAX(CASE WHEN l.tipo = 'G' THEN l.perf_grupo END)           AS perf_pc_max,
        MIN(CASE WHEN l.tipo = 'G' THEN l.mech_grupo END)           AS mech_pc_min,
        MAX(CASE WHEN l.tipo = 'G' THEN l.mech_grupo END)           AS mech_pc_max,
        MIN(CASE WHEN l.tipo = 'G' THEN l.sync_grupo END)           AS sync_pc_min,
        MAX(CASE WHEN l.tipo = 'G' THEN l.sync_grupo END)           AS sync_pc_max
    FROM listas l
    GROUP BY l.song_id, l.publisher_id
)

-- 6. Resultado. Primero Tempo ID, título, editorial controlada e IPI.
SELECT
    e.song_id                                                        AS tempo_id,
    e.song_title_tx                                                  AS song_title,
    CASE WHEN e.tiene_ctrl = 1 THEN e.publisher_name_tx END          AS editorial_controlada,
    CASE WHEN e.tiene_ctrl = 1 THEN p.cae_num END                    AS ipi_editorial,
    CASE WHEN e.tiene_ctrl = 1 THEN 'CONTROLADA'
         ELSE 'SIN EDITORIAL CONTROLADA' END                         AS estado,
    CASE WHEN e.tiene_ctrl = 1 THEN e.publisher_id END               AS publisher_id,
    CASE WHEN e.tiene_ctrl = 1 THEN e.capacidad END                  AS capacidad,
    CASE WHEN e.tiene_ctrl = 1 THEN e.writers_representados END      AS writers_representados,
    CASE WHEN e.tiene_ctrl = 1 THEN e.contratos_asociados END        AS contratos_asociados,
    CASE WHEN e.tiene_ctrl = 1 THEN e.cant_grupos_ip END             AS cant_grupos_ip,
    CASE WHEN e.tiene_ctrl = 1 THEN e.detalle_por_grupo_ip END       AS detalle_por_grupo_ip,
    CASE WHEN e.tiene_ctrl = 1 THEN e.perf_pc_min END                AS perf_pc_min,
    CASE WHEN e.tiene_ctrl = 1 THEN e.perf_pc_max END                AS perf_pc_max,
    CASE WHEN e.tiene_ctrl = 1 THEN e.mech_pc_min END                AS mech_pc_min,
    CASE WHEN e.tiene_ctrl = 1 THEN e.mech_pc_max END                AS mech_pc_max,
    CASE WHEN e.tiene_ctrl = 1 THEN e.sync_pc_min END                AS sync_pc_min,
    CASE WHEN e.tiene_ctrl = 1 THEN e.sync_pc_max END                AS sync_pc_max
FROM por_editorial e
LEFT JOIN dp_writer_data.publisher_v p
       ON p.publisher_id = e.publisher_id
      AND e.tiene_ctrl = 1
ORDER BY e.song_id, editorial_controlada
;
