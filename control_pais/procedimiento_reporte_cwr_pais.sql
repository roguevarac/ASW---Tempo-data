-- =====================================================================
-- PROCEDIMIENTO: reporte CWR v8 para un país, sobre sus obras controladas (por tandas)
--
-- No editar acá: se genera desde reporte_cwr/reporte_cwr_x_territorio_v8.sql con
--   python3 control_pais/tools/generar_unload.py
-- ANTES: tiene que estar cargado el país en public.obras_controladas_pais_resultado
-- (CALL public.sp_obras_controladas_pais('PAIS', 500000, 0)).
--
-- PASO 1 (una vez, y cada vez que te pase una versión nueva): ejecutar TODO este
--   archivo. Crea o actualiza public.control_pais_claves (formas de escritura de
--   cada país), public.reporte_cwr_pais_resultado (resultado), public.reporte_cwr_pais_log
--   (avance) y el procedimiento. NO borra resultados ya guardados.
--   Países disponibles: 'ARGENTINA', 'CHILE', 'PERU', 'URUGUAY', 'COLOMBIA', 'BRASIL', 'UNITED STATES'.
-- PASO 2: correr, con el país entre comillas:
--     CALL public.sp_reporte_cwr_pais('CHILE', 500000, 0);
--   (tandas de 500.000 Tempo ID; desde 0 = borra solo lo de ese país y empieza
--   de cero). Cada país queda guardado aparte (columna pais).
--   Avance:  SELECT * FROM public.reporte_cwr_pais_log WHERE pais = 'CHILE' ORDER BY tanda;
-- PASO 3: el archivo de ese país:
--     UNLOAD ('SELECT * FROM public.reporte_cwr_pais_resultado WHERE pais = ''CHILE'' ORDER BY song_id')
--     TO 's3://dw-export-prod/7000042560/reporte_cwr_pais_chile_'
--     IAM_ROLE 'arn:aws:iam::991042281579:role/DataWarehouse/RedShift-S3-Unload'
--     FORMAT AS CSV HEADER EXTENSION 'csv' PARALLEL OFF MAXFILESIZE 1 GB ALLOWOVERWRITE;
--
-- Si se corta: lo ya confirmado queda guardado. Ver en el log el "hasta" de la
-- última tanda y seguir desde el siguiente Tempo ID, sin borrar:
--     CALL public.sp_reporte_cwr_pais('CHILE', 500000, <hasta + 1>);
-- Si una tanda tarda demasiado, usar un tamaño menor (ej. 250000).
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.control_pais_claves (
    pais   VARCHAR(100),
    tipo   VARCHAR(1),
    clave  VARCHAR(200),
    orden  INTEGER
);
DELETE FROM public.control_pais_claves;
INSERT INTO public.control_pais_claves (pais, tipo, clave, orden) VALUES
    ('ARGENTINA', 'P', 'ARGENTINA', 1),
    ('ARGENTINA', 'R', 'LATIN AMERICA', 2),
    ('ARGENTINA', 'R', 'SOUTH AMERICA', 3),
    ('CHILE', 'P', 'CHILE', 1),
    ('CHILE', 'R', 'LATIN AMERICA', 2),
    ('CHILE', 'R', 'SOUTH AMERICA', 3),
    ('PERU', 'P', 'PERU', 1),
    ('PERU', 'R', 'LATIN AMERICA', 2),
    ('PERU', 'R', 'SOUTH AMERICA', 3),
    ('URUGUAY', 'P', 'URUGUAY', 1),
    ('URUGUAY', 'R', 'LATIN AMERICA', 2),
    ('URUGUAY', 'R', 'SOUTH AMERICA', 3),
    ('COLOMBIA', 'P', 'COLOMBIA', 1),
    ('COLOMBIA', 'R', 'LATIN AMERICA', 2),
    ('COLOMBIA', 'R', 'SOUTH AMERICA', 3),
    ('BRASIL', 'P', 'BRAZIL', 1),
    ('BRASIL', 'P', 'BRASIL', 2),
    ('BRASIL', 'R', 'LATIN AMERICA', 3),
    ('BRASIL', 'R', 'SOUTH AMERICA', 4),
    ('UNITED STATES', 'P', 'UNITED STATES', 1),
    ('UNITED STATES', 'P', 'UNITED STATES OF AMERICA', 2),
    ('UNITED STATES', 'P', 'USA', 3),
    ('UNITED STATES', 'P', 'US', 4),
    ('UNITED STATES', 'P', 'U S A', 5),
    ('UNITED STATES', 'P', 'U S', 6),
    ('UNITED STATES', 'R', 'NORTH AMERICA', 7),
    ('UNITED STATES', 'R', 'US AND CANADA', 8),
    ('UNITED STATES', 'R', 'US & CANADA', 9),
    ('UNITED STATES', 'R', 'USA AND CANADA', 10),
    ('UNITED STATES', 'R', 'USA & CANADA', 11);

CREATE TABLE IF NOT EXISTS public.reporte_cwr_pais_resultado (
    song_id BIGINT,
    song_title_tx VARCHAR(2000),
    iswc VARCHAR(100),
    pais VARCHAR(100),
    performance_pc_total VARCHAR(20),
    mechanical_pc_total VARCHAR(20),
    sync_pc_total VARCHAR(20),
    publishers VARCHAR(65535),
    cantidad_publishers BIGINT,
    contratos_del_pais VARCHAR(65535),
    cantidad_contratos_del_pais BIGINT,
    todos_los_contratos VARCHAR(65535),
    cantidad_contratos_obra BIGINT,
    originating_office VARCHAR(65535),
    song_tempo_create_date TIMESTAMP,
    song_not_ours_dt TIMESTAMP,
    estado_obra VARCHAR(50),
    contrato_venc_mas_proximo TIMESTAMP,
    contrato_venc_mas_lejano TIMESTAMP,
    estado_contrato VARCHAR(50),
    grupo_ip_usado VARCHAR(2000),
    como_se_eligio_grupo VARCHAR(100),
    regla_territorial VARCHAR(65535),
    grupos_ip_de_la_obra VARCHAR(65535),
    lineas_de_control_obra VARCHAR(65535),
    lineas_que_cubren_el_pais VARCHAR(65535),
    texto_territorio_contratos VARCHAR(65535),
    alertas VARCHAR(4000)
);

-- El log se rehace (ahora lleva el país); el resultado no se toca.
DROP TABLE IF EXISTS public.reporte_cwr_pais_log;
CREATE TABLE public.reporte_cwr_pais_log (
    pais      VARCHAR(100),
    tanda     INTEGER,
    desde     BIGINT,
    hasta     BIGINT,
    filas     BIGINT,
    inicio    VARCHAR(60),
    fin       VARCHAR(60)
);

CREATE OR REPLACE PROCEDURE public.sp_reporte_cwr_pais(p_pais VARCHAR(100), p_tamano BIGINT, p_desde BIGINT)
AS $$
DECLARE
    v_max    BIGINT;
    v_desde  BIGINT;
    v_hasta  BIGINT;
    v_filas  BIGINT;
    v_tanda  INTEGER;
    v_claves INTEGER;
    v_inicio VARCHAR(60);
BEGIN
    IF p_tamano IS NULL OR p_tamano < 1 THEN
        RAISE EXCEPTION 'El tamaño de tanda tiene que ser mayor que 0';
    END IF;
    SELECT COUNT(*) INTO v_claves FROM public.control_pais_claves WHERE pais = p_pais;
    IF v_claves = 0 THEN
        RAISE EXCEPTION 'País % sin formas de escritura en public.control_pais_claves', p_pais;
    END IF;
    IF p_desde = 0 THEN
        DELETE FROM public.reporte_cwr_pais_resultado WHERE pais = p_pais;
        DELETE FROM public.reporte_cwr_pais_log WHERE pais = p_pais;
        COMMIT;
    END IF;
    SELECT CAST(MAX(song_id) AS BIGINT) INTO v_max FROM public.obras_controladas_pais_resultado WHERE pais = p_pais;
    SELECT COALESCE(MAX(tanda), 0) INTO v_tanda FROM public.reporte_cwr_pais_log WHERE pais = p_pais;
    v_desde := p_desde;
    WHILE v_desde <= v_max LOOP
        v_hasta  := v_desde + p_tamano - 1;
        v_tanda  := v_tanda + 1;
        v_inicio := TIMEOFDAY();
        EXECUTE 'INSERT INTO public.reporte_cwr_pais_resultado (song_id, song_title_tx, iswc, pais, performance_pc_total, mechanical_pc_total, sync_pc_total, publishers, cantidad_publishers, contratos_del_pais, cantidad_contratos_del_pais, todos_los_contratos, cantidad_contratos_obra, originating_office, song_tempo_create_date, song_not_ours_dt, estado_obra, contrato_venc_mas_proximo, contrato_venc_mas_lejano, estado_contrato, grupo_ip_usado, como_se_eligio_grupo, regla_territorial, grupos_ip_de_la_obra, lineas_de_control_obra, lineas_que_cubren_el_pais, texto_territorio_contratos, alertas)
WITH

ids AS (
    SELECT DISTINCT CAST(t.song_id AS BIGINT) AS song_id
    FROM public.obras_controladas_pais_resultado t
    WHERE t.pais = ' || QUOTE_LITERAL(p_pais) || ' AND t.song_id BETWEEN ' || CAST(v_desde AS VARCHAR(20)) || ' AND ' || CAST(v_hasta AS VARCHAR(20)) || '
),
paises AS (
    SELECT c.pais FROM public.control_pais_claves c WHERE c.pais = ' || QUOTE_LITERAL(p_pais) || ' AND c.orden = 1
),
alias_pais AS (
    SELECT c.pais, c.clave AS alias FROM public.control_pais_claves c WHERE c.tipo = ''P''
),
regiones AS (
    SELECT c.clave AS region, c.pais FROM public.control_pais_claves c WHERE c.tipo = ''R''
),

mv_raw AS (
    SELECT
        s.song_id,
        s.associated_contract_id                          AS contract_id,
        s.associated_contract_nm                          AS contract_nm_mv,
        s.smp_controlled_ind                              AS ctrl,
        s.publisher_name_tx,
        UPPER(TRIM(COALESCE(s.song_ip_territory_nm, ''''))) AS grupo_ip,
        s.publisher_performance_pc                        AS perf,
        s.publisher_mechanical_pc                         AS mech,
        s.publisher_sync_pc                               AS sync
    FROM dp_song_metadata.song_share_detail_mv s
    WHERE s.song_id BETWEEN ' || CAST(v_desde AS VARCHAR(20)) || ' AND ' || CAST(v_hasta AS VARCHAR(20)) || ' AND s.song_id IN (SELECT song_id FROM ids)
),
lineas_raw AS (
    SELECT song_id, contract_id, inclusions, exclusions
    FROM (
        SELECT
            ct.song_id, ct.contract_id, ct.inclusions, ct.exclusions,
            ROW_NUMBER() OVER (PARTITION BY ct.song_id, ct.contract_id
                               ORDER BY ct.inclusions, CASE WHEN ct.exclusions IS NULL THEN 1 ELSE 0 END, ct.exclusions) AS rn
        FROM dp_song_metadata.contract_territories ct
        WHERE ct.song_id BETWEEN ' || CAST(v_desde AS VARCHAR(20)) || ' AND ' || CAST(v_hasta AS VARCHAR(20)) || ' AND ct.song_id IN (SELECT song_id FROM ids)
    ) x
    WHERE rn = 1
),
fb_faltan AS (
    SELECT DISTINCT m.contract_id
    FROM mv_raw m
    WHERE m.ctrl = ''Y''
      AND m.contract_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM lineas_raw l WHERE l.song_id = m.song_id AND l.contract_id = m.contract_id)
),
fb_conteo AS (
    SELECT
        ct.contract_id,
        MD5(COALESCE(ct.inclusions, '''') || ''|'' || COALESCE(ct.exclusions, '''')) AS h,
        COUNT(*)            AS n,
        MAX(ct.inclusions)  AS inclusions,
        MAX(ct.exclusions)  AS exclusions
    FROM dp_song_metadata.contract_territories ct
    JOIN fb_faltan f ON f.contract_id = ct.contract_id
    GROUP BY ct.contract_id, MD5(COALESCE(ct.inclusions, '''') || ''|'' || COALESCE(ct.exclusions, ''''))
),
fb AS (
    SELECT contract_id, inclusions, exclusions
    FROM (
        SELECT c.*, ROW_NUMBER() OVER (PARTITION BY c.contract_id ORDER BY c.n DESC, c.inclusions, c.exclusions) AS rn
        FROM fb_conteo c
    ) x
    WHERE rn = 1
),
contratos_ids AS (
    SELECT associated_contract_id AS contract_id
    FROM dp_song_metadata.song_share_detail_mv
    WHERE song_id BETWEEN ' || CAST(v_desde AS VARCHAR(20)) || ' AND ' || CAST(v_hasta AS VARCHAR(20)) || ' AND song_id IN (SELECT song_id FROM ids) AND associated_contract_id IS NOT NULL
    UNION
    SELECT contract_id
    FROM dp_song_metadata.contract_territories
    WHERE song_id BETWEEN ' || CAST(v_desde AS VARCHAR(20)) || ' AND ' || CAST(v_hasta AS VARCHAR(20)) || ' AND song_id IN (SELECT song_id FROM ids)
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
    WHERE song_id BETWEEN ' || CAST(v_desde AS VARCHAR(20)) || ' AND ' || CAST(v_hasta AS VARCHAR(20)) || ' AND song_id IN (SELECT song_id FROM ids)
    GROUP BY song_id
),
iswc AS (
    SELECT
        tempo_song_id AS song_id,
        COALESCE(MAX(CASE WHEN preferred_indicator = ''Y'' THEN ident_iswc_cd END), MIN(ident_iswc_cd)) AS iswc
    FROM dp_song_metadata.identifiers_iswc_v
    WHERE tempo_song_id BETWEEN ' || CAST(v_desde AS VARCHAR(20)) || ' AND ' || CAST(v_hasta AS VARCHAR(20)) || ' AND tempo_song_id IN (SELECT song_id FROM ids)
      AND ident_iswc_cd IS NOT NULL
    GROUP BY tempo_song_id
),

u0 AS (
    SELECT
        ''M'' AS tipo, m.song_id, m.contract_id, m.contract_nm_mv, m.ctrl, m.publisher_name_tx, m.grupo_ip,
        m.perf, m.mech, m.sync,
        fb.inclusions, fb.exclusions,
        CASE WHEN fb.contract_id IS NOT NULL THEN 1 ELSE 0 END AS tiene_respaldo
    FROM mv_raw m
    LEFT JOIN fb ON fb.contract_id = m.contract_id
    UNION ALL
    SELECT
        ''L'', l.song_id, l.contract_id, NULL, NULL, NULL, NULL,
        NULL, NULL, NULL,
        l.inclusions, l.exclusions,
        0
    FROM lineas_raw l
),
u1 AS (
    SELECT
        u.*,
        ROW_NUMBER() OVER (ORDER BY u.tipo, u.song_id, u.contract_id) AS rid,
        v.contract_nm            AS contract_nm_v,
        v.orig_office_nm,
        v.contract_expiration_dt,
        '' '' || TRIM(REGEXP_REPLACE(TRANSLATE(u.grupo_ip, ''ÁÉÍÓÚÜÑ'', ''AEIOUUN''), ''[^A-Z0-9]+'', '' '')) || '' '' AS tok,
        '';'' || REGEXP_REPLACE(
                   TRIM(REGEXP_REPLACE(
                       REGEXP_REPLACE(
                           UPPER(TRANSLATE(COALESCE(u.inclusions, ''''), ''ÁÉÍÓÚÜÑáéíóúüñ'', ''AEIOUUNaeiouun'')),
                           ''[[:space:]]*[(]REG[)]'', ''''),
                       ''^[[:space:]]*INCLUDE:[[:space:]]*'', '''')),
                   ''[[:space:]]*;[[:space:]]*'', '';'') || '';'' AS incl,
        '';'' || REGEXP_REPLACE(
                   TRIM(REGEXP_REPLACE(
                       REGEXP_REPLACE(
                           UPPER(TRANSLATE(COALESCE(u.exclusions, ''''), ''ÁÉÍÓÚÜÑáéíóúüñ'', ''AEIOUUNaeiouun'')),
                           ''[[:space:]]*[(]REG[)]'', ''''),
                       ''^[[:space:]]*EXCLUDE:[[:space:]]*'', '''')),
                   ''[[:space:]]*;[[:space:]]*'', '';'') || '';'' AS excl
    FROM u0 u
    LEFT JOIN vinfo v ON v.contract_id = u.contract_id
),
u2 AS (
    SELECT u.*, REGEXP_INSTR(u.tok, '' (EX|EXCL|EXCLUDING|EXCEPT|EXCLUDE|EXCLUDES) '') AS pos_excl
    FROM u1 u
),
u3 AS (
    SELECT
        u.*,
        CASE WHEN u.pos_excl > 0 THEN SUBSTRING(u.tok FROM 1 FOR u.pos_excl) ELSE u.tok END AS incl_tok,
        CASE WHEN u.pos_excl > 0 THEN SUBSTRING(u.tok FROM u.pos_excl)       ELSE ''''    END AS excl_tok
    FROM u2 u
),
u4 AS (
    SELECT
        u.rid, u.tipo, u.song_id, u.contract_id, u.contract_nm_mv, u.ctrl, u.publisher_name_tx, u.grupo_ip,
        u.perf, u.mech, u.sync, u.inclusions, u.exclusions, u.tiene_respaldo,
        u.contract_nm_v, u.orig_office_nm, u.contract_expiration_dt, u.incl_tok, u.excl_tok,
        p.pais,
        CASE WHEN TRIM(u.incl_tok) = '''' OR u.incl_tok LIKE '' ALL %'' OR u.incl_tok LIKE ''% WORLD %''
                  OR u.incl_tok LIKE ''% WORLDWIDE %'' OR u.incl_tok LIKE ''% UNIVERSE %'' OR u.incl_tok LIKE ''% MUNDO %''
             THEN 1 ELSE 0 END AS es_generico,
        MAX(CASE WHEN u.incl_tok LIKE ''% '' || a.alias || '' %'' THEN 1 ELSE 0 END)                          AS g_pais,
        MAX(CASE WHEN r.region IS NOT NULL AND u.incl_tok LIKE ''% '' || r.region || '' %'' THEN 1 ELSE 0 END) AS g_region,
        MAX(CASE WHEN u.excl_tok <> '''' AND (u.excl_tok LIKE ''% '' || a.alias || '' %''
                      OR (r.region IS NOT NULL AND u.excl_tok LIKE ''% '' || r.region || '' %'')) THEN 1 ELSE 0 END) AS g_excluido,
        MAX(CASE WHEN u.incl LIKE ''%;WORLD;%'' THEN 1 ELSE 0 END)                                            AS inc_mundo,
        MAX(CASE WHEN u.incl LIKE ''%;'' || a.alias || '';%'' THEN 1 ELSE 0 END)                                AS inc_pais,
        MAX(CASE WHEN r.region IS NOT NULL AND u.incl LIKE ''%;'' || r.region || '';%'' THEN 1 ELSE 0 END)      AS inc_region,
        MAX(CASE WHEN u.excl LIKE ''%;'' || a.alias || '';%'' THEN 1 ELSE 0 END)                                AS exc_pais,
        MAX(CASE WHEN r.region IS NOT NULL AND u.excl LIKE ''%;'' || r.region || '';%'' THEN 1 ELSE 0 END)      AS exc_region
    FROM u3 u
    CROSS JOIN paises p
    JOIN alias_pais a     ON a.pais = p.pais
    LEFT JOIN regiones r  ON r.pais = p.pais
    GROUP BY
        u.rid, u.tipo, u.song_id, u.contract_id, u.contract_nm_mv, u.ctrl, u.publisher_name_tx, u.grupo_ip,
        u.perf, u.mech, u.sync, u.inclusions, u.exclusions, u.tiene_respaldo,
        u.contract_nm_v, u.orig_office_nm, u.contract_expiration_dt, u.incl_tok, u.excl_tok, p.pais
),
u5 AS (
    SELECT
        u.*,
        CASE
            WHEN u.tipo <> ''M'' OR u.g_excluido = 1          THEN NULL
            WHEN u.es_generico = 0 AND u.g_pais = 1          THEN 1
            WHEN u.es_generico = 0 AND u.g_region = 1        THEN 2
            WHEN u.es_generico = 1                           THEN 3
        END AS spec,
        CASE WHEN u.tipo = ''L'' THEN ''OBRA'' WHEN u.tiene_respaldo = 1 THEN ''CONTRATO'' ELSE ''SIN TEXTO'' END AS fuente_fila,
        CASE
            WHEN u.tipo = ''M'' AND u.tiene_respaldo = 0       THEN 0
            WHEN u.exc_pais = 1 OR u.exc_region = 1           THEN 0
            WHEN u.inc_mundo = 1 OR u.inc_pais = 1 OR u.inc_region = 1 THEN 1
            ELSE 0
        END AS cubre_fila,
        CASE
            WHEN u.tipo = ''M'' AND u.tiene_respaldo = 0       THEN ''Contrato sin texto de territorio: VERIFICAR''
            WHEN u.exc_pais = 1                               THEN ''Contrato: país excluido''
            WHEN u.exc_region = 1                             THEN ''Contrato: región excluida''
            WHEN u.inc_pais = 1                               THEN ''Contrato: país incluido''
            WHEN u.inc_region = 1                             THEN ''Contrato: región incluida''
            WHEN u.inc_mundo = 1                              THEN ''Contrato: World''
            ELSE ''Contrato: país no incluido''
        END
        || CASE WHEN u.tipo = ''M'' AND u.tiene_respaldo = 1 THEN '' (texto tomado de otra obra del contrato)'' ELSE '''' END
        AS regla_fila
    FROM u4 u
),
u6 AS (
    SELECT
        u.*,
        MIN(u.spec) OVER (PARTITION BY u.song_id, u.pais) AS best_spec,
        MAX(CASE WHEN u.tipo = ''L'' THEN 1 ELSE 0 END) OVER (PARTITION BY u.song_id, u.pais, u.contract_id) AS tiene_linea,
        MAX(CASE WHEN u.tipo = ''L'' THEN u.cubre_fila END) OVER (PARTITION BY u.song_id, u.pais, u.contract_id) AS linea_cubre,
        MAX(CASE WHEN u.tipo = ''L'' THEN u.regla_fila END) OVER (PARTITION BY u.song_id, u.pais, u.contract_id) AS linea_regla,
        MAX(CASE WHEN u.tipo = ''L'' AND u.cubre_fila = 1 THEN 1 ELSE 0 END) OVER (PARTITION BY u.song_id, u.pais) AS alguna_linea_cubre
    FROM u5 u
),
u7 AS (
    SELECT
        u.*,
        MIN(CASE WHEN u.spec = u.best_spec THEN u.grupo_ip END) OVER (PARTITION BY u.song_id, u.pais) AS grupo_elegido,
        DENSE_RANK() OVER (PARTITION BY u.song_id, u.pais, CASE WHEN u.spec = u.best_spec THEN 1 ELSE 0 END
                           ORDER BY u.grupo_ip) AS dr_grupo,
        CASE WHEN u.contract_id IS NULL THEN NULL WHEN u.tiene_linea = 1 THEN u.linea_cubre ELSE u.cubre_fila END AS cob_cubre,
        CASE WHEN u.contract_id IS NULL THEN NULL WHEN u.tiene_linea = 1 THEN u.linea_regla ELSE u.regla_fila END AS cob_regla,
        CASE WHEN u.contract_id IS NULL THEN NULL WHEN u.tiene_linea = 1 THEN ''OBRA''        ELSE u.fuente_fila END AS cob_fuente
    FROM u6 u
),
u8 AS (
    SELECT
        u.*,
        MAX(CASE WHEN u.spec = u.best_spec THEN u.dr_grupo END) OVER (PARTITION BY u.song_id, u.pais) AS n_empate,
        CASE WHEN u.tipo = ''M'' AND u.ctrl = ''Y'' AND u.grupo_ip = u.grupo_elegido THEN 1 ELSE 0 END AS es_det,
        CASE
            WHEN u.contract_id IS NULL      THEN 1
            WHEN u.cob_cubre = 1            THEN 1
            WHEN u.alguna_linea_cubre = 1   THEN 1
            ELSE 0
        END AS cubre_det,
        CASE WHEN u.contract_id IS NULL THEN 1 ELSE COALESCE(u.cob_cubre, 0) END AS cubre_asoc,
        CASE
            WHEN u.contract_id IS NULL        THEN ''Participación sin contrato asociado''
            WHEN u.cob_cubre = 1              THEN u.cob_regla
            WHEN u.alguna_linea_cubre = 1
                THEN ''Otra línea de control de la obra cubre el país (contrato asociado: '' || COALESCE(u.cob_regla, ''sin texto'') || '')''
            ELSE u.cob_regla
        END AS regla_det,
        CASE WHEN u.tipo = ''L'' THEN 1
             WHEN u.tipo = ''M'' AND u.ctrl = ''Y'' AND u.contract_id IS NOT NULL AND u.tiene_linea = 0 THEN 1
             ELSE 0 END AS es_alcance,
        CAST(COALESCE(CAST(u.contract_id AS VARCHAR(30)), ''SIN CONTRATO'') || '' - ''
             || CAST(COALESCE(u.contract_nm_mv, ''Sin nombre'') AS VARCHAR(200)) AS VARCHAR(250)) AS etiqueta_pais,
        CAST(
            COALESCE(CAST(u.contract_id AS VARCHAR(30)), ''SIN CONTRATO'') || '' - ''
            || CAST(COALESCE(u.contract_nm_mv, ''Sin nombre'') AS VARCHAR(200))
            || '' [ctrl:'' || CAST(COALESCE(u.ctrl, ''?'') AS VARCHAR(5)) || ''] ''
            || CAST(CASE
                        WHEN u.contract_expiration_dt IS NULL THEN ''sin venc.''
                        WHEN u.contract_expiration_dt < CURRENT_DATE THEN ''VENCIDO '' || CAST(u.contract_expiration_dt AS VARCHAR(10))
                        ELSE ''vig. '' || CAST(u.contract_expiration_dt AS VARCHAR(10))
                    END AS VARCHAR(40))
        AS VARCHAR(300)) AS etiqueta_obra
    FROM u7 u
),
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
        LPAD(CAST(u.contract_id AS VARCHAR(20)), 20, ''0'') AS orden_contrato
    FROM u9 u
),
listas AS (
              SELECT ''base'' AS lst
    UNION ALL SELECT ''pub''
    UNION ALL SELECT ''cpais''
    UNION ALL SELECT ''regla''
    UNION ALL SELECT ''cobra''
    UNION ALL SELECT ''ofi''
    UNION ALL SELECT ''grupo''
    UNION ALL SELECT ''lobra''
    UNION ALL SELECT ''lcubre''
    UNION ALL SELECT ''audit''
),
u11 AS (
    SELECT
        u.*,
        x.lst,
        CASE x.lst
            WHEN ''pub''    THEN CASE WHEN u.es_ctrl = 1 AND u.rn_pub = 1 THEN u.publisher_name_tx END
            WHEN ''cpais''  THEN CASE WHEN u.es_ctrl = 1 AND u.rn_cpais = 1 THEN u.etiqueta_pais END
            WHEN ''regla''  THEN CASE WHEN u.es_det = 1 AND u.rn_regla = 1 THEN u.regla_det END
            WHEN ''cobra''  THEN CASE WHEN u.tipo = ''M'' AND u.rn_cobra = 1 THEN u.etiqueta_obra END
            WHEN ''ofi''    THEN CASE WHEN u.tipo = ''M'' AND u.rn_ofi = 1 THEN u.orig_office_nm END
            WHEN ''grupo''  THEN CASE WHEN u.tipo = ''M'' AND u.rn_grupo = 1 THEN CASE WHEN u.grupo_ip = '''' THEN ''(sin nombre)'' ELSE u.grupo_ip END END
            WHEN ''lobra''  THEN CASE WHEN u.tipo = ''L''
                                    THEN CAST(u.contract_id AS VARCHAR(20)) || '' - '' || CAST(COALESCE(u.contract_nm_v, ''Sin nombre'') AS VARCHAR(150)) END
            WHEN ''lcubre'' THEN CASE WHEN u.alc_cubre = 1
                                    THEN CAST(u.contract_id AS VARCHAR(20)) || '' - '' || CAST(COALESCE(u.contract_nm_v, ''Sin nombre'') AS VARCHAR(150))
                                         || '' [''
                                         || CASE
                                                WHEN u.contract_expiration_dt IS NULL THEN ''sin venc.''
                                                WHEN u.contract_expiration_dt < CURRENT_DATE THEN ''VENCIDO '' || CAST(u.contract_expiration_dt AS VARCHAR(10))
                                                ELSE ''vig. '' || CAST(u.contract_expiration_dt AS VARCHAR(10))
                                            END
                                         || '']'' END
            WHEN ''audit''  THEN CASE WHEN u.alc = 1
                                    THEN CAST(u.contract_id AS VARCHAR(20)) || '' ['' || u.fuente_fila || ''] cubre='' || CAST(u.cubre_fila AS VARCHAR(1))
                                         || '' | '' || u.regla_fila
                                         || '' | INC: '' || SUBSTRING(COALESCE(u.inclusions, ''(vacio)''), 1, 100)
                                         || '' | EXC: '' || SUBSTRING(COALESCE(u.exclusions, ''(vacio)''), 1, 100) END
        END AS item,
        CASE x.lst
            WHEN ''pub''    THEN u.publisher_name_tx
            WHEN ''cpais''  THEN u.etiqueta_pais
            WHEN ''regla''  THEN u.regla_det
            WHEN ''cobra''  THEN u.etiqueta_obra
            WHEN ''ofi''    THEN u.orig_office_nm
            WHEN ''grupo''  THEN u.grupo_ip
            ELSE u.orden_contrato
        END AS orden
    FROM u10 u
    CROSS JOIN listas x
),

res AS (
    SELECT
        song_id,
        pais,
        SUM(CASE WHEN lst = ''base'' AND tipo = ''M'' THEN 1 ELSE 0 END)                       AS n_mv,
        MAX(CASE WHEN lst = ''base'' THEN best_spec END)                                     AS especificidad,
        MAX(CASE WHEN lst = ''base'' THEN grupo_elegido END)                                 AS grupo_ip,
        MAX(CASE WHEN lst = ''base'' THEN n_empate END)                                      AS n_empate,
        SUM(CASE WHEN lst = ''base'' AND es_ctrl = 1 THEN 1 ELSE 0 END)                      AS n_det,
        SUM(CASE WHEN lst = ''base'' AND es_ctrl = 1 THEN perf END)                          AS perf,
        SUM(CASE WHEN lst = ''base'' AND es_ctrl = 1 THEN mech END)                          AS mech,
        SUM(CASE WHEN lst = ''base'' AND es_ctrl = 1 THEN sync END)                          AS sync,
        MAX(CASE WHEN lst = ''base'' AND es_ctrl = 1 AND contract_id IS NULL THEN 1 ELSE 0 END) AS hay_sin_contrato,
        MAX(CASE WHEN lst = ''base'' AND es_det = 1 AND cob_fuente = ''SIN TEXTO'' AND cubre_det = 0 THEN 1 ELSE 0 END) AS hay_sin_texto,
        MAX(CASE WHEN lst = ''base'' AND es_det = 1 AND cob_fuente = ''CONTRATO'' AND cubre_asoc = 1 THEN 1 ELSE 0 END) AS hay_texto_prestado,
        MAX(CASE WHEN lst = ''base'' AND es_det = 1 AND cubre_det = 1 AND cubre_asoc = 0 THEN 1 ELSE 0 END)      AS hay_otra_linea,
        SUM(CASE WHEN lst = ''pub''   AND item IS NOT NULL THEN 1 ELSE 0 END)                AS cantidad_publishers,
        SUM(CASE WHEN lst = ''cpais'' AND item IS NOT NULL THEN 1 ELSE 0 END)                AS cantidad_contratos_pais,
        SUM(CASE WHEN lst = ''cobra'' AND item IS NOT NULL THEN 1 ELSE 0 END)                AS cantidad_contratos_obra,
        SUM(CASE WHEN lst = ''base'' AND alc_cubre = 1 THEN 1 ELSE 0 END)                    AS n_lineas,
        SUM(CASE WHEN lst = ''base'' AND alc_cubre = 1 AND contract_expiration_dt < CURRENT_DATE THEN 1 ELSE 0 END)  AS n_vencidos,
        SUM(CASE WHEN lst = ''base'' AND alc_cubre = 1 AND contract_expiration_dt >= CURRENT_DATE THEN 1 ELSE 0 END) AS n_vigentes,
        MIN(CASE WHEN lst = ''base'' AND alc_cubre = 1 THEN contract_expiration_dt END)      AS venc_proximo,
        MAX(CASE WHEN lst = ''base'' AND alc_cubre = 1 THEN contract_expiration_dt END)      AS venc_lejano,
        NULLIF(LISTAGG(CASE WHEN lst = ''pub''    THEN item END, '' | '')  WITHIN GROUP (ORDER BY orden), '''') AS publishers,
        NULLIF(LISTAGG(CASE WHEN lst = ''cpais''  THEN item END, '' | '')  WITHIN GROUP (ORDER BY orden), '''') AS contratos_del_pais,
        NULLIF(LISTAGG(CASE WHEN lst = ''regla''  THEN item END, '' | '')  WITHIN GROUP (ORDER BY orden), '''') AS regla_territorial,
        NULLIF(LISTAGG(CASE WHEN lst = ''cobra''  THEN item END, '' | '')  WITHIN GROUP (ORDER BY orden), '''') AS todos_los_contratos,
        NULLIF(LISTAGG(CASE WHEN lst = ''ofi''    THEN item END, '' | '')  WITHIN GROUP (ORDER BY orden), '''') AS originating_office,
        NULLIF(LISTAGG(CASE WHEN lst = ''grupo''  THEN item END, '' | '')  WITHIN GROUP (ORDER BY orden), '''') AS grupos_ip_de_la_obra,
        NULLIF(LISTAGG(CASE WHEN lst = ''lobra''  THEN item END, '' | '')  WITHIN GROUP (ORDER BY orden), '''') AS lineas_de_control_obra,
        NULLIF(LISTAGG(CASE WHEN lst = ''lcubre'' THEN item END, '' | '')  WITHIN GROUP (ORDER BY orden), '''') AS lineas_que_cubren_el_pais,
        NULLIF(LISTAGG(CASE WHEN lst = ''audit''  THEN item END, '' || '') WITHIN GROUP (ORDER BY orden), '''') AS texto_territorio_contratos
    FROM u11
    GROUP BY song_id, pais
)

SELECT
    i.song_id,
    COALESCE(si.song_title_tx, ''Sin título'')          AS song_title_tx,
    iw.iswc                                           AS iswc,
    p.pais,

    CASE
        WHEN si.song_not_ours_dt IS NOT NULL AND si.song_not_ours_dt <= CURRENT_DATE THEN ''NOP''
        WHEN COALESCE(r.n_mv, 0) = 0 THEN ''SIN DATOS''
        WHEN COALESCE(r.perf, 0) = 0 THEN ''NVFT''
        ELSE CAST(CAST(r.perf AS NUMERIC(10,2)) AS VARCHAR(20))
    END AS performance_pc_total,
    CASE
        WHEN si.song_not_ours_dt IS NOT NULL AND si.song_not_ours_dt <= CURRENT_DATE THEN ''NOP''
        WHEN COALESCE(r.n_mv, 0) = 0 THEN ''SIN DATOS''
        WHEN COALESCE(r.mech, 0) = 0 THEN ''NVFT''
        ELSE CAST(CAST(r.mech AS NUMERIC(10,2)) AS VARCHAR(20))
    END AS mechanical_pc_total,
    CASE
        WHEN si.song_not_ours_dt IS NOT NULL AND si.song_not_ours_dt <= CURRENT_DATE THEN ''NOP''
        WHEN COALESCE(r.n_mv, 0) = 0 THEN ''SIN DATOS''
        WHEN COALESCE(r.sync, 0) = 0 THEN ''NVFT''
        ELSE CAST(CAST(r.sync AS NUMERIC(10,2)) AS VARCHAR(20))
    END AS sync_pc_total,

    COALESCE(r.publishers, ''N/A'')                     AS publishers,
    COALESCE(r.cantidad_publishers, 0)                AS cantidad_publishers,
    COALESCE(r.contratos_del_pais, ''N/A'')             AS contratos_del_pais,
    COALESCE(r.cantidad_contratos_pais, 0)            AS cantidad_contratos_del_pais,
    r.todos_los_contratos,
    CASE WHEN COALESCE(r.n_mv, 0) = 0 THEN NULL ELSE r.cantidad_contratos_obra END AS cantidad_contratos_obra,
    r.originating_office,
    si.tempo_create_date                              AS song_tempo_create_date,
    si.song_not_ours_dt,
    CASE
        WHEN si.song_not_ours_dt IS NOT NULL AND si.song_not_ours_dt <= CURRENT_DATE THEN ''VENCIDA (NOP)''
        ELSE ''ACTIVA''
    END                                               AS estado_obra,
    CASE WHEN COALESCE(r.n_lineas, 0) > 0 THEN r.venc_proximo END AS contrato_venc_mas_proximo,
    CASE WHEN COALESCE(r.n_lineas, 0) > 0 THEN r.venc_lejano  END AS contrato_venc_mas_lejano,
    CASE
        WHEN COALESCE(r.n_det, 0) = 0            THEN ''SIN CONTROL''
        WHEN COALESCE(r.n_lineas, 0) = 0         THEN ''SIN LINEA DE CONTROL''
        WHEN r.n_vencidos = r.n_lineas           THEN ''TODOS VENCIDOS''
        WHEN r.n_vencidos > 0                    THEN ''MIXTO (alguno vencido)''
        WHEN r.n_vigentes = 0                    THEN ''SIN VENCIMIENTO''
        ELSE ''VIGENTE''
    END                                               AS estado_contrato,

    CASE WHEN r.especificidad IS NULL THEN NULL WHEN r.grupo_ip = '''' THEN ''(sin nombre)'' ELSE r.grupo_ip END AS grupo_ip_usado,
    CASE r.especificidad
        WHEN 1 THEN ''Grupo nombra al país''
        WHEN 2 THEN ''Grupo nombra una región que lo incluye''
        WHEN 3 THEN ''Grupo mundial''
        ELSE ''Ningún grupo de la obra cubre el país''
    END                                               AS como_se_eligio_grupo,
    COALESCE(r.regla_territorial, ''—'')                AS regla_territorial,
    r.grupos_ip_de_la_obra,
    r.lineas_de_control_obra,
    r.lineas_que_cubren_el_pais,
    r.texto_territorio_contratos,
    NULLIF(
        CASE WHEN r.especificidad IS NOT NULL AND r.n_empate > 1 THEN ''VARIOS GRUPOS CON LA MISMA PRIORIDAD; '' ELSE '''' END
        || CASE WHEN r.hay_sin_contrato = 1 THEN ''PARTICIPACION SIN CONTRATO; '' ELSE '''' END
        || CASE WHEN COALESCE(r.n_mv, 0) = 0 THEN ''OBRA AUSENTE EN song_share_detail_mv (revisar writers sin sociedad, secuencia o grupo de pais); '' ELSE '''' END
        || CASE WHEN r.hay_sin_texto = 1 THEN ''CONTRATO SIN TEXTO DE TERRITORIO: sin rate client/payment option activo (VERIFICAR); '' ELSE '''' END
        || CASE WHEN COALESCE(r.perf, 0) > 100 OR COALESCE(r.mech, 0) > 100 OR COALESCE(r.sync, 0) > 100
                THEN ''TOTAL SUPERA 100 (posible doble conteo en la cadena de publishers); '' ELSE '''' END
        || CASE WHEN r.hay_texto_prestado = 1 THEN ''TERRITORIO TOMADO DE OTRA OBRA DEL CONTRATO; '' ELSE '''' END
        || CASE WHEN r.hay_otra_linea = 1 THEN ''CONTROL SOSTENIDO POR OTRA LINEA DE CONTROL (el contrato asociado a la participacion no cubre el pais); '' ELSE '''' END
    , '''')                                             AS alertas

FROM ids i
CROSS JOIN paises p
LEFT JOIN res r        ON r.song_id = i.song_id AND r.pais = p.pais
LEFT JOIN song_info si ON si.song_id = i.song_id
LEFT JOIN iswc iw      ON iw.song_id = i.song_id';
        GET DIAGNOSTICS v_filas := ROW_COUNT;
        INSERT INTO public.reporte_cwr_pais_log VALUES (p_pais, v_tanda, v_desde, v_hasta, v_filas, v_inicio, TIMEOFDAY());
        COMMIT;
        RAISE INFO '% - tanda %: Tempo ID % a %: % filas', p_pais, v_tanda, v_desde, v_hasta, v_filas;
        v_desde := v_hasta + 1;
    END LOOP;
    RAISE INFO '% listo. Máximo Tempo ID recorrido: %', p_pais, v_max;
END;
$$ LANGUAGE plpgsql;
