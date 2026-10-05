-- =====================================================================
-- REPORTE CWR POR TERRITORIO — v6 (solo vistas dp_*, sin esquema edw)
--
-- Respecto de la versión original:
--   1. Un solo grupo IP por obra y país: el que nombra al país; el
--      genérico ("All (Other) Contractual Territories") solo si ninguno
--      lo nombra. Antes se sumaban los dos (Ella Dijo: 12.5 + 8.34).
--   2. Los grupos se eligen mirando TODAS las participaciones de la obra,
--      no solo las controladas (si el grupo del país no es de SMP: NVFT).
--   3. El territorio del contrato se lee de contract_territories
--      comparando ELEMENTO por elemento de la lista (separada por ";"),
--      no buscando texto adentro. Ese texto ya incluye los overrides de
--      cada obra.
--   4. Si falta el texto de la obra con ese contrato, se usa el texto
--      más frecuente del mismo contrato en otras obras (marcado). Si no
--      hay ninguno, NO se asume control mundial: queda NVFT y marcado
--      para revisar (antes esto daba control falso, ej. Te Encontre en
--      Colombia).
--   5. Columnas de auditoría al final.
--
-- Agregado en v4 (a partir del DDL real de Tempo, ver docs/tempo_schema):
--   6. Obra sin filas en song_share_detail_mv -> 'SIN DATOS' (no 'NVFT').
--      La MV exige: song tipo 1, secuencia 0, writer con sociedad mecánica y
--      de ejecución cargadas (JOIN interno a tempo_society) y grupo de país.
--      Si falta cualquiera, la obra desaparece de la MV sin error.
--   7. Alertas de sanidad: totales > 100, contrato sin texto (el procedimiento
--      shared.sp_get_all_contract_territories solo genera filas para contratos
--      con rate client y payment option activos) y filas con la misma
--      participación repetida.
--   8. Desempate determinista en el texto de territorio de la obra.
--
-- Agregado en v5 (caso Baba O'Riley 2701309, contrastado con el front):
--   9. CAMBIO DE CRITERIO. Un pais esta controlado si ALGUNA linea de control de
--      la obra (fila de contract_territories) lo cubre, no solo el contrato que
--      figura como "Associated Contract" en la participacion. El grupo
--      "All (Other) Contractual Territories" significa "los demas territorios
--      contratados", y ese territorio lo dan las lineas de control. Antes la v3/v4
--      exigian que el contrato asociado cubriera el pais y daban NVFT cuando ese
--      contrato era de otra region (1525818 = Asia) y el control real estaba en
--      otra linea (1551025 = World ex..., 1146885 = Latinoamerica).
--      Las filas donde el contrato asociado NO cubre pero otra linea si, llevan
--      la alerta 'CONTROL SOSTENIDO POR OTRA LINEA DE CONTROL'.
--  10. Vencimiento y estado_contrato se calculan sobre las lineas que realmente
--      cubren el pais (antes: contratos asociados). Se corrige ademas un error:
--      una linea sin vencimiento mezclada con una vencida daba 'TODOS VENCIDOS'.
--  11. Columnas nuevas: lineas_de_control_obra, lineas_que_cubren_el_pais.
--
-- v6 (rendimiento): misma lógica y mismo resultado que la v5. Es un SCRIPT:
-- correr TODO junto en la misma sesión (DBeaver: "Execute script" / Alt+X;
-- Query Editor v2: "Run all"). El último SELECT es el reporte.
--
-- Por qué la v5 tardaba: Redshift no guarda el resultado de una CTE, la
-- recalcula cada vez que se nombra. target_songs salía de song_v (vista pesada:
-- agrupa writers, artistas, alertas y holds de todo el catálogo) y se nombraba
-- ~7 veces; song_share_detail_mv y contract_territories se leían 3 veces cada
-- una; y contract_v se recorría ENTERA, sin filtro, para sacar vencimientos.
-- Ahora cada fuente se lee UNA vez, filtrada a las obras/contratos pedidos, en
-- tablas temporales chicas (viven solo en esta sesión).
--
-- PARA CAMBIAR LAS OBRAS: editar solo el INSERT de cwr_ids (paso 0).
-- =====================================================================

-- 0. Obras pedidas
DROP TABLE IF EXISTS cwr_ids;
CREATE TEMP TABLE cwr_ids (song_id BIGINT);
INSERT INTO cwr_ids VALUES (7777841),(7777839),(2582605),(6146322),(6757163),(7610448),(5064830),(7182530),(4561711),(5587099),(5294797),(28755),(7525701),(7682215),(7086827),(5092800),(7256352),(5196177),(7536155),(327237),(7777854),(7525686),(7714996),(191014),(5026723),(6740634),(2649208),(2660988),(7159221),(5026737),(7594612),(4555478),(550810),(5751389),(1303178),(4273597),(5687811),(7184775),(2661049),(4823212),(2316641),(7142299),(7506515),(2658835),(7490088),(6012929),(6261420),(2590841),(5073349),(6176302),(6640425),(4386644),(6760420),(7875164),(6887017),(7760567),(6989652),(7710563),(7204081),(2145411),(5938752),(6989105),(7808656),(7485419),(6802711),(112996),(7525924),(5770053),(6452138),(5106087),(7450744),(6945418),(5527423),(7900799),(6686578),(2589549);

-- 1. Datos de la obra (song_v se lee una sola vez)
DROP TABLE IF EXISTS cwr_song;
CREATE TEMP TABLE cwr_song AS
SELECT song_id, song_title_tx, tempo_create_date, song_not_ours_dt
FROM dp_song_metadata.song_v
WHERE song_id IN (SELECT song_id FROM cwr_ids);

DROP TABLE IF EXISTS cwr_iswc;
CREATE TEMP TABLE cwr_iswc AS
SELECT tempo_song_id AS song_id, ident_iswc_cd, preferred_indicator
FROM dp_song_metadata.identifiers_iswc_v
WHERE tempo_song_id IN (SELECT song_id FROM cwr_ids)
  AND ident_iswc_cd IS NOT NULL;

-- 2. Participaciones (solo las columnas que se usan)
DROP TABLE IF EXISTS cwr_mv;
CREATE TEMP TABLE cwr_mv AS
SELECT song_id, associated_contract_id, associated_contract_nm, smp_controlled_ind,
       writer_id, publisher_id, publisher_name_tx, song_ip_territory_nm,
       publisher_performance_pc, publisher_mechanical_pc, publisher_sync_pc
FROM dp_song_metadata.song_share_detail_mv
WHERE song_id IN (SELECT song_id FROM cwr_ids);

-- 3. Líneas de control de las obras pedidas
DROP TABLE IF EXISTS cwr_ct;
CREATE TEMP TABLE cwr_ct AS
SELECT song_id, contract_id, contract_nm, inclusions, exclusions
FROM dp_song_metadata.contract_territories
WHERE song_id IN (SELECT song_id FROM cwr_ids);

-- 4. Respaldo de texto: solo para contratos de participaciones controladas que
--    no tienen texto propio para la obra. Se agrupa por un hash del texto (no por
--    el texto largo) y solo sobre esos contratos.
DROP TABLE IF EXISTS cwr_ct_fallback;
CREATE TEMP TABLE cwr_ct_fallback AS
WITH faltan AS (
    SELECT DISTINCT m.associated_contract_id AS contract_id
    FROM cwr_mv m
    WHERE m.smp_controlled_ind = 'Y'
      AND m.associated_contract_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM cwr_ct c
                      WHERE c.song_id = m.song_id AND c.contract_id = m.associated_contract_id)
),
textos AS (
    SELECT ct.contract_id, ct.song_id, ct.inclusions, ct.exclusions,
           MD5(COALESCE(ct.inclusions, '') || '|' || COALESCE(ct.exclusions, '')) AS h
    FROM dp_song_metadata.contract_territories ct
    JOIN faltan f ON f.contract_id = ct.contract_id
),
conteo AS (
    SELECT contract_id, h, COUNT(*) AS n
    FROM textos
    GROUP BY contract_id, h
),
mejor AS (
    SELECT contract_id, h
    FROM (SELECT contract_id, h, ROW_NUMBER() OVER (PARTITION BY contract_id ORDER BY n DESC, h) AS rn
          FROM conteo) x
    WHERE rn = 1
)
SELECT contract_id, inclusions, exclusions
FROM (
    SELECT t.contract_id, t.inclusions, t.exclusions,
           ROW_NUMBER() OVER (PARTITION BY t.contract_id ORDER BY t.song_id) AS rn
    FROM textos t
    JOIN mejor b ON b.contract_id = t.contract_id AND b.h = t.h
) y
WHERE rn = 1;

-- 5. Contratos involucrados (contract_v filtrada; antes se recorría entera)
DROP TABLE IF EXISTS cwr_contract;
CREATE TEMP TABLE cwr_contract AS
SELECT contract_id,
       MAX(contract_nm)            AS contract_nm,
       MAX(orig_office_nm)         AS orig_office_nm,
       MAX(contract_expiration_dt) AS contract_expiration_dt
FROM dp_deal_metadata.contract_v
WHERE contract_id IN (SELECT associated_contract_id FROM cwr_mv WHERE associated_contract_id IS NOT NULL
                      UNION
                      SELECT contract_id FROM cwr_ct)
GROUP BY contract_id;

-- 6. REPORTE (misma lógica que la v5)
WITH

-- ---------------------------------------------------------------------
-- 1. ALCANCE
-- ---------------------------------------------------------------------
target_songs AS (
    SELECT song_id FROM cwr_ids
),
paises_pedidos AS (
    SELECT 'ARGENTINA' AS pais
    UNION ALL SELECT 'CHILE'
    UNION ALL SELECT 'PERU'
    UNION ALL SELECT 'URUGUAY'
    UNION ALL SELECT 'COLOMBIA'
),
target_countries AS (
    SELECT pais FROM paises_pedidos
),
-- Regiones que pueden aparecer en los textos de territorio en lugar de
-- los países. EDITABLE: si el control previo muestra otra región que
-- incluya alguno de tus países, agregala acá (una fila por país).
regiones AS (
              SELECT 'LATIN AMERICA' AS region, 'ARGENTINA' AS pais
    UNION ALL SELECT 'LATIN AMERICA', 'CHILE'
    UNION ALL SELECT 'LATIN AMERICA', 'PERU'
    UNION ALL SELECT 'LATIN AMERICA', 'URUGUAY'
    UNION ALL SELECT 'LATIN AMERICA', 'COLOMBIA'
    UNION ALL SELECT 'SOUTH AMERICA', 'ARGENTINA'
    UNION ALL SELECT 'SOUTH AMERICA', 'CHILE'
    UNION ALL SELECT 'SOUTH AMERICA', 'PERU'
    UNION ALL SELECT 'SOUTH AMERICA', 'URUGUAY'
    UNION ALL SELECT 'SOUTH AMERICA', 'COLOMBIA'
),
scaffold AS (
    SELECT ts.song_id, tc.pais
    FROM target_songs ts
    CROSS JOIN target_countries tc
),

-- ---------------------------------------------------------------------
-- 2. DATOS DE LA OBRA
-- ---------------------------------------------------------------------
song_info AS (
    SELECT
        s.song_id,
        MAX(s.song_title_tx)     AS song_title_tx,
        MAX(s.tempo_create_date) AS tempo_create_date,
        MAX(s.song_not_ours_dt)  AS song_not_ours_dt
    FROM cwr_song s
    GROUP BY s.song_id
),
-- Un solo ISWC por obra (el preferido; si no hay, cualquiera).
iswc AS (
    SELECT
        i.song_id,
        COALESCE(
            MAX(CASE WHEN i.preferred_indicator = 'Y' THEN i.ident_iswc_cd END),
            MIN(i.ident_iswc_cd)
        ) AS iswc
    FROM cwr_iswc i
    GROUP BY i.song_id
),
contratos_obra_raw AS (
    SELECT DISTINCT
        s.song_id,
        s.associated_contract_id,
        s.associated_contract_nm,
        s.smp_controlled_ind
    FROM cwr_mv s
),
contratos_obra_label AS (
    SELECT
        c.song_id,
        c.associated_contract_id,
        CAST(
            COALESCE(CAST(c.associated_contract_id AS VARCHAR(30)), 'SIN CONTRATO')
            || ' - '
            || CAST(COALESCE(c.associated_contract_nm, 'Sin nombre') AS VARCHAR(200))
            || ' [ctrl:'
            || CAST(COALESCE(c.smp_controlled_ind, '?') AS VARCHAR(5))
            || '] '
            || CAST(
                 CASE
                     WHEN cv.contract_expiration_dt IS NULL THEN 'sin venc.'
                     WHEN cv.contract_expiration_dt < CURRENT_DATE
                         THEN 'VENCIDO ' || CAST(cv.contract_expiration_dt AS VARCHAR(10))
                     ELSE 'vig. ' || CAST(cv.contract_expiration_dt AS VARCHAR(10))
                 END AS VARCHAR(40))
        AS VARCHAR(300)) AS contrato_label
    FROM contratos_obra_raw c
    LEFT JOIN cwr_contract cv
        ON cv.contract_id = c.associated_contract_id
),
contratos_obra AS (
    SELECT
        song_id,
        LISTAGG(contrato_label, ' | ')
            WITHIN GROUP (ORDER BY contrato_label) AS todos_los_contratos,
        COUNT(*) AS cantidad_contratos_obra
    FROM contratos_obra_label
    GROUP BY song_id
),
oficinas_obra_raw AS (
    SELECT DISTINCT
        c.song_id,
        cv.orig_office_nm AS originating_office
    FROM contratos_obra_raw c
    JOIN cwr_contract cv
        ON cv.contract_id = c.associated_contract_id
    WHERE cv.orig_office_nm IS NOT NULL
),
oficinas_obra AS (
    SELECT
        song_id,
        LISTAGG(originating_office, ' | ')
            WITHIN GROUP (ORDER BY originating_office) AS originating_office
    FROM oficinas_obra_raw
    GROUP BY song_id
),

-- ---------------------------------------------------------------------
-- 3. PARTICIPACIONES CONTROLADAS POR SMP
-- ---------------------------------------------------------------------
shares AS (
    SELECT
        s.song_id,
        s.associated_contract_id,
        s.associated_contract_nm,
        s.writer_id,
        s.publisher_id,
        s.publisher_name_tx,
        UPPER(TRIM(COALESCE(s.song_ip_territory_nm, ''))) AS grupo_ip,
        s.publisher_performance_pc,
        s.publisher_mechanical_pc,
        s.publisher_sync_pc
    FROM cwr_mv s
    WHERE s.smp_controlled_ind = 'Y'
),

-- ---------------------------------------------------------------------
-- 4. QUÉ GRUPO IP APLICA A CADA OBRA Y PAÍS
-- ---------------------------------------------------------------------
-- Todos los grupos de la obra, controlados o no (ver punto 2 del encabezado).
grupos AS (
    SELECT DISTINCT
        s.song_id,
        UPPER(TRIM(COALESCE(s.song_ip_territory_nm, ''))) AS grupo_ip
    FROM cwr_mv s
),
-- Nombre del grupo como lista de palabras separadas por espacios, para
-- comparar palabras enteras (evita que "NIGER" coincida con "NIGERIA").
grupos_tok AS (
    SELECT
        song_id,
        grupo_ip,
        ' ' || TRIM(REGEXP_REPLACE(
            TRANSLATE(grupo_ip, 'ÁÉÍÓÚÜÑ', 'AEIOUUN'),
            '[^A-Z0-9]+', ' ')) || ' ' AS tok
    FROM grupos
),
-- Se separa lo incluido de lo excluido ("WORLD EX PHILIPPINES").
grupos_partes AS (
    SELECT
        song_id,
        grupo_ip,
        tok,
        REGEXP_INSTR(tok, ' (EX|EXCL|EXCLUDING|EXCEPT|EXCLUDE|EXCLUDES) ') AS pos_excl
    FROM grupos_tok
),
grupos_clasif AS (
    SELECT
        song_id,
        grupo_ip,
        CASE WHEN pos_excl > 0 THEN SUBSTRING(tok FROM 1 FOR pos_excl) ELSE tok END AS incl_tok,
        CASE WHEN pos_excl > 0 THEN SUBSTRING(tok FROM pos_excl)       ELSE ''  END AS excl_tok
    FROM grupos_partes
),
grupos_tipo AS (
    SELECT
        g.*,
        CASE
            WHEN TRIM(g.incl_tok) = ''
              OR g.incl_tok LIKE ' ALL %'
              OR g.incl_tok LIKE '% WORLD %'
              OR g.incl_tok LIKE '% WORLDWIDE %'
              OR g.incl_tok LIKE '% UNIVERSE %'
              OR g.incl_tok LIKE '% MUNDO %'
            THEN 1 ELSE 0
        END AS es_generico
    FROM grupos_clasif g
),
-- Países que cubre cada grupo, con su nivel de especificidad:
--   1 = el grupo nombra al país (nombre o código)
--   2 = el grupo nombra una región (diccionario "regiones") que lo contiene
--   3 = grupo mundial
grupo_pais AS (
    SELECT g.song_id, g.grupo_ip, tc.pais, 1 AS especificidad
    FROM grupos_tipo g
    JOIN target_countries tc
      ON g.incl_tok LIKE '% ' || tc.pais || ' %'
    WHERE g.es_generico = 0

    UNION ALL

    SELECT g.song_id, g.grupo_ip, r.pais, 2
    FROM grupos_tipo g
    JOIN regiones r
      ON g.incl_tok LIKE '% ' || r.region || ' %'
    WHERE g.es_generico = 0

    UNION ALL

    SELECT g.song_id, g.grupo_ip, tc.pais, 3
    FROM grupos_tipo g
    CROSS JOIN target_countries tc
    WHERE g.es_generico = 1
),
-- Países que el grupo excluye explícitamente (por nombre, código o región).
grupo_pais_excl AS (
    SELECT g.song_id, g.grupo_ip, tc.pais
    FROM grupos_tipo g
    JOIN target_countries tc
      ON g.excl_tok LIKE '% ' || tc.pais || ' %'
    WHERE g.excl_tok <> ''

    UNION

    SELECT g.song_id, g.grupo_ip, r.pais
    FROM grupos_tipo g
    JOIN regiones r
      ON g.excl_tok LIKE '% ' || r.region || ' %'
    WHERE g.excl_tok <> ''
),
grupo_pais_valido AS (
    SELECT gp.song_id, gp.grupo_ip, gp.pais, MIN(gp.especificidad) AS especificidad
    FROM grupo_pais gp
    WHERE NOT EXISTS (
        SELECT 1 FROM grupo_pais_excl x
        WHERE x.song_id = gp.song_id
          AND x.grupo_ip = gp.grupo_ip
          AND x.pais = gp.pais
    )
    GROUP BY gp.song_id, gp.grupo_ip, gp.pais
),
-- Un único grupo por obra y país: el más específico.
grupo_elegido AS (
    SELECT song_id, pais, grupo_ip, especificidad, n_empate
    FROM (
        SELECT
            v.*,
            ROW_NUMBER() OVER (PARTITION BY v.song_id, v.pais ORDER BY v.especificidad, v.grupo_ip) AS rn,
            COUNT(*)     OVER (PARTITION BY v.song_id, v.pais, v.especificidad)               AS n_empate
        FROM grupo_pais_valido v
    ) x
    WHERE rn = 1
),

-- ---------------------------------------------------------------------
-- 5. TERRITORIO DEL CONTRATO (texto de contract_territories, por elemento)
-- ---------------------------------------------------------------------
contratos_scope AS (
    SELECT DISTINCT song_id, associated_contract_id AS contract_id
    FROM shares
    WHERE associated_contract_id IS NOT NULL
    UNION
    -- lineas de control de la obra aunque ninguna participacion las nombre
    SELECT DISTINCT ct.song_id, ct.contract_id
    FROM cwr_ct ct
),
-- Texto de la obra con ese contrato (ya trae los overrides de la obra).
ct_par AS (
    SELECT song_id, contract_id, inclusions, exclusions
    FROM (
        SELECT
            ct.song_id, ct.contract_id, ct.inclusions, ct.exclusions,
            ROW_NUMBER() OVER (PARTITION BY ct.song_id, ct.contract_id ORDER BY ct.inclusions, CASE WHEN ct.exclusions IS NULL THEN 1 ELSE 0 END, ct.exclusions) AS rn
        FROM cwr_ct ct
        JOIN contratos_scope cs ON cs.song_id = ct.song_id AND cs.contract_id = ct.contract_id
    ) x
    WHERE rn = 1
),
-- Respaldo: el texto más frecuente del mismo contrato en otras obras (precalculado).
ct_contrato AS (
    SELECT contract_id, inclusions, exclusions FROM cwr_ct_fallback
),
texto_contrato_raw AS (
    SELECT
        cs.song_id,
        cs.contract_id,
        CASE
            WHEN p.contract_id IS NOT NULL THEN 'OBRA'
            WHEN c.contract_id IS NOT NULL THEN 'CONTRATO'
            ELSE 'SIN TEXTO'
        END AS fuente_texto,
        COALESCE(p.inclusions, c.inclusions) AS inclusions,
        COALESCE(p.exclusions, c.exclusions) AS exclusions
    FROM contratos_scope cs
    LEFT JOIN ct_par p      ON p.song_id = cs.song_id AND p.contract_id = cs.contract_id
    LEFT JOIN ct_contrato c ON c.contract_id = cs.contract_id
),
-- Listas normalizadas: ";ELEM1;ELEM2;" en mayúsculas, sin tildes, sin
-- el prefijo "Include:" / "Exclude:" y sin el sufijo " (REG)" que Tempo
-- agrega a algunos países ("ARGENTINA (REG)" cuenta como ARGENTINA).
texto_contrato AS (
    SELECT
        song_id,
        contract_id,
        fuente_texto,
        ';' || REGEXP_REPLACE(
                   TRIM(REGEXP_REPLACE(
                       REGEXP_REPLACE(
                           UPPER(TRANSLATE(COALESCE(inclusions, ''), 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun')),
                           '[[:space:]]*[(]REG[)]', ''),
                       '^[[:space:]]*INCLUDE:[[:space:]]*', '')),
                   '[[:space:]]*;[[:space:]]*', ';') || ';' AS incl,
        ';' || REGEXP_REPLACE(
                   TRIM(REGEXP_REPLACE(
                       REGEXP_REPLACE(
                           UPPER(TRANSLATE(COALESCE(exclusions, ''), 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun')),
                           '[[:space:]]*[(]REG[)]', ''),
                       '^[[:space:]]*EXCLUDE:[[:space:]]*', '')),
                   '[[:space:]]*;[[:space:]]*', ';') || ';' AS excl
    FROM texto_contrato_raw
),
cobertura_calc AS (
    SELECT
        t.song_id,
        t.contract_id,
        t.fuente_texto,
        tc.pais,
        MAX(CASE WHEN t.incl LIKE '%;WORLD;%'                                   THEN 1 ELSE 0 END) AS inc_mundo,
        MAX(CASE WHEN t.incl LIKE '%;' || tc.pais || ';%'                       THEN 1 ELSE 0 END) AS inc_pais,
        MAX(CASE WHEN r.region IS NOT NULL AND t.incl LIKE '%;' || r.region || ';%' THEN 1 ELSE 0 END) AS inc_region,
        MAX(CASE WHEN t.excl LIKE '%;' || tc.pais || ';%'                       THEN 1 ELSE 0 END) AS exc_pais,
        MAX(CASE WHEN r.region IS NOT NULL AND t.excl LIKE '%;' || r.region || ';%' THEN 1 ELSE 0 END) AS exc_region
    FROM texto_contrato t
    CROSS JOIN target_countries tc
    LEFT JOIN regiones r ON r.pais = tc.pais
    GROUP BY t.song_id, t.contract_id, t.fuente_texto, tc.pais
),
cobertura AS (
    SELECT
        song_id,
        contract_id,
        pais,
        fuente_texto,
        CASE
            WHEN fuente_texto = 'SIN TEXTO'          THEN 0
            WHEN exc_pais = 1 OR exc_region = 1      THEN 0
            WHEN inc_mundo = 1 OR inc_pais = 1 OR inc_region = 1 THEN 1
            ELSE 0
        END AS cubre,
        CASE
            WHEN fuente_texto = 'SIN TEXTO'          THEN 'Contrato sin texto de territorio: VERIFICAR'
            WHEN exc_pais = 1                        THEN 'Contrato: país excluido'
            WHEN exc_region = 1                      THEN 'Contrato: región excluida'
            WHEN inc_pais = 1                        THEN 'Contrato: país incluido'
            WHEN inc_region = 1                      THEN 'Contrato: región incluida'
            WHEN inc_mundo = 1                       THEN 'Contrato: World'
            ELSE 'Contrato: país no incluido'
        END
        || CASE WHEN fuente_texto = 'CONTRATO' THEN ' (texto tomado de otra obra del contrato)' ELSE '' END
        AS regla
    FROM cobertura_calc
),
-- Un pais esta dentro del territorio contratado de la obra si alguna de sus
-- lineas de control (texto propio de la obra) lo cubre.
cobertura_obra AS (
    SELECT
        song_id,
        pais,
        MAX(CASE WHEN fuente_texto = 'OBRA' AND cubre = 1 THEN 1 ELSE 0 END) AS cubre_alguna_linea
    FROM cobertura
    GROUP BY song_id, pais
),

-- ---------------------------------------------------------------------
-- 6. PARTICIPACIONES QUE APLICAN A CADA PAÍS
-- ---------------------------------------------------------------------
-- Una participación cuenta para un país si pertenece al grupo IP elegido
-- para ese país y su contrato cubre ese país.
detalle_pre AS (
    SELECT
        s.song_id,
        ge.pais,
        ge.grupo_ip,
        ge.especificidad,
        ge.n_empate,
        s.associated_contract_id,
        s.associated_contract_nm,
        s.publisher_id,
        s.publisher_name_tx,
        s.publisher_performance_pc,
        s.publisher_mechanical_pc,
        s.publisher_sync_pc,
        CASE
            WHEN s.associated_contract_id IS NULL THEN 1
            WHEN cob.cubre = 1                    THEN 1
            WHEN cobo.cubre_alguna_linea = 1      THEN 1
            ELSE 0
        END AS cubre,
        CASE WHEN s.associated_contract_id IS NULL THEN 1 ELSE COALESCE(cob.cubre, 0) END AS cubre_contrato_asociado,
        cob.fuente_texto,
        CASE
            WHEN s.associated_contract_id IS NULL THEN 'Participación sin contrato asociado'
            WHEN cob.cubre = 1                    THEN cob.regla
            WHEN cobo.cubre_alguna_linea = 1
                THEN 'Otra línea de control de la obra cubre el país (contrato asociado: ' || COALESCE(cob.regla, 'sin texto') || ')'
            ELSE cob.regla
        END AS regla
    FROM shares s
    JOIN grupo_elegido ge
        ON ge.song_id = s.song_id
       AND ge.grupo_ip = s.grupo_ip
    LEFT JOIN cobertura cob
        ON cob.song_id = s.song_id
       AND cob.contract_id = s.associated_contract_id
       AND cob.pais = ge.pais
    LEFT JOIN cobertura_obra cobo
        ON cobo.song_id = s.song_id
       AND cobo.pais = ge.pais
),
detalle AS (
    SELECT * FROM detalle_pre WHERE cubre = 1
),
alertas_pais AS (
    SELECT
        song_id,
        pais,
        MAX(CASE WHEN fuente_texto = 'SIN TEXTO' AND cubre = 0 THEN 1 ELSE 0 END) AS hay_sin_texto,
        MAX(CASE WHEN fuente_texto = 'CONTRATO'  AND cubre_contrato_asociado = 1 THEN 1 ELSE 0 END) AS hay_texto_prestado,
        MAX(CASE WHEN cubre = 1 AND cubre_contrato_asociado = 0 THEN 1 ELSE 0 END) AS hay_otra_linea
    FROM detalle_pre
    GROUP BY song_id, pais
),
totales AS (
    SELECT
        song_id,
        pais,
        COUNT(publisher_id)            AS n_participaciones,
        SUM(publisher_performance_pc)  AS perf,
        SUM(publisher_mechanical_pc)   AS mech,
        SUM(publisher_sync_pc)         AS sync,
        MAX(CASE WHEN associated_contract_id IS NULL THEN 1 ELSE 0 END) AS hay_sin_contrato
    FROM detalle
    GROUP BY song_id, pais
),
publishers_por_pais AS (
    SELECT DISTINCT song_id, pais, publisher_name_tx AS publisher
    FROM detalle
    WHERE publisher_name_tx IS NOT NULL
),
publishers_listados AS (
    SELECT
        song_id, pais,
        LISTAGG(publisher, ' | ') WITHIN GROUP (ORDER BY publisher) AS publishers,
        COUNT(*) AS cantidad_publishers
    FROM publishers_por_pais
    GROUP BY song_id, pais
),
contratos_por_pais AS (
    SELECT DISTINCT
        song_id, pais,
        CAST(
            COALESCE(CAST(associated_contract_id AS VARCHAR(30)), 'SIN CONTRATO')
            || ' - '
            || CAST(COALESCE(associated_contract_nm, 'Sin nombre') AS VARCHAR(200))
        AS VARCHAR(250)) AS contrato_label
    FROM detalle
),
contratos_listados AS (
    SELECT
        song_id, pais,
        LISTAGG(contrato_label, ' | ') WITHIN GROUP (ORDER BY contrato_label) AS contratos,
        COUNT(*) AS cantidad_contratos
    FROM contratos_por_pais
    GROUP BY song_id, pais
),
-- Etiqueta y vencimiento de cada contrato involucrado (una fila por contrato).
contrato_info AS (
    SELECT
        contract_id,
        MAX(contract_nm)            AS contract_nm,
        MAX(contract_expiration_dt) AS contract_expiration_dt
    FROM cwr_contract
    GROUP BY contract_id
),
-- Lineas de control de la obra (texto propio de la obra en contract_territories).
lineas_obra AS (
    SELECT
        tr.song_id,
        LISTAGG(
            CAST(tr.contract_id AS VARCHAR(20)) || ' - ' || CAST(COALESCE(ci.contract_nm, 'Sin nombre') AS VARCHAR(150)),
            ' | ') WITHIN GROUP (ORDER BY tr.contract_id) AS lineas_de_control_obra
    FROM texto_contrato_raw tr
    LEFT JOIN contrato_info ci ON ci.contract_id = tr.contract_id
    WHERE tr.fuente_texto = 'OBRA'
    GROUP BY tr.song_id
),
-- Contratos que cubren cada pais (lineas de control y contratos asociados cubiertos).
lineas_cubren_raw AS (
    SELECT
        cob.song_id,
        cob.pais,
        cob.contract_id,
        CAST(cob.contract_id AS VARCHAR(20)) || ' - ' || CAST(COALESCE(ci.contract_nm, 'Sin nombre') AS VARCHAR(150))
            || ' ['
            || CASE
                   WHEN ci.contract_expiration_dt IS NULL THEN 'sin venc.'
                   WHEN ci.contract_expiration_dt < CURRENT_DATE THEN 'VENCIDO ' || CAST(ci.contract_expiration_dt AS VARCHAR(10))
                   ELSE 'vig. ' || CAST(ci.contract_expiration_dt AS VARCHAR(10))
               END
            || ']' AS etiqueta,
        ci.contract_expiration_dt
    FROM cobertura cob
    LEFT JOIN contrato_info ci ON ci.contract_id = cob.contract_id
    WHERE cob.cubre = 1
),
lineas_cubren AS (
    SELECT
        song_id,
        pais,
        LISTAGG(etiqueta, ' | ') WITHIN GROUP (ORDER BY contract_id) AS lineas_que_cubren,
        COUNT(*)                                                                         AS n_lineas,
        SUM(CASE WHEN contract_expiration_dt IS NULL THEN 1 ELSE 0 END)                  AS n_sin_venc,
        SUM(CASE WHEN contract_expiration_dt < CURRENT_DATE THEN 1 ELSE 0 END)           AS n_vencidos,
        SUM(CASE WHEN contract_expiration_dt >= CURRENT_DATE THEN 1 ELSE 0 END)          AS n_vigentes,
        MIN(contract_expiration_dt)                                                      AS venc_proximo,
        MAX(contract_expiration_dt)                                                      AS venc_lejano
    FROM lineas_cubren_raw
    GROUP BY song_id, pais
),
-- Texto de territorio tal como lo guarda contract_territories (recortado), por contrato y pais.
texto_auditoria AS (
    SELECT
        cob.song_id,
        cob.pais,
        LISTAGG(
            CAST(cob.contract_id AS VARCHAR(20)) || ' [' || cob.fuente_texto || '] cubre=' || CAST(cob.cubre AS VARCHAR(1))
            || ' | ' || cob.regla
            || ' | INC: ' || SUBSTRING(COALESCE(tr.inclusions, '(vacio)'), 1, 100)
            || ' | EXC: ' || SUBSTRING(COALESCE(tr.exclusions, '(vacio)'), 1, 100),
            ' || ') WITHIN GROUP (ORDER BY cob.contract_id) AS texto_territorio_contratos
    FROM cobertura cob
    JOIN texto_contrato_raw tr ON tr.song_id = cob.song_id AND tr.contract_id = cob.contract_id
    GROUP BY cob.song_id, cob.pais
),
reglas_por_pais AS (
    SELECT DISTINCT song_id, pais, regla FROM detalle_pre
),
reglas_listadas AS (
    SELECT
        song_id, pais,
        LISTAGG(regla, ' | ') WITHIN GROUP (ORDER BY regla) AS regla_territorial
    FROM reglas_por_pais
    GROUP BY song_id, pais
),
grupos_listados AS (
    SELECT
        song_id,
        LISTAGG(CASE WHEN grupo_ip = '' THEN '(sin nombre)' ELSE grupo_ip END, ' | ')
            WITHIN GROUP (ORDER BY grupo_ip) AS grupos_ip_de_la_obra
    FROM grupos
    GROUP BY song_id
)

-- ---------------------------------------------------------------------
-- 7. RESULTADO: una fila por obra y país
-- ---------------------------------------------------------------------
SELECT
    sc.song_id,
    COALESCE(si.song_title_tx, 'Sin título')          AS song_title_tx,
    iw.iswc                                           AS iswc,
    sc.pais,

    CASE
        WHEN si.song_not_ours_dt IS NOT NULL AND si.song_not_ours_dt <= CURRENT_DATE THEN 'NOP'
        WHEN gl.song_id IS NULL THEN 'SIN DATOS'
        WHEN COALESCE(t.perf, 0) = 0 THEN 'NVFT'
        ELSE CAST(CAST(t.perf AS NUMERIC(10,2)) AS VARCHAR(20))
    END AS performance_pc_total,
    CASE
        WHEN si.song_not_ours_dt IS NOT NULL AND si.song_not_ours_dt <= CURRENT_DATE THEN 'NOP'
        WHEN gl.song_id IS NULL THEN 'SIN DATOS'
        WHEN COALESCE(t.mech, 0) = 0 THEN 'NVFT'
        ELSE CAST(CAST(t.mech AS NUMERIC(10,2)) AS VARCHAR(20))
    END AS mechanical_pc_total,
    CASE
        WHEN si.song_not_ours_dt IS NOT NULL AND si.song_not_ours_dt <= CURRENT_DATE THEN 'NOP'
        WHEN gl.song_id IS NULL THEN 'SIN DATOS'
        WHEN COALESCE(t.sync, 0) = 0 THEN 'NVFT'
        ELSE CAST(CAST(t.sync AS NUMERIC(10,2)) AS VARCHAR(20))
    END AS sync_pc_total,

    COALESCE(pl.publishers, 'N/A')                    AS publishers,
    COALESCE(pl.cantidad_publishers, 0)               AS cantidad_publishers,
    COALESCE(cl.contratos, 'N/A')                     AS contratos_del_pais,
    COALESCE(cl.cantidad_contratos, 0)                AS cantidad_contratos_del_pais,
    co.todos_los_contratos,
    co.cantidad_contratos_obra,
    oo.originating_office,
    si.tempo_create_date                              AS song_tempo_create_date,
    si.song_not_ours_dt,
    CASE
        WHEN si.song_not_ours_dt IS NOT NULL AND si.song_not_ours_dt <= CURRENT_DATE THEN 'VENCIDA (NOP)'
        ELSE 'ACTIVA'
    END                                               AS estado_obra,
    lc.venc_proximo                                   AS contrato_venc_mas_proximo,
    lc.venc_lejano                                    AS contrato_venc_mas_lejano,
    CASE
        WHEN t.song_id IS NULL                                            THEN 'SIN CONTROL'
        WHEN lc.song_id IS NULL                                           THEN 'SIN LINEA DE CONTROL'
        WHEN lc.n_vencidos = lc.n_lineas                                  THEN 'TODOS VENCIDOS'
        WHEN lc.n_vencidos > 0                                            THEN 'MIXTO (alguno vencido)'
        WHEN lc.n_vigentes = 0                                            THEN 'SIN VENCIMIENTO'
        ELSE 'VIGENTE'
    END                                               AS estado_contrato,

    -- Auditoría
    CASE WHEN ge.grupo_ip = '' THEN '(sin nombre)' ELSE ge.grupo_ip END AS grupo_ip_usado,
    CASE ge.especificidad
        WHEN 1 THEN 'Grupo nombra al país'
        WHEN 2 THEN 'Grupo nombra una región que lo incluye'
        WHEN 3 THEN 'Grupo mundial'
        ELSE 'Ningún grupo de la obra cubre el país'
    END                                               AS como_se_eligio_grupo,
    COALESCE(rl.regla_territorial, '—')               AS regla_territorial,
    gl.grupos_ip_de_la_obra,
    lo.lineas_de_control_obra,
    lc.lineas_que_cubren                              AS lineas_que_cubren_el_pais,
    ta.texto_territorio_contratos,
    NULLIF(
        CASE WHEN ge.n_empate > 1 THEN 'VARIOS GRUPOS CON LA MISMA PRIORIDAD; ' ELSE '' END
        || CASE WHEN t.hay_sin_contrato = 1 THEN 'PARTICIPACION SIN CONTRATO; ' ELSE '' END
        || CASE WHEN gl.song_id IS NULL THEN 'OBRA AUSENTE EN song_share_detail_mv (revisar writers sin sociedad, secuencia o grupo de pais); ' ELSE '' END
        || CASE WHEN ap.hay_sin_texto = 1 THEN 'CONTRATO SIN TEXTO DE TERRITORIO: sin rate client/payment option activo (VERIFICAR); ' ELSE '' END
        || CASE WHEN COALESCE(t.perf, 0) > 100 OR COALESCE(t.mech, 0) > 100 OR COALESCE(t.sync, 0) > 100
                THEN 'TOTAL SUPERA 100 (posible doble conteo en la cadena de publishers); ' ELSE '' END
        || CASE WHEN ap.hay_texto_prestado = 1 THEN 'TERRITORIO TOMADO DE OTRA OBRA DEL CONTRATO; ' ELSE '' END
        || CASE WHEN ap.hay_otra_linea = 1 THEN 'CONTROL SOSTENIDO POR OTRA LINEA DE CONTROL (el contrato asociado a la participacion no cubre el pais); ' ELSE '' END
    , '')                                             AS alertas

FROM scaffold sc
LEFT JOIN song_info si           ON si.song_id = sc.song_id
LEFT JOIN iswc iw                ON iw.song_id = sc.song_id
LEFT JOIN grupo_elegido ge       ON ge.song_id = sc.song_id AND ge.pais = sc.pais
LEFT JOIN totales t              ON t.song_id  = sc.song_id AND t.pais  = sc.pais
LEFT JOIN publishers_listados pl ON pl.song_id = sc.song_id AND pl.pais = sc.pais
LEFT JOIN contratos_listados cl  ON cl.song_id = sc.song_id AND cl.pais = sc.pais
LEFT JOIN reglas_listadas rl     ON rl.song_id = sc.song_id AND rl.pais = sc.pais
LEFT JOIN contratos_obra co      ON co.song_id = sc.song_id
LEFT JOIN oficinas_obra oo       ON oo.song_id = sc.song_id
LEFT JOIN grupos_listados gl     ON gl.song_id = sc.song_id
LEFT JOIN alertas_pais ap        ON ap.song_id = sc.song_id AND ap.pais = sc.pais
LEFT JOIN texto_auditoria ta     ON ta.song_id = sc.song_id AND ta.pais = sc.pais
LEFT JOIN lineas_cubren lc       ON lc.song_id = sc.song_id AND lc.pais = sc.pais
LEFT JOIN lineas_obra lo         ON lo.song_id = sc.song_id
ORDER BY sc.song_id, sc.pais;
