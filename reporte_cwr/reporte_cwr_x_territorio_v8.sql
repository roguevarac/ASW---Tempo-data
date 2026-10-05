-- =====================================================================
-- REPORTE CWR POR TERRITORIO — v8 (una sola sentencia; obras desde public.rankingdigital_song_id)
--
-- Misma lógica y mismo resultado que la v5/v6, en UNA sola consulta y con
-- un solo resultado. Una fila por obra y país (AR, CL, CO, PE, UY).
--
-- PARA CAMBIAR LAS OBRAS: cargar los Tempo ID en public.rankingdigital_song_id
-- (columna song_id). Misma lógica y resultado que la v7, que tenía la lista
-- escrita dentro de la query.
-- Para descargar archivos grandes usar unload_reporte_cwr_v8.sql (misma query
-- dentro de un UNLOAD a S3).
--
-- Reglas de negocio (detalle e historia en reporte_cwr/README.md):
--   * Un solo grupo IP por obra y país: el que nombra al país; si no, el que
--     nombra una región que lo incluye; si no, el mundial. Si ese grupo no es
--     de SMP, NVFT (no se cae a otro grupo).
--   * El país está controlado si ALGUNA línea de control de la obra
--     (contract_territories) lo cubre, o si lo cubre el contrato asociado a la
--     participación. Los textos se comparan elemento por elemento.
--   * Si el contrato asociado no tiene texto propio para la obra, se usa el
--     texto más frecuente del mismo contrato en otras obras (marcado).
--   * Obra sin filas en song_share_detail_mv: 'SIN DATOS'. Obra NOP: 'NOP'.
--
-- Rendimiento. Redshift recalcula una CTE cada vez que se la nombra, así que
-- esta versión está armada como una CADENA: cada CTE pesada se nombra una sola
-- vez. Lecturas por ejecución: song_share_detail_mv 3, contract_territories 4
-- (una de ellas solo para contratos sin texto propio), contract_v 1, song_v 1,
-- identifiers_iswc_v 1. Todas filtradas a las obras o contratos pedidos.
-- (La v5 en una sola sentencia llegaba a 126 / 80 / 70 lecturas.)
--
-- Restricción de Redshift: todos los LISTAGG de un mismo SELECT deben ordenar
-- por la misma expresión. Por eso al final cada fila se repite por tipo de lista
-- (bloque "listas") y todas ordenan por la misma columna "orden".
-- =====================================================================
WITH

-- ---------------------------------------------------------------------
-- 0. PARÁMETROS
-- ---------------------------------------------------------------------
-- Obras a analizar: se leen de la tabla public.rankingdigital_song_id.
-- Para cambiar las obras se carga/actualiza esa tabla; la query no se toca.
-- Si la columna de la tabla no se llama song_id, cambiar el nombre SOLO acá.
ids AS (
    SELECT DISTINCT CAST(t.song_id AS BIGINT) AS song_id
    FROM public.rankingdigital_song_id t
    WHERE t.song_id IS NOT NULL
),
paises AS (
              SELECT 'ARGENTINA' AS pais
    UNION ALL SELECT 'CHILE'
    UNION ALL SELECT 'PERU'
    UNION ALL SELECT 'URUGUAY'
    UNION ALL SELECT 'COLOMBIA'
),
-- Regiones que pueden aparecer en los textos en lugar de los países.
-- EDITABLE: una fila por región y país que la integra.
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

-- ---------------------------------------------------------------------
-- 1. LECTURAS (filtradas a las obras pedidas)
-- ---------------------------------------------------------------------
mv_raw AS (
    SELECT
        s.song_id,
        s.associated_contract_id                          AS contract_id,
        s.associated_contract_nm                          AS contract_nm_mv,
        s.smp_controlled_ind                              AS ctrl,
        s.publisher_name_tx,
        UPPER(TRIM(COALESCE(s.song_ip_territory_nm, ''))) AS grupo_ip,
        s.publisher_performance_pc                        AS perf,
        s.publisher_mechanical_pc                         AS mech,
        s.publisher_sync_pc                               AS sync
    FROM dp_song_metadata.song_share_detail_mv s
    WHERE s.song_id IN (SELECT song_id FROM ids)
),
-- Líneas de control de las obras pedidas (una por obra y contrato).
lineas_raw AS (
    SELECT song_id, contract_id, inclusions, exclusions
    FROM (
        SELECT
            ct.song_id, ct.contract_id, ct.inclusions, ct.exclusions,
            ROW_NUMBER() OVER (PARTITION BY ct.song_id, ct.contract_id
                               ORDER BY ct.inclusions, CASE WHEN ct.exclusions IS NULL THEN 1 ELSE 0 END, ct.exclusions) AS rn
        FROM dp_song_metadata.contract_territories ct
        WHERE ct.song_id IN (SELECT song_id FROM ids)
    ) x
    WHERE rn = 1
),
-- Respaldo de texto: solo contratos de participaciones controladas que no tienen
-- texto propio para esa obra. Texto más frecuente del contrato (agrupa por hash).
fb_faltan AS (
    SELECT DISTINCT m.contract_id
    FROM mv_raw m
    WHERE m.ctrl = 'Y'
      AND m.contract_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM lineas_raw l WHERE l.song_id = m.song_id AND l.contract_id = m.contract_id)
),
fb_conteo AS (
    SELECT
        ct.contract_id,
        MD5(COALESCE(ct.inclusions, '') || '|' || COALESCE(ct.exclusions, '')) AS h,
        COUNT(*)            AS n,
        MAX(ct.inclusions)  AS inclusions,
        MAX(ct.exclusions)  AS exclusions
    FROM dp_song_metadata.contract_territories ct
    JOIN fb_faltan f ON f.contract_id = ct.contract_id
    GROUP BY ct.contract_id, MD5(COALESCE(ct.inclusions, '') || '|' || COALESCE(ct.exclusions, ''))
),
fb AS (
    SELECT contract_id, inclusions, exclusions
    FROM (
        SELECT c.*, ROW_NUMBER() OVER (PARTITION BY c.contract_id ORDER BY c.n DESC, c.inclusions, c.exclusions) AS rn
        FROM fb_conteo c
    ) x
    WHERE rn = 1
),
-- Contratos involucrados (contract_v filtrada; se lee una sola vez).
contratos_ids AS (
    SELECT associated_contract_id AS contract_id
    FROM dp_song_metadata.song_share_detail_mv
    WHERE song_id IN (SELECT song_id FROM ids) AND associated_contract_id IS NOT NULL
    UNION
    SELECT contract_id
    FROM dp_song_metadata.contract_territories
    WHERE song_id IN (SELECT song_id FROM ids)
),
vinfo AS (
    SELECT
        contract_id,
        MAX(contract_nm)            AS contract_nm,
        MAX(orig_office_nm)         AS orig_office_nm,
        MAX(contract_expiration_dt) AS contract_expiration_dt
    FROM dp_deal_metadata.contract_v
    WHERE contract_id IN (SELECT contract_id FROM contratos_ids)
    GROUP BY contract_id
),
song_info AS (
    SELECT
        song_id,
        MAX(song_title_tx)     AS song_title_tx,
        MAX(tempo_create_date) AS tempo_create_date,
        MAX(song_not_ours_dt)  AS song_not_ours_dt
    FROM dp_song_metadata.song_v
    WHERE song_id IN (SELECT song_id FROM ids)
    GROUP BY song_id
),
iswc AS (   -- un ISWC por obra: el preferido; si no hay, cualquiera
    SELECT
        tempo_song_id AS song_id,
        COALESCE(MAX(CASE WHEN preferred_indicator = 'Y' THEN ident_iswc_cd END), MIN(ident_iswc_cd)) AS iswc
    FROM dp_song_metadata.identifiers_iswc_v
    WHERE tempo_song_id IN (SELECT song_id FROM ids)
      AND ident_iswc_cd IS NOT NULL
    GROUP BY tempo_song_id
),

-- ---------------------------------------------------------------------
-- 2. FLUJO ÚNICO: participaciones (tipo M) + líneas de control (tipo L)
-- ---------------------------------------------------------------------
u0 AS (
    SELECT
        'M' AS tipo, m.song_id, m.contract_id, m.contract_nm_mv, m.ctrl, m.publisher_name_tx, m.grupo_ip,
        m.perf, m.mech, m.sync,
        fb.inclusions, fb.exclusions,
        CASE WHEN fb.contract_id IS NOT NULL THEN 1 ELSE 0 END AS tiene_respaldo
    FROM mv_raw m
    LEFT JOIN fb ON fb.contract_id = m.contract_id
    UNION ALL
    SELECT
        'L', l.song_id, l.contract_id, NULL, NULL, NULL, NULL,
        NULL, NULL, NULL,
        l.inclusions, l.exclusions,
        0
    FROM lineas_raw l
),
-- Normalización: grupo IP como palabras; textos de territorio como ";A;B;".
u1 AS (
    SELECT
        u.*,
        ROW_NUMBER() OVER (ORDER BY u.tipo, u.song_id, u.contract_id) AS rid,
        v.contract_nm            AS contract_nm_v,
        v.orig_office_nm,
        v.contract_expiration_dt,
        ' ' || TRIM(REGEXP_REPLACE(TRANSLATE(u.grupo_ip, 'ÁÉÍÓÚÜÑ', 'AEIOUUN'), '[^A-Z0-9]+', ' ')) || ' ' AS tok,
        ';' || REGEXP_REPLACE(
                   TRIM(REGEXP_REPLACE(
                       REGEXP_REPLACE(
                           UPPER(TRANSLATE(COALESCE(u.inclusions, ''), 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun')),
                           '[[:space:]]*[(]REG[)]', ''),
                       '^[[:space:]]*INCLUDE:[[:space:]]*', '')),
                   '[[:space:]]*;[[:space:]]*', ';') || ';' AS incl,
        ';' || REGEXP_REPLACE(
                   TRIM(REGEXP_REPLACE(
                       REGEXP_REPLACE(
                           UPPER(TRANSLATE(COALESCE(u.exclusions, ''), 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun')),
                           '[[:space:]]*[(]REG[)]', ''),
                       '^[[:space:]]*EXCLUDE:[[:space:]]*', '')),
                   '[[:space:]]*;[[:space:]]*', ';') || ';' AS excl
    FROM u0 u
    LEFT JOIN vinfo v ON v.contract_id = u.contract_id
),
-- Grupo IP: parte incluida y parte excluida ("WORLD EX PHILIPPINES").
u2 AS (
    SELECT u.*, REGEXP_INSTR(u.tok, ' (EX|EXCL|EXCLUDING|EXCEPT|EXCLUDE|EXCLUDES) ') AS pos_excl
    FROM u1 u
),
u3 AS (
    SELECT
        u.*,
        CASE WHEN u.pos_excl > 0 THEN SUBSTRING(u.tok FROM 1 FOR u.pos_excl) ELSE u.tok END AS incl_tok,
        CASE WHEN u.pos_excl > 0 THEN SUBSTRING(u.tok FROM u.pos_excl)       ELSE ''    END AS excl_tok
    FROM u2 u
),
-- Cada fila por cada país, con las coincidencias de país y región.
u4 AS (
    SELECT
        u.rid, u.tipo, u.song_id, u.contract_id, u.contract_nm_mv, u.ctrl, u.publisher_name_tx, u.grupo_ip,
        u.perf, u.mech, u.sync, u.inclusions, u.exclusions, u.tiene_respaldo,
        u.contract_nm_v, u.orig_office_nm, u.contract_expiration_dt, u.incl_tok, u.excl_tok,
        p.pais,
        CASE WHEN TRIM(u.incl_tok) = '' OR u.incl_tok LIKE ' ALL %' OR u.incl_tok LIKE '% WORLD %'
                  OR u.incl_tok LIKE '% WORLDWIDE %' OR u.incl_tok LIKE '% UNIVERSE %' OR u.incl_tok LIKE '% MUNDO %'
             THEN 1 ELSE 0 END AS es_generico,
        MAX(CASE WHEN u.incl_tok LIKE '% ' || p.pais || ' %' THEN 1 ELSE 0 END)                           AS g_pais,
        MAX(CASE WHEN r.region IS NOT NULL AND u.incl_tok LIKE '% ' || r.region || ' %' THEN 1 ELSE 0 END) AS g_region,
        MAX(CASE WHEN u.excl_tok <> '' AND (u.excl_tok LIKE '% ' || p.pais || ' %'
                      OR (r.region IS NOT NULL AND u.excl_tok LIKE '% ' || r.region || ' %')) THEN 1 ELSE 0 END) AS g_excluido,
        MAX(CASE WHEN u.incl LIKE '%;WORLD;%' THEN 1 ELSE 0 END)                                            AS inc_mundo,
        MAX(CASE WHEN u.incl LIKE '%;' || p.pais || ';%' THEN 1 ELSE 0 END)                                 AS inc_pais,
        MAX(CASE WHEN r.region IS NOT NULL AND u.incl LIKE '%;' || r.region || ';%' THEN 1 ELSE 0 END)      AS inc_region,
        MAX(CASE WHEN u.excl LIKE '%;' || p.pais || ';%' THEN 1 ELSE 0 END)                                 AS exc_pais,
        MAX(CASE WHEN r.region IS NOT NULL AND u.excl LIKE '%;' || r.region || ';%' THEN 1 ELSE 0 END)      AS exc_region
    FROM u3 u
    CROSS JOIN paises p
    LEFT JOIN regiones r ON r.pais = p.pais
    GROUP BY
        u.rid, u.tipo, u.song_id, u.contract_id, u.contract_nm_mv, u.ctrl, u.publisher_name_tx, u.grupo_ip,
        u.perf, u.mech, u.sync, u.inclusions, u.exclusions, u.tiene_respaldo,
        u.contract_nm_v, u.orig_office_nm, u.contract_expiration_dt, u.incl_tok, u.excl_tok, p.pais
),
-- Especificidad del grupo (1 país, 2 región, 3 mundial; NULL si no cubre o lo
-- excluye) y cobertura del texto de la fila (línea propia o respaldo).
u5 AS (
    SELECT
        u.*,
        CASE
            WHEN u.tipo <> 'M' OR u.g_excluido = 1          THEN NULL
            WHEN u.es_generico = 0 AND u.g_pais = 1          THEN 1
            WHEN u.es_generico = 0 AND u.g_region = 1        THEN 2
            WHEN u.es_generico = 1                           THEN 3
        END AS spec,
        CASE WHEN u.tipo = 'L' THEN 'OBRA' WHEN u.tiene_respaldo = 1 THEN 'CONTRATO' ELSE 'SIN TEXTO' END AS fuente_fila,
        CASE
            WHEN u.tipo = 'M' AND u.tiene_respaldo = 0       THEN 0
            WHEN u.exc_pais = 1 OR u.exc_region = 1           THEN 0
            WHEN u.inc_mundo = 1 OR u.inc_pais = 1 OR u.inc_region = 1 THEN 1
            ELSE 0
        END AS cubre_fila,
        CASE
            WHEN u.tipo = 'M' AND u.tiene_respaldo = 0       THEN 'Contrato sin texto de territorio: VERIFICAR'
            WHEN u.exc_pais = 1                               THEN 'Contrato: país excluido'
            WHEN u.exc_region = 1                             THEN 'Contrato: región excluida'
            WHEN u.inc_pais = 1                               THEN 'Contrato: país incluido'
            WHEN u.inc_region = 1                             THEN 'Contrato: región incluida'
            WHEN u.inc_mundo = 1                              THEN 'Contrato: World'
            ELSE 'Contrato: país no incluido'
        END
        || CASE WHEN u.tipo = 'M' AND u.tiene_respaldo = 1 THEN ' (texto tomado de otra obra del contrato)' ELSE '' END
        AS regla_fila
    FROM u4 u
),
-- Mejor grupo por obra y país; cobertura de la línea propia del contrato;
-- ¿alguna línea de la obra cubre el país?
u6 AS (
    SELECT
        u.*,
        MIN(u.spec) OVER (PARTITION BY u.song_id, u.pais) AS best_spec,
        MAX(CASE WHEN u.tipo = 'L' THEN 1 ELSE 0 END) OVER (PARTITION BY u.song_id, u.pais, u.contract_id) AS tiene_linea,
        MAX(CASE WHEN u.tipo = 'L' THEN u.cubre_fila END) OVER (PARTITION BY u.song_id, u.pais, u.contract_id) AS linea_cubre,
        MAX(CASE WHEN u.tipo = 'L' THEN u.regla_fila END) OVER (PARTITION BY u.song_id, u.pais, u.contract_id) AS linea_regla,
        MAX(CASE WHEN u.tipo = 'L' AND u.cubre_fila = 1 THEN 1 ELSE 0 END) OVER (PARTITION BY u.song_id, u.pais) AS alguna_linea_cubre
    FROM u5 u
),
u7 AS (
    SELECT
        u.*,
        MIN(CASE WHEN u.spec = u.best_spec THEN u.grupo_ip END) OVER (PARTITION BY u.song_id, u.pais) AS grupo_elegido,
        DENSE_RANK() OVER (PARTITION BY u.song_id, u.pais, CASE WHEN u.spec = u.best_spec THEN 1 ELSE 0 END
                           ORDER BY u.grupo_ip) AS dr_grupo,
        -- cobertura del contrato asociado a la participación
        CASE WHEN u.contract_id IS NULL THEN NULL WHEN u.tiene_linea = 1 THEN u.linea_cubre ELSE u.cubre_fila END AS cob_cubre,
        CASE WHEN u.contract_id IS NULL THEN NULL WHEN u.tiene_linea = 1 THEN u.linea_regla ELSE u.regla_fila END AS cob_regla,
        CASE WHEN u.contract_id IS NULL THEN NULL WHEN u.tiene_linea = 1 THEN 'OBRA'        ELSE u.fuente_fila END AS cob_fuente
    FROM u6 u
),
u8 AS (
    SELECT
        u.*,
        MAX(CASE WHEN u.spec = u.best_spec THEN u.dr_grupo END) OVER (PARTITION BY u.song_id, u.pais) AS n_empate,
        CASE WHEN u.tipo = 'M' AND u.ctrl = 'Y' AND u.grupo_ip = u.grupo_elegido THEN 1 ELSE 0 END AS es_det,
        CASE
            WHEN u.contract_id IS NULL      THEN 1
            WHEN u.cob_cubre = 1            THEN 1
            WHEN u.alguna_linea_cubre = 1   THEN 1
            ELSE 0
        END AS cubre_det,
        CASE WHEN u.contract_id IS NULL THEN 1 ELSE COALESCE(u.cob_cubre, 0) END AS cubre_asoc,
        CASE
            WHEN u.contract_id IS NULL        THEN 'Participación sin contrato asociado'
            WHEN u.cob_cubre = 1              THEN u.cob_regla
            WHEN u.alguna_linea_cubre = 1
                THEN 'Otra línea de control de la obra cubre el país (contrato asociado: ' || COALESCE(u.cob_regla, 'sin texto') || ')'
            ELSE u.cob_regla
        END AS regla_det,
        -- contrato del alcance territorial: línea propia, o contrato de participación controlada sin línea propia
        CASE WHEN u.tipo = 'L' THEN 1
             WHEN u.tipo = 'M' AND u.ctrl = 'Y' AND u.contract_id IS NOT NULL AND u.tiene_linea = 0 THEN 1
             ELSE 0 END AS es_alcance,
        CAST(COALESCE(CAST(u.contract_id AS VARCHAR(30)), 'SIN CONTRATO') || ' - '
             || CAST(COALESCE(u.contract_nm_mv, 'Sin nombre') AS VARCHAR(200)) AS VARCHAR(250)) AS etiqueta_pais,
        CAST(
            COALESCE(CAST(u.contract_id AS VARCHAR(30)), 'SIN CONTRATO') || ' - '
            || CAST(COALESCE(u.contract_nm_mv, 'Sin nombre') AS VARCHAR(200))
            || ' [ctrl:' || CAST(COALESCE(u.ctrl, '?') AS VARCHAR(5)) || '] '
            || CAST(CASE
                        WHEN u.contract_expiration_dt IS NULL THEN 'sin venc.'
                        WHEN u.contract_expiration_dt < CURRENT_DATE THEN 'VENCIDO ' || CAST(u.contract_expiration_dt AS VARCHAR(10))
                        ELSE 'vig. ' || CAST(u.contract_expiration_dt AS VARCHAR(10))
                    END AS VARCHAR(40))
        AS VARCHAR(300)) AS etiqueta_obra
    FROM u7 u
),
-- Marcas de "primera aparición" para listar valores sin repetir.
u9 AS (
    SELECT
        u.*,
        CASE WHEN u.es_det = 1 AND u.cubre_det = 1 THEN 1 ELSE 0 END AS es_ctrl,
        ROW_NUMBER() OVER (PARTITION BY u.song_id, u.pais, u.es_det, u.cubre_det, u.publisher_name_tx ORDER BY u.rid) AS rn_pub,
        ROW_NUMBER() OVER (PARTITION BY u.song_id, u.pais, u.es_det, u.cubre_det, u.etiqueta_pais      ORDER BY u.rid) AS rn_cpais,
        ROW_NUMBER() OVER (PARTITION BY u.song_id, u.pais, u.es_det, u.regla_det                      ORDER BY u.rid) AS rn_regla,
        ROW_NUMBER() OVER (PARTITION BY u.song_id, u.pais, u.tipo, u.contract_id, u.contract_nm_mv, u.ctrl ORDER BY u.rid) AS rn_cobra,
        ROW_NUMBER() OVER (PARTITION BY u.song_id, u.pais, u.tipo, u.orig_office_nm                   ORDER BY u.rid) AS rn_ofi,
        ROW_NUMBER() OVER (PARTITION BY u.song_id, u.pais, u.tipo, u.grupo_ip                         ORDER BY u.rid) AS rn_grupo,
        ROW_NUMBER() OVER (PARTITION BY u.song_id, u.pais, u.es_alcance, u.contract_id                ORDER BY u.rid) AS rn_alcance
    FROM u8 u
),
u10 AS (
    SELECT
        u.*,
        CASE WHEN u.es_alcance = 1 AND u.rn_alcance = 1 THEN 1 ELSE 0 END AS alc,
        CASE WHEN u.es_alcance = 1 AND u.rn_alcance = 1 AND u.cubre_fila = 1 THEN 1 ELSE 0 END AS alc_cubre,
        LPAD(CAST(u.contract_id AS VARCHAR(20)), 20, '0') AS orden_contrato
    FROM u9 u
),
-- Una fila por cada lista en la que participa cada fila (ver encabezado).
listas AS (
              SELECT 'base' AS lst
    UNION ALL SELECT 'pub'
    UNION ALL SELECT 'cpais'
    UNION ALL SELECT 'regla'
    UNION ALL SELECT 'cobra'
    UNION ALL SELECT 'ofi'
    UNION ALL SELECT 'grupo'
    UNION ALL SELECT 'lobra'
    UNION ALL SELECT 'lcubre'
    UNION ALL SELECT 'audit'
),
u11 AS (
    SELECT
        u.*,
        x.lst,
        CASE x.lst
            WHEN 'pub'    THEN CASE WHEN u.es_ctrl = 1 AND u.rn_pub = 1 THEN u.publisher_name_tx END
            WHEN 'cpais'  THEN CASE WHEN u.es_ctrl = 1 AND u.rn_cpais = 1 THEN u.etiqueta_pais END
            WHEN 'regla'  THEN CASE WHEN u.es_det = 1 AND u.rn_regla = 1 THEN u.regla_det END
            WHEN 'cobra'  THEN CASE WHEN u.tipo = 'M' AND u.rn_cobra = 1 THEN u.etiqueta_obra END
            WHEN 'ofi'    THEN CASE WHEN u.tipo = 'M' AND u.rn_ofi = 1 THEN u.orig_office_nm END
            WHEN 'grupo'  THEN CASE WHEN u.tipo = 'M' AND u.rn_grupo = 1 THEN CASE WHEN u.grupo_ip = '' THEN '(sin nombre)' ELSE u.grupo_ip END END
            WHEN 'lobra'  THEN CASE WHEN u.tipo = 'L'
                                    THEN CAST(u.contract_id AS VARCHAR(20)) || ' - ' || CAST(COALESCE(u.contract_nm_v, 'Sin nombre') AS VARCHAR(150)) END
            WHEN 'lcubre' THEN CASE WHEN u.alc_cubre = 1
                                    THEN CAST(u.contract_id AS VARCHAR(20)) || ' - ' || CAST(COALESCE(u.contract_nm_v, 'Sin nombre') AS VARCHAR(150))
                                         || ' ['
                                         || CASE
                                                WHEN u.contract_expiration_dt IS NULL THEN 'sin venc.'
                                                WHEN u.contract_expiration_dt < CURRENT_DATE THEN 'VENCIDO ' || CAST(u.contract_expiration_dt AS VARCHAR(10))
                                                ELSE 'vig. ' || CAST(u.contract_expiration_dt AS VARCHAR(10))
                                            END
                                         || ']' END
            WHEN 'audit'  THEN CASE WHEN u.alc = 1
                                    THEN CAST(u.contract_id AS VARCHAR(20)) || ' [' || u.fuente_fila || '] cubre=' || CAST(u.cubre_fila AS VARCHAR(1))
                                         || ' | ' || u.regla_fila
                                         || ' | INC: ' || SUBSTRING(COALESCE(u.inclusions, '(vacio)'), 1, 100)
                                         || ' | EXC: ' || SUBSTRING(COALESCE(u.exclusions, '(vacio)'), 1, 100) END
        END AS item,
        CASE x.lst
            WHEN 'pub'    THEN u.publisher_name_tx
            WHEN 'cpais'  THEN u.etiqueta_pais
            WHEN 'regla'  THEN u.regla_det
            WHEN 'cobra'  THEN u.etiqueta_obra
            WHEN 'ofi'    THEN u.orig_office_nm
            WHEN 'grupo'  THEN u.grupo_ip
            ELSE u.orden_contrato
        END AS orden
    FROM u10 u
    CROSS JOIN listas x
),

-- ---------------------------------------------------------------------
-- 3. UNA FILA POR OBRA Y PAÍS
-- ---------------------------------------------------------------------
res AS (
    SELECT
        song_id,
        pais,
        SUM(CASE WHEN lst = 'base' AND tipo = 'M' THEN 1 ELSE 0 END)                       AS n_mv,
        MAX(CASE WHEN lst = 'base' THEN best_spec END)                                     AS especificidad,
        MAX(CASE WHEN lst = 'base' THEN grupo_elegido END)                                 AS grupo_ip,
        MAX(CASE WHEN lst = 'base' THEN n_empate END)                                      AS n_empate,
        SUM(CASE WHEN lst = 'base' AND es_ctrl = 1 THEN 1 ELSE 0 END)                      AS n_det,
        SUM(CASE WHEN lst = 'base' AND es_ctrl = 1 THEN perf END)                          AS perf,
        SUM(CASE WHEN lst = 'base' AND es_ctrl = 1 THEN mech END)                          AS mech,
        SUM(CASE WHEN lst = 'base' AND es_ctrl = 1 THEN sync END)                          AS sync,
        MAX(CASE WHEN lst = 'base' AND es_ctrl = 1 AND contract_id IS NULL THEN 1 ELSE 0 END) AS hay_sin_contrato,
        MAX(CASE WHEN lst = 'base' AND es_det = 1 AND cob_fuente = 'SIN TEXTO' AND cubre_det = 0 THEN 1 ELSE 0 END) AS hay_sin_texto,
        MAX(CASE WHEN lst = 'base' AND es_det = 1 AND cob_fuente = 'CONTRATO' AND cubre_asoc = 1 THEN 1 ELSE 0 END) AS hay_texto_prestado,
        MAX(CASE WHEN lst = 'base' AND es_det = 1 AND cubre_det = 1 AND cubre_asoc = 0 THEN 1 ELSE 0 END)      AS hay_otra_linea,
        SUM(CASE WHEN lst = 'pub'   AND item IS NOT NULL THEN 1 ELSE 0 END)                AS cantidad_publishers,
        SUM(CASE WHEN lst = 'cpais' AND item IS NOT NULL THEN 1 ELSE 0 END)                AS cantidad_contratos_pais,
        SUM(CASE WHEN lst = 'cobra' AND item IS NOT NULL THEN 1 ELSE 0 END)                AS cantidad_contratos_obra,
        SUM(CASE WHEN lst = 'base' AND alc_cubre = 1 THEN 1 ELSE 0 END)                    AS n_lineas,
        SUM(CASE WHEN lst = 'base' AND alc_cubre = 1 AND contract_expiration_dt < CURRENT_DATE THEN 1 ELSE 0 END)  AS n_vencidos,
        SUM(CASE WHEN lst = 'base' AND alc_cubre = 1 AND contract_expiration_dt >= CURRENT_DATE THEN 1 ELSE 0 END) AS n_vigentes,
        MIN(CASE WHEN lst = 'base' AND alc_cubre = 1 THEN contract_expiration_dt END)      AS venc_proximo,
        MAX(CASE WHEN lst = 'base' AND alc_cubre = 1 THEN contract_expiration_dt END)      AS venc_lejano,
        NULLIF(LISTAGG(CASE WHEN lst = 'pub'    THEN item END, ' | ')  WITHIN GROUP (ORDER BY orden), '') AS publishers,
        NULLIF(LISTAGG(CASE WHEN lst = 'cpais'  THEN item END, ' | ')  WITHIN GROUP (ORDER BY orden), '') AS contratos_del_pais,
        NULLIF(LISTAGG(CASE WHEN lst = 'regla'  THEN item END, ' | ')  WITHIN GROUP (ORDER BY orden), '') AS regla_territorial,
        NULLIF(LISTAGG(CASE WHEN lst = 'cobra'  THEN item END, ' | ')  WITHIN GROUP (ORDER BY orden), '') AS todos_los_contratos,
        NULLIF(LISTAGG(CASE WHEN lst = 'ofi'    THEN item END, ' | ')  WITHIN GROUP (ORDER BY orden), '') AS originating_office,
        NULLIF(LISTAGG(CASE WHEN lst = 'grupo'  THEN item END, ' | ')  WITHIN GROUP (ORDER BY orden), '') AS grupos_ip_de_la_obra,
        NULLIF(LISTAGG(CASE WHEN lst = 'lobra'  THEN item END, ' | ')  WITHIN GROUP (ORDER BY orden), '') AS lineas_de_control_obra,
        NULLIF(LISTAGG(CASE WHEN lst = 'lcubre' THEN item END, ' | ')  WITHIN GROUP (ORDER BY orden), '') AS lineas_que_cubren_el_pais,
        NULLIF(LISTAGG(CASE WHEN lst = 'audit'  THEN item END, ' || ') WITHIN GROUP (ORDER BY orden), '') AS texto_territorio_contratos
    FROM u11
    GROUP BY song_id, pais
)

-- ---------------------------------------------------------------------
-- 4. RESULTADO
-- ---------------------------------------------------------------------
SELECT
    i.song_id,
    COALESCE(si.song_title_tx, 'Sin título')          AS song_title_tx,
    iw.iswc                                           AS iswc,
    p.pais,

    CASE
        WHEN si.song_not_ours_dt IS NOT NULL AND si.song_not_ours_dt <= CURRENT_DATE THEN 'NOP'
        WHEN COALESCE(r.n_mv, 0) = 0 THEN 'SIN DATOS'
        WHEN COALESCE(r.perf, 0) = 0 THEN 'NVFT'
        ELSE CAST(CAST(r.perf AS NUMERIC(10,2)) AS VARCHAR(20))
    END AS performance_pc_total,
    CASE
        WHEN si.song_not_ours_dt IS NOT NULL AND si.song_not_ours_dt <= CURRENT_DATE THEN 'NOP'
        WHEN COALESCE(r.n_mv, 0) = 0 THEN 'SIN DATOS'
        WHEN COALESCE(r.mech, 0) = 0 THEN 'NVFT'
        ELSE CAST(CAST(r.mech AS NUMERIC(10,2)) AS VARCHAR(20))
    END AS mechanical_pc_total,
    CASE
        WHEN si.song_not_ours_dt IS NOT NULL AND si.song_not_ours_dt <= CURRENT_DATE THEN 'NOP'
        WHEN COALESCE(r.n_mv, 0) = 0 THEN 'SIN DATOS'
        WHEN COALESCE(r.sync, 0) = 0 THEN 'NVFT'
        ELSE CAST(CAST(r.sync AS NUMERIC(10,2)) AS VARCHAR(20))
    END AS sync_pc_total,

    COALESCE(r.publishers, 'N/A')                     AS publishers,
    COALESCE(r.cantidad_publishers, 0)                AS cantidad_publishers,
    COALESCE(r.contratos_del_pais, 'N/A')             AS contratos_del_pais,
    COALESCE(r.cantidad_contratos_pais, 0)            AS cantidad_contratos_del_pais,
    r.todos_los_contratos,
    CASE WHEN COALESCE(r.n_mv, 0) = 0 THEN NULL ELSE r.cantidad_contratos_obra END AS cantidad_contratos_obra,
    r.originating_office,
    si.tempo_create_date                              AS song_tempo_create_date,
    si.song_not_ours_dt,
    CASE
        WHEN si.song_not_ours_dt IS NOT NULL AND si.song_not_ours_dt <= CURRENT_DATE THEN 'VENCIDA (NOP)'
        ELSE 'ACTIVA'
    END                                               AS estado_obra,
    CASE WHEN COALESCE(r.n_lineas, 0) > 0 THEN r.venc_proximo END AS contrato_venc_mas_proximo,
    CASE WHEN COALESCE(r.n_lineas, 0) > 0 THEN r.venc_lejano  END AS contrato_venc_mas_lejano,
    CASE
        WHEN COALESCE(r.n_det, 0) = 0            THEN 'SIN CONTROL'
        WHEN COALESCE(r.n_lineas, 0) = 0         THEN 'SIN LINEA DE CONTROL'
        WHEN r.n_vencidos = r.n_lineas           THEN 'TODOS VENCIDOS'
        WHEN r.n_vencidos > 0                    THEN 'MIXTO (alguno vencido)'
        WHEN r.n_vigentes = 0                    THEN 'SIN VENCIMIENTO'
        ELSE 'VIGENTE'
    END                                               AS estado_contrato,

    -- Auditoría
    CASE WHEN r.especificidad IS NULL THEN NULL WHEN r.grupo_ip = '' THEN '(sin nombre)' ELSE r.grupo_ip END AS grupo_ip_usado,
    CASE r.especificidad
        WHEN 1 THEN 'Grupo nombra al país'
        WHEN 2 THEN 'Grupo nombra una región que lo incluye'
        WHEN 3 THEN 'Grupo mundial'
        ELSE 'Ningún grupo de la obra cubre el país'
    END                                               AS como_se_eligio_grupo,
    COALESCE(r.regla_territorial, '—')                AS regla_territorial,
    r.grupos_ip_de_la_obra,
    r.lineas_de_control_obra,
    r.lineas_que_cubren_el_pais,
    r.texto_territorio_contratos,
    NULLIF(
        CASE WHEN r.especificidad IS NOT NULL AND r.n_empate > 1 THEN 'VARIOS GRUPOS CON LA MISMA PRIORIDAD; ' ELSE '' END
        || CASE WHEN r.hay_sin_contrato = 1 THEN 'PARTICIPACION SIN CONTRATO; ' ELSE '' END
        || CASE WHEN COALESCE(r.n_mv, 0) = 0 THEN 'OBRA AUSENTE EN song_share_detail_mv (revisar writers sin sociedad, secuencia o grupo de pais); ' ELSE '' END
        || CASE WHEN r.hay_sin_texto = 1 THEN 'CONTRATO SIN TEXTO DE TERRITORIO: sin rate client/payment option activo (VERIFICAR); ' ELSE '' END
        || CASE WHEN COALESCE(r.perf, 0) > 100 OR COALESCE(r.mech, 0) > 100 OR COALESCE(r.sync, 0) > 100
                THEN 'TOTAL SUPERA 100 (posible doble conteo en la cadena de publishers); ' ELSE '' END
        || CASE WHEN r.hay_texto_prestado = 1 THEN 'TERRITORIO TOMADO DE OTRA OBRA DEL CONTRATO; ' ELSE '' END
        || CASE WHEN r.hay_otra_linea = 1 THEN 'CONTROL SOSTENIDO POR OTRA LINEA DE CONTROL (el contrato asociado a la participacion no cubre el pais); ' ELSE '' END
    , '')                                             AS alertas

FROM ids i
CROSS JOIN paises p
LEFT JOIN res r        ON r.song_id = i.song_id AND r.pais = p.pais
LEFT JOIN song_info si ON si.song_id = i.song_id
LEFT JOIN iswc iw      ON iw.song_id = i.song_id
ORDER BY i.song_id, p.pais;
