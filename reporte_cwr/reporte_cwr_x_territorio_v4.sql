-- =====================================================================
-- REPORTE CWR POR TERRITORIO — v4 (solo vistas dp_*, sin esquema edw)
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
-- =====================================================================
WITH

-- ---------------------------------------------------------------------
-- 1. ALCANCE
-- ---------------------------------------------------------------------
target_songs AS (
    SELECT DISTINCT song_id
    FROM dp_song_metadata.song_v
    WHERE song_id IN (
        7777841,7777839,2582605,6146322,6757163,7610448,5064830,7182530,4561711,5587099,5294797,28755,7525701,7682215,7086827,5092800,7256352,5196177,7536155,327237,7777854,7525686,7714996,191014,5026723,6740634,2649208,2660988,7159221,5026737,7594612,4555478,550810,5751389,1303178,4273597,5687811,7184775,2661049,4823212,2316641,7142299,7506515,2658835,7490088,6012929,6261420,2590841,5073349,6176302,6640425,4386644,6760420,7875164,6887017,7760567,6989652,7710563,7204081,2145411,5938752,6989105,7808656,7485419,6802711,112996,7525924,5770053,6452138,5106087,7450744,6945418,5527423,7900799,6686578,2589549
    )
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
    FROM dp_song_metadata.song_v s
    JOIN target_songs ts ON ts.song_id = s.song_id
    GROUP BY s.song_id
),
-- Un solo ISWC por obra (el preferido; si no hay, cualquiera).
iswc AS (
    SELECT
        i.tempo_song_id AS song_id,
        COALESCE(
            MAX(CASE WHEN i.preferred_indicator = 'Y' THEN i.ident_iswc_cd END),
            MIN(i.ident_iswc_cd)
        ) AS iswc
    FROM dp_song_metadata.identifiers_iswc_v i
    JOIN target_songs ts ON ts.song_id = i.tempo_song_id
    WHERE i.ident_iswc_cd IS NOT NULL
    GROUP BY i.tempo_song_id
),
contratos_obra_raw AS (
    SELECT DISTINCT
        s.song_id,
        s.associated_contract_id,
        s.associated_contract_nm,
        s.smp_controlled_ind
    FROM dp_song_metadata.song_share_detail_mv s
    JOIN target_songs ts ON ts.song_id = s.song_id
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
    LEFT JOIN dp_deal_metadata.contract_v cv
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
    JOIN dp_deal_metadata.contract_v cv
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
    FROM dp_song_metadata.song_share_detail_mv s
    JOIN target_songs ts ON ts.song_id = s.song_id
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
    FROM dp_song_metadata.song_share_detail_mv s
    JOIN target_songs ts ON ts.song_id = s.song_id
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
),
contratos_ids AS (
    SELECT DISTINCT contract_id FROM contratos_scope
),
-- Texto de la obra con ese contrato (ya trae los overrides de la obra).
ct_par AS (
    SELECT song_id, contract_id, inclusions, exclusions
    FROM (
        SELECT
            ct.song_id, ct.contract_id, ct.inclusions, ct.exclusions,
            ROW_NUMBER() OVER (PARTITION BY ct.song_id, ct.contract_id ORDER BY ct.inclusions, CASE WHEN ct.exclusions IS NULL THEN 1 ELSE 0 END, ct.exclusions) AS rn
        FROM dp_song_metadata.contract_territories ct
        JOIN contratos_scope cs ON cs.song_id = ct.song_id AND cs.contract_id = ct.contract_id
    ) x
    WHERE rn = 1
),
-- Respaldo: el texto más frecuente del mismo contrato en otras obras.
ct_contrato AS (
    SELECT contract_id, inclusions, exclusions
    FROM (
        SELECT
            ct.contract_id, ct.inclusions, ct.exclusions,
            ROW_NUMBER() OVER (PARTITION BY ct.contract_id ORDER BY COUNT(*) DESC, ct.inclusions) AS rn
        FROM dp_song_metadata.contract_territories ct
        JOIN contratos_ids ci ON ci.contract_id = ct.contract_id
        GROUP BY ct.contract_id, ct.inclusions, ct.exclusions
    ) x
    WHERE rn = 1
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
        cv.contract_expiration_dt,
        COALESCE(cob.cubre, 1) AS cubre,
        cob.fuente_texto,
        COALESCE(cob.regla, 'Participación sin contrato asociado') AS regla
    FROM shares s
    JOIN grupo_elegido ge
        ON ge.song_id = s.song_id
       AND ge.grupo_ip = s.grupo_ip
    LEFT JOIN cobertura cob
        ON cob.song_id = s.song_id
       AND cob.contract_id = s.associated_contract_id
       AND cob.pais = ge.pais
    LEFT JOIN dp_deal_metadata.contract_v cv
        ON cv.contract_id = s.associated_contract_id
),
detalle AS (
    SELECT * FROM detalle_pre WHERE cubre = 1
),
alertas_pais AS (
    SELECT
        song_id,
        pais,
        MAX(CASE WHEN fuente_texto = 'SIN TEXTO' THEN 1 ELSE 0 END) AS hay_sin_texto,
        MAX(CASE WHEN fuente_texto = 'CONTRATO'  THEN 1 ELSE 0 END) AS hay_texto_prestado
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
        MIN(contract_expiration_dt)    AS venc_proximo,
        MAX(contract_expiration_dt)    AS venc_lejano,
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
    t.venc_proximo                                    AS contrato_venc_mas_proximo,
    t.venc_lejano                                     AS contrato_venc_mas_lejano,
    CASE
        WHEN t.song_id IS NULL                        THEN 'SIN CONTROL'
        WHEN t.venc_lejano IS NULL                    THEN 'SIN VENCIMIENTO'
        WHEN t.venc_lejano < CURRENT_DATE             THEN 'TODOS VENCIDOS'
        WHEN t.venc_proximo < CURRENT_DATE            THEN 'MIXTO (alguno vencido)'
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
    NULLIF(
        CASE WHEN ge.n_empate > 1 THEN 'VARIOS GRUPOS CON LA MISMA PRIORIDAD; ' ELSE '' END
        || CASE WHEN t.hay_sin_contrato = 1 THEN 'PARTICIPACION SIN CONTRATO; ' ELSE '' END
        || CASE WHEN gl.song_id IS NULL THEN 'OBRA AUSENTE EN song_share_detail_mv (revisar writers sin sociedad, secuencia o grupo de pais); ' ELSE '' END
        || CASE WHEN ap.hay_sin_texto = 1 THEN 'CONTRATO SIN TEXTO DE TERRITORIO: sin rate client/payment option activo (VERIFICAR); ' ELSE '' END
        || CASE WHEN COALESCE(t.perf, 0) > 100 OR COALESCE(t.mech, 0) > 100 OR COALESCE(t.sync, 0) > 100
                THEN 'TOTAL SUPERA 100 (posible doble conteo en la cadena de publishers); ' ELSE '' END
        || CASE WHEN ap.hay_texto_prestado = 1 THEN 'TERRITORIO TOMADO DE OTRA OBRA DEL CONTRATO; ' ELSE '' END
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
ORDER BY sc.song_id, sc.pais;
