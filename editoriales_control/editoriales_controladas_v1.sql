-- =====================================================================
-- EDITORIALES CON CONTROL SMP POR OBRA — v1 (una sola sentencia)
--
-- Una fila por obra + editorial con control "Yes" en Tempo
-- (song_share_detail_mv.smp_controlled_ind = 'Y'), con su IPI.
-- Las obras que no tienen ninguna editorial controlada salen en una sola fila
-- con estado SIN EDITORIAL CONTROLADA.
-- Un Tempo ID que no figura en song_share_detail_mv NO aparece en el resultado
-- (no es song_type 1 / secuencia 0, o un writer sin sociedad la saca de la MV):
-- comparar la cantidad de obras del resultado con la de la lista.
--
-- OBRAS: se escriben en el IN del bloque 1 (buscar "EDITABLE"), separadas por coma.
--
-- IPI de la editorial: dp_writer_data.publisher_v.cae_num (CAE/IPI name number),
-- con LEFT JOIN: una editorial sin IPI cargado sale con el IPI vacío.
-- cae_num es numérico (sin ceros a la izquierda). Permiso sobre dp_writer_data
-- confirmado por el usuario.
--
-- Columnas pedidas por el usuario (03/11/2026): sin contratos, grupos IP ni
-- porcentajes.
--
-- Rendimiento: song_share_detail_mv se nombra UNA vez (cadena lineal, cruces
-- con funciones de ventana). Los dos LISTAGG ordenan por la misma columna
-- "orden": cada fila se repite por tipo de lista (bloque "listas").
-- =====================================================================
WITH
-- 1. Única lectura de la MV, filtrada a las obras pedidas.
mv AS (
    SELECT DISTINCT
        CAST(s.song_id AS BIGINT)        AS song_id,
        s.song_title_tx,
        s.smp_controlled_ind             AS ctrl,
        s.publisher_id,
        s.publisher_name_tx,
        s.publisher_capacity_type_cd     AS capacidad,
        s.writer_id,
        s.writer_nm
    FROM dp_song_metadata.song_share_detail_mv s
    -- EDITABLE: Tempo ID de las obras, separados por coma.
    WHERE s.song_id IN (111111, 222222, 333333)
),

-- 2. Si la obra tiene alguna editorial controlada y primeras apariciones para
--    las listas (en lugar de LISTAGG DISTINCT).
marcado AS (
    SELECT
        m.*,
        MAX(CASE WHEN m.ctrl = 'Y' THEN 1 ELSE 0 END) OVER (PARTITION BY m.song_id) AS tiene_ctrl,
        ROW_NUMBER() OVER (PARTITION BY m.song_id ORDER BY m.publisher_id, m.writer_id)              AS rn_obra,
        ROW_NUMBER() OVER (PARTITION BY m.song_id, m.publisher_id, m.writer_id ORDER BY m.capacidad) AS rn_writer,
        ROW_NUMBER() OVER (PARTITION BY m.song_id, m.publisher_id, m.capacidad ORDER BY m.writer_id) AS rn_capacidad
    FROM mv m
),

-- 3. Filas de editoriales controladas y, para las obras sin ninguna, una sola fila.
filas AS (
    SELECT *
    FROM marcado
    WHERE ctrl = 'Y'
       OR (tiene_ctrl = 0 AND rn_obra = 1)
),

-- 4. Cada fila se repite por tipo de lista para que los LISTAGG ordenen por la
--    misma columna (restricción de Redshift).
tipos AS (
              SELECT 'W' AS tipo
    UNION ALL SELECT 'K'
),
listas AS (
    SELECT
        f.*,
        t.tipo,
        CASE t.tipo WHEN 'W' THEN COALESCE(f.writer_nm, '') ELSE COALESCE(f.capacidad, '') END AS orden
    FROM filas f
    CROSS JOIN tipos t
),

-- 5. Una fila por obra + editorial.
por_editorial AS (
    SELECT
        l.song_id,
        MAX(l.song_title_tx)     AS song_title_tx,
        MAX(l.tiene_ctrl)        AS tiene_ctrl,
        l.publisher_id,
        MAX(l.publisher_name_tx) AS publisher_name_tx,
        LISTAGG(CASE WHEN l.tipo = 'K' AND l.rn_capacidad = 1 THEN l.capacidad END, ', ')
            WITHIN GROUP (ORDER BY l.orden) AS capacidad,
        LISTAGG(CASE WHEN l.tipo = 'W' AND l.rn_writer = 1 AND l.writer_id IS NOT NULL
                     THEN l.writer_nm || ' (' || CAST(l.writer_id AS VARCHAR(20)) || ')' END, ' | ')
            WITHIN GROUP (ORDER BY l.orden) AS writers_representados
    FROM listas l
    GROUP BY l.song_id, l.publisher_id
)

-- 6. Resultado.
SELECT
    e.song_id                                                   AS tempo_id,
    e.song_title_tx                                             AS song_title,
    CASE WHEN e.tiene_ctrl = 1 THEN e.publisher_name_tx END     AS editorial_controlada,
    CASE WHEN e.tiene_ctrl = 1 THEN p.cae_num END               AS ipi_editorial,
    CASE WHEN e.tiene_ctrl = 1 THEN 'CONTROLADA'
         ELSE 'SIN EDITORIAL CONTROLADA' END                    AS estado,
    CASE WHEN e.tiene_ctrl = 1 THEN e.publisher_id END          AS publisher_id,
    CASE WHEN e.tiene_ctrl = 1 THEN e.capacidad END             AS capacidad,
    CASE WHEN e.tiene_ctrl = 1 THEN e.writers_representados END AS writers_representados
FROM por_editorial e
LEFT JOIN dp_writer_data.publisher_v p
       ON p.publisher_id = e.publisher_id
      AND e.tiene_ctrl = 1
ORDER BY e.song_id, editorial_controlada
;
