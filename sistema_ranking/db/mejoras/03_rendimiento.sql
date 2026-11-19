-- =====================================================================
-- Mejora propia (no viene de Supabase): rendimiento con volumen real (cientos de miles de filas de charts).
--
-- El front heredado de Supabase traía las tablas completas de a 1.000 filas (cada tanda recalculaba la consulta) y
-- filtraba en el navegador: con los históricos cargados tardaba minutos. Estas funciones buscan, filtran, ordenan y
-- paginan en la base, y devuelven solo la página que se muestra, con el total.
-- Las funciones originales (fn_master_view, fn_territory_view...) quedan iguales.
-- Idempotente: se aplica en cada arranque (db/mejoras.sh).
-- =====================================================================
SET search_path = public;

-- Último chart de cada obra (por territorio) y última semana por plataforma y territorio.
CREATE INDEX IF NOT EXISTS ix_territory_obra_pais_fecha ON public.territory_tracks (track_master_id, pais_code, snapshot_date DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_territory_plataforma_pais_fecha ON public.territory_tracks (platform, pais_code, snapshot_date DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_bo_report_obra_pais ON public.territory_bo_report (track_master_id, pais_code);
CREATE INDEX IF NOT EXISTS ix_tempo_report_obra_pais ON public.territory_tempo_report (track_master_id, pais_code);

-- Texto de búsqueda como patrón LIKE literal (sin comodines del usuario).
CREATE OR REPLACE FUNCTION public.fn_patron_busqueda(p_texto text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select case when coalesce(trim(p_texto), '') = '' then null
           else '%' || replace(replace(replace(lower(trim(p_texto)), '\', '\\'), '%', '\%'), '_', '\_') || '%' end;
$function$;

-- Búsqueda de las tablas: por título, artista o Tempo ID; "-" busca las obras sin Tempo ID.
CREATE OR REPLACE FUNCTION public.fn_coincide_busqueda(p_buscar text, p_tempo_id text, p_texto text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select case when fn_patron_busqueda(p_buscar) is null then true
                when trim(p_buscar) = '-' then coalesce(trim(p_tempo_id), '') = ''
                else lower(coalesce(p_texto, '') || ' ' || coalesce(p_tempo_id, '')) like fn_patron_busqueda(p_buscar) end;
$function$;

-- Filtro Tempo ID de la tabla principal (pedido del usuario, 11/11/2026: filtrar vacíos junto con la búsqueda por artista):
-- 'vacios' = sin Tempo ID, 'con' = con Tempo ID (número o marcador), NULL = todas.
CREATE OR REPLACE FUNCTION public.fn_coincide_tempo(p_tempo text, p_tempo_id text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select case p_tempo when 'vacios' then coalesce(trim(p_tempo_id), '') = ''
                        when 'con' then coalesce(trim(p_tempo_id), '') <> ''
                        else true end;
$function$;

-- Tabla principal: una página (p_limite filas desde p_offset), con los mismos filtros que fn_master_view, la búsqueda
-- por título, artista o Tempo ID, el filtro Tempo ID, el seguimiento de envíos de cada obra y el total de filas.
DROP FUNCTION IF EXISTS public.fn_master_pagina(date, date, pais_code_enum, boolean, text, integer, integer);
CREATE OR REPLACE FUNCTION public.fn_master_pagina(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date,
    p_pais pais_code_enum DEFAULT NULL::pais_code_enum, p_include_deleted boolean DEFAULT false, p_buscar text DEFAULT NULL::text,
    p_limite integer DEFAULT 100, p_offset integer DEFAULT 0, p_tempo text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, track_artist_concat text, track_name_clean text, tempo_id text, last_chart_date date,
               deleted_at timestamp with time zone, ult_bo_at timestamp with time zone, ult_bo_carga integer,
               ult_csv_at timestamp with time zone, total bigint)
 LANGUAGE sql
 STABLE
AS $function$
    with filtrado as (
        select tt.track_master_id, max(tt.snapshot_date) as ultima
        from territory_tracks tt
        where tt.deleted_at is null
          and (p_pais      is null or tt.pais_code = p_pais)
          and (p_date_from is null or tt.snapshot_date >= p_date_from)
          and (p_date_to   is null or tt.snapshot_date <= p_date_to)
        group by tt.track_master_id
    ), base as (
        select tm.id, tm.track_artist_concat, tm.track_name_clean, tm.tempo_id, f.ultima, tm.deleted_at
        from tracks_master tm
        left join filtrado f on f.track_master_id = tm.id
        where (p_include_deleted or tm.deleted_at is null)
          and ((p_pais is null and p_date_from is null and p_date_to is null) or f.track_master_id is not null)
          and (p_buscar is null or fn_coincide_busqueda(p_buscar, fn_tempo_texto(tm.id, tm.tempo_id), tm.track_artist_concat))
          and fn_coincide_tempo(p_tempo, tm.tempo_id)
    ), pagina as (
        select b.*, count(*) over () as total
        from base b
        order by lower(b.track_artist_concat), b.track_artist_concat, b.id   -- siempre alfabético (pedido del usuario, 06/11/2026)
        limit greatest(p_limite, 0) offset greatest(p_offset, 0)
    )
    select p.id, p.track_artist_concat, p.track_name_clean, fn_tempo_texto(p.id, p.tempo_id), p.ultima, p.deleted_at,
           e.ult_bo_at, e.ult_bo_carga, e.ult_csv_at, p.total
    from pagina p
    left join lateral (
        select max(en.created_at) filter (where en.tipo = 'reporte_bo') as ult_bo_at,
               (array_agg(en.carga order by en.created_at desc) filter (where en.tipo = 'reporte_bo'))[1] as ult_bo_carga,
               max(en.created_at) filter (where en.tipo = 'csv_principal') as ult_csv_at
        from envio_obras eo join envios en on en.id = eo.envio_id
        where eo.track_master_id = p.id
    ) e on true
    order by lower(p.track_artist_concat), p.track_artist_concat, p.id;
$function$;

-- Tabla principal: cuántas obras tienen Tempo ID (número o marcador, como UNCONTROLLED) y cuántas no, con los mismos
-- filtros y búsqueda que fn_master_pagina (las dos cantidades suman su total).
DROP FUNCTION IF EXISTS public.fn_master_conteo(date, date, pais_code_enum, boolean, text);
CREATE OR REPLACE FUNCTION public.fn_master_conteo(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date,
    p_pais pais_code_enum DEFAULT NULL::pais_code_enum, p_include_deleted boolean DEFAULT false, p_buscar text DEFAULT NULL::text,
    p_tempo text DEFAULT NULL::text)
 RETURNS TABLE(identificadas bigint, sin_identificar bigint)
 LANGUAGE sql
 STABLE
AS $function$
    with filtrado as (
        select distinct tt.track_master_id
        from territory_tracks tt
        where tt.deleted_at is null
          and (p_pais      is null or tt.pais_code = p_pais)
          and (p_date_from is null or tt.snapshot_date >= p_date_from)
          and (p_date_to   is null or tt.snapshot_date <= p_date_to)
    )
    select count(*) filter (where nullif(trim(tm.tempo_id), '') is not null),
           count(*) filter (where nullif(trim(tm.tempo_id), '') is null)
    from tracks_master tm
    where (p_include_deleted or tm.deleted_at is null)
      and ((p_pais is null and p_date_from is null and p_date_to is null)
           or tm.id in (select f.track_master_id from filtrado f))
      and (p_buscar is null or fn_coincide_busqueda(p_buscar, fn_tempo_texto(tm.id, tm.tempo_id), tm.track_artist_concat))
      and fn_coincide_tempo(p_tempo, tm.tempo_id);
$function$;

-- Ticket y fecha por obra y territorio (los escribe la persona en la tabla por territorio, con fn_guardar_seguimiento):
-- el número de ticket enviado cuando la obra está mal en Tempo o en BO, y la fecha correspondiente.
CREATE TABLE IF NOT EXISTS public.territory_seguimiento (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    track_master_id uuid NOT NULL REFERENCES public.tracks_master(id) ON DELETE CASCADE,
    pais_code pais_code_enum NOT NULL,
    ticket text,
    ticket_fecha date,
    deleted_at timestamp with time zone,   -- no se usa; lo pide fn_audit_trigger
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_by text NOT NULL DEFAULT COALESCE((auth.uid())::text, (CURRENT_USER)::text),
    UNIQUE (track_master_id, pais_code)
);
ALTER TABLE public.territory_seguimiento ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS territory_seguimiento_select ON public.territory_seguimiento;
CREATE POLICY territory_seguimiento_select ON public.territory_seguimiento AS PERMISSIVE FOR SELECT TO authenticated USING (true);
GRANT SELECT ON public.territory_seguimiento TO authenticated;
GRANT ALL ON public.territory_seguimiento TO service_role;
DROP TRIGGER IF EXISTS trg_audit_territory_seguimiento ON public.territory_seguimiento;
CREATE TRIGGER trg_audit_territory_seguimiento AFTER INSERT OR DELETE OR UPDATE ON public.territory_seguimiento
    FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();
-- Obras con Tempo ID duplicado (00/17): cada Tempo ID lleva su propio ticket. tempo_id NULL = el Tempo ID principal.
ALTER TABLE public.territory_seguimiento ADD COLUMN IF NOT EXISTS tempo_id text;
ALTER TABLE public.territory_seguimiento DROP CONSTRAINT IF EXISTS territory_seguimiento_track_master_id_pais_code_key;
CREATE UNIQUE INDEX IF NOT EXISTS uq_territory_seguimiento_obra_pais_tempo
    ON public.territory_seguimiento (track_master_id, pais_code, (coalesce(tempo_id, '')));

-- Tabla por territorio: una página. Cada obra que figuró en algún chart (en el período Desde/Hasta, si se indica)
-- aparece en todos los países, para controlar Tempo y BackOffice en cada uno aunque solo se escuche en uno (pedido del
-- usuario, 15/11/2026). chart dice si figuró en el chart de ese país ('En chart' / 'No en chart', en el período) y
-- en_chart_de, en qué países figuró ("MX, CL"): en las filas 'No en chart' se muestra al lado del país (16/11/2026).
-- Las obras UNCONTROLLED no aparecen: vuelven cuando reciben un Tempo ID numérico.
-- Obra con Tempo ID duplicado (tempo_duplicado): una fila por país y por cada Tempo ID, con sus datos de BO y Tempo y
-- su ticket; duplicada = true y el estado de trabajo empieza con DUPLICADA (16/11/2026).
-- Filtros: los de estado (de BO), reclamos y estado de trabajo ('—' = sin valor), p_chart y la búsqueda por Tempo ID o
-- título. Ordenada alfabéticamente por título (y país). Los parámetros nuevos van al final (fn_territory_exportar y
-- fn_ticket_filtrado la llaman por posición).
DROP FUNCTION IF EXISTS public.fn_territory_pagina(date, date, pais_code_enum, boolean, text, text, text, integer, integer);
DROP FUNCTION IF EXISTS public.fn_territory_pagina(date, date, pais_code_enum, boolean, text, text, text, integer, integer, text);
DO $$ BEGIN   -- versiones del 15 y 16/11/2026, sin en_chart_de o sin duplicada (cambia lo que devuelve)
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_territory_pagina' AND pronamespace = 'public'::regnamespace
               AND NOT coalesce(proargnames, '{}') @> ARRAY['en_chart_de', 'duplicada']) THEN
        DROP FUNCTION public.fn_territory_pagina(date, date, pais_code_enum, boolean, text, text, text, integer, integer, text, text);
    END IF;
END $$;
CREATE OR REPLACE FUNCTION public.fn_territory_pagina(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date,
    p_pais pais_code_enum DEFAULT NULL::pais_code_enum, p_include_deleted boolean DEFAULT false, p_buscar text DEFAULT NULL::text,
    p_reclamos text DEFAULT NULL::text, p_estado_trabajo text DEFAULT NULL::text,
    p_limite integer DEFAULT 100, p_offset integer DEFAULT 0, p_estado text DEFAULT NULL::text, p_chart text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, track_master_id uuid, pais_code pais_code_enum, tempo_id text, track_artist_concat text, snapshot_date date,
               created_date date, bo_report_id uuid, bo text, ca text, perf_raw text, mech_raw text, estado text, reclamos text,
               mech_bo numeric, estado_trabajo text, estado_obra text, deleted_at timestamp with time zone,
               ticket text, ticket_fecha date, chart text, en_chart_de text, duplicada boolean, total bigint)
 LANGUAGE sql
 STABLE
AS $function$
    with charts as (
        select tt.id, tt.track_master_id, tt.pais_code, tt.platform, tt.snapshot_date
        from territory_tracks tt
        where tt.deleted_at is null
          and (p_date_from is null or tt.snapshot_date >= p_date_from)
          and (p_date_to   is null or tt.snapshot_date <= p_date_to)
    ), por_pais as (
        select c.track_master_id, c.pais_code, max(c.snapshot_date) as ultima,
               (array_agg(c.id order by c.snapshot_date desc))[1] as id
        from charts c
        group by 1, 2
    ), paises as (
        select pp.track_master_id, string_agg(pp.pais_code::text, ', ' order by pp.pais_code) as en_chart_de
        from por_pais pp group by 1
    ), obras as (
        select tm.id, tm.tempo_id, tm.track_artist_concat, tm.deleted_at, ps.en_chart_de
        from tracks_master tm
        join paises ps on ps.track_master_id = tm.id
        where (p_include_deleted or tm.deleted_at is null)
          and tm.tempo_id is distinct from 'UNCONTROLLED'   -- sin control no hay nada que revisar (pedido del usuario, 16/11/2026)
          and (p_buscar is null or fn_coincide_busqueda(p_buscar, fn_tempo_texto(tm.id, tm.tempo_id), tm.track_artist_concat))
    ), con_tempos as (   -- una fila por cada Tempo ID de la obra: el principal (orden 0) y los duplicados
        select o.*, t.tempo, t.orden, exists (select 1 from tempo_duplicado d where d.track_master_id = o.id) as duplicada
        from obras o
        cross join lateral (select o.tempo_id as tempo, 0 as orden
                            union all
                            select d.tempo_id, d.orden from tempo_duplicado d where d.track_master_id = o.id) t
    ), base as (
        select pp.id, o.id as track_master_id, p.pais as pais_code, o.tempo as tempo_id, o.track_artist_concat,
               pp.ultima as snapshot_date, tr.created_date,
               br.id as bo_report_id, br.bo_id as bo, br.ca,
               coalesce(tr.perf_raw, tr.perf_pc::text) as perf_raw, coalesce(tr.mech_raw, tr.mech_pc::text) as mech_raw,
               br.bo_status as estado, br.reclamos, br.mech_bo,
               case when o.duplicada then 'DUPLICADA' || coalesce(' / ' || br.estado_trabajo, '') else br.estado_trabajo end
                   as estado_trabajo,
               tr.estado_obra, o.deleted_at,
               sg.ticket, sg.ticket_fecha,
               case when pp.track_master_id is not null then 'En chart' else 'No en chart' end as chart,
               o.en_chart_de, o.duplicada, o.orden
        from con_tempos o
        cross join unnest(enum_range(null::pais_code_enum)) as p(pais)
        left join por_pais pp on pp.track_master_id = o.id and pp.pais_code = p.pais
        left join territory_seguimiento sg on sg.track_master_id = o.id and sg.pais_code = p.pais
               and sg.tempo_id is not distinct from (case when o.orden = 0 then null else o.tempo end)
        left join territory_bo_report br on br.track_master_id = o.id and br.pais_code = p.pais
               and br.deleted_at is null and br.tempo_id = o.tempo
        left join territory_tempo_report tr on tr.track_master_id = o.id and tr.pais_code = p.pais
               and tr.deleted_at is null and tr.tempo_id = o.tempo
        where (p_pais is null or p.pais = p_pais)
          and (p_estado is null or coalesce(nullif(trim(br.bo_status), ''), '—') = p_estado)
          and (p_reclamos is null or coalesce(br.reclamos, '—') = p_reclamos)
    )
    select b.id, b.track_master_id, b.pais_code, b.tempo_id, b.track_artist_concat, b.snapshot_date, b.created_date,
           b.bo_report_id, b.bo, b.ca, b.perf_raw, b.mech_raw, b.estado, b.reclamos, b.mech_bo, b.estado_trabajo,
           b.estado_obra, b.deleted_at, b.ticket, b.ticket_fecha, b.chart, b.en_chart_de, b.duplicada,
           count(*) over () as total
    from base b
    where (p_chart is null or b.chart = p_chart)
      and (p_estado_trabajo is null or p_estado_trabajo = any(string_to_array(coalesce(b.estado_trabajo, '—'), ' / ')))
    order by lower(b.track_artist_concat), b.pais_code, b.track_master_id, b.orden   -- siempre alfabético (06/11/2026)
    limit greatest(p_limite, 0) offset greatest(p_offset, 0);
$function$;

-- Valores de los filtros de la tabla por territorio (como el filtro de Excel). '—' = sin valor.
CREATE OR REPLACE FUNCTION public.fn_territory_opciones()
 RETURNS TABLE(campo text, valor text)
 LANGUAGE sql
 STABLE
AS $function$
    select 'estado', v from (select distinct coalesce(nullif(trim(bo_status), ''), '—') as v from territory_bo_report
                             where deleted_at is null union select '—') s
    union all
    select 'reclamos', v from (select distinct coalesce(reclamos, '—') as v from territory_bo_report where deleted_at is null
                               union select '—') s
    union all
    select 'estado_trabajo', v from (select distinct e as v from territory_bo_report,   -- cada problema por separado
                                     unnest(string_to_array(coalesce(estado_trabajo, '—'), ' / ')) e where deleted_at is null
                                     union select '—'
                                     union select 'DUPLICADA' where exists (select 1 from tempo_duplicado)) s
    order by 1, 2;
$function$;

-- Cantidad de obras de cada opción de descarga (reporte BO o CSV) con los filtros y la búsqueda de la tabla principal:
-- las mismas que tomaría fn_preparar_envio.
DROP FUNCTION IF EXISTS public.fn_envio_conteo(text, date, date, pais_code_enum);         -- antes no tenía la búsqueda
DROP FUNCTION IF EXISTS public.fn_envio_conteo(text, date, date, pais_code_enum, text);   -- ni el filtro Tempo ID
CREATE OR REPLACE FUNCTION public.fn_envio_conteo(p_tipo text, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date,
    p_pais pais_code_enum DEFAULT NULL::pais_code_enum, p_buscar text DEFAULT NULL::text, p_tempo text DEFAULT NULL::text)
 RETURNS TABLE(todas bigint, identificadas bigint)
 LANGUAGE sql
 STABLE
AS $function$
    select count(*),
           count(*) filter (where fn_envio_identificada(p_tipo, v.tempo_id) and not exists (
               select 1 from envio_identificadas ei where ei.tipo = p_tipo and ei.usuario = fn_usuario_envio()
                 and ei.track_master_id = v.id))   -- desde la última descarga de esta persona (01)
    from fn_master_view(p_date_from, p_date_to, p_pais, false) v
    where (p_tipo <> 'reporte_bo' or fn_envio_identificada(p_tipo, v.tempo_id))
      and fn_coincide_busqueda(p_buscar, v.tempo_id, v.track_artist_concat)
      and fn_coincide_tempo(p_tempo, v.tempo_id);
$function$;

-- Semana del último chart cargado, por territorio y plataforma (un acceso al índice por combinación).
CREATE OR REPLACE FUNCTION public.fn_ultimas_cargas()
 RETURNS TABLE(pais_code pais_code_enum, platform text, snapshot_date date)
 LANGUAGE sql
 STABLE
AS $function$
    select p.pais, pl.plataforma, u.snapshot_date
    from unnest(enum_range(null::pais_code_enum)) as p(pais)
    cross join unnest(array['spotify', 'youtube']) as pl(plataforma)
    cross join lateral (
        select tt.snapshot_date from territory_tracks tt
        where tt.platform = pl.plataforma and tt.pais_code = p.pais and tt.deleted_at is null
        order by tt.snapshot_date desc limit 1
    ) u
    order by 1, 2;
$function$;
