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

-- Tabla principal: una página (p_limite filas desde p_offset), con los mismos filtros que fn_master_view, la búsqueda
-- por título, artista o Tempo ID, el seguimiento de envíos de cada obra y el total de filas que cumplen el filtro.
CREATE OR REPLACE FUNCTION public.fn_master_pagina(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date,
    p_pais pais_code_enum DEFAULT NULL::pais_code_enum, p_include_deleted boolean DEFAULT false, p_buscar text DEFAULT NULL::text,
    p_limite integer DEFAULT 100, p_offset integer DEFAULT 0)
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
          and (fn_patron_busqueda(p_buscar) is null
               or lower(coalesce(tm.track_artist_concat, '') || ' ' || coalesce(tm.tempo_id, '')) like fn_patron_busqueda(p_buscar))
    ), pagina as (
        select b.*, count(*) over () as total
        from base b
        order by b.ultima desc nulls last, b.track_artist_concat, b.id
        limit greatest(p_limite, 0) offset greatest(p_offset, 0)
    )
    select p.id, p.track_artist_concat, p.track_name_clean, p.tempo_id, p.ultima, p.deleted_at,
           e.ult_bo_at, e.ult_bo_carga, e.ult_csv_at, p.total
    from pagina p
    left join lateral (
        select max(en.created_at) filter (where en.tipo = 'reporte_bo') as ult_bo_at,
               (array_agg(en.carga order by en.created_at desc) filter (where en.tipo = 'reporte_bo'))[1] as ult_bo_carga,
               max(en.created_at) filter (where en.tipo = 'csv_principal') as ult_csv_at
        from envio_obras eo join envios en on en.id = eo.envio_id
        where eo.track_master_id = p.id
    ) e on true
    order by p.ultima desc nulls last, p.track_artist_concat, p.id;
$function$;

-- Tabla principal: cuántas obras tienen Tempo ID (número o marcador, como UNCONTROLLED) y cuántas no, con los mismos
-- filtros y búsqueda que fn_master_pagina (las dos cantidades suman su total).
CREATE OR REPLACE FUNCTION public.fn_master_conteo(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date,
    p_pais pais_code_enum DEFAULT NULL::pais_code_enum, p_include_deleted boolean DEFAULT false, p_buscar text DEFAULT NULL::text)
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
      and (fn_patron_busqueda(p_buscar) is null
           or lower(coalesce(tm.track_artist_concat, '') || ' ' || coalesce(tm.tempo_id, '')) like fn_patron_busqueda(p_buscar));
$function$;

-- Tabla por territorio: una página, con los filtros de fn_territory_view más los de reclamos y estado de trabajo
-- ('—' = sin valor) y la búsqueda por Tempo ID o título. Ordenada por territorio y título.
CREATE OR REPLACE FUNCTION public.fn_territory_pagina(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date,
    p_pais pais_code_enum DEFAULT NULL::pais_code_enum, p_include_deleted boolean DEFAULT false, p_buscar text DEFAULT NULL::text,
    p_reclamos text DEFAULT NULL::text, p_estado_trabajo text DEFAULT NULL::text,
    p_limite integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS TABLE(id uuid, track_master_id uuid, pais_code pais_code_enum, tempo_id text, track_artist_concat text, snapshot_date date,
               created_date date, bo_report_id uuid, bo text, ca text, perf_raw text, mech_raw text, estado text, reclamos text,
               mech_bo numeric, estado_trabajo text, estado_obra text, deleted_at timestamp with time zone, total bigint)
 LANGUAGE sql
 STABLE
AS $function$
    with ultimo as (
        select distinct on (tt.track_master_id, tt.pais_code)
               tt.id, tt.track_master_id, tt.pais_code, tt.snapshot_date, tt.deleted_at
        from territory_tracks tt
        where (p_include_deleted or tt.deleted_at is null)
          and (p_pais      is null or tt.pais_code = p_pais)
          and (p_date_from is null or tt.snapshot_date >= p_date_from)
          and (p_date_to   is null or tt.snapshot_date <= p_date_to)
        order by tt.track_master_id, tt.pais_code, tt.snapshot_date desc
    ), base as (
        select u.id, u.track_master_id, u.pais_code, tm.tempo_id, tm.track_artist_concat, u.snapshot_date, tr.created_date,
               br.id as bo_report_id, br.bo_id as bo, br.ca,
               coalesce(tr.perf_raw, tr.perf_pc::text) as perf_raw, coalesce(tr.mech_raw, tr.mech_pc::text) as mech_raw,
               br.bo_status as estado, br.reclamos, br.mech_bo, br.estado_trabajo, tr.estado_obra, u.deleted_at
        from ultimo u
        join tracks_master tm on tm.id = u.track_master_id
        left join territory_bo_report br on br.track_master_id = u.track_master_id and br.pais_code = u.pais_code
        left join territory_tempo_report tr on tr.track_master_id = u.track_master_id and tr.pais_code = u.pais_code
               and tr.deleted_at is null
        where (p_include_deleted or (u.deleted_at is null and tm.deleted_at is null))
          and (p_reclamos is null or coalesce(br.reclamos, '—') = p_reclamos)
          and (p_estado_trabajo is null or coalesce(br.estado_trabajo, '—') = p_estado_trabajo)
          and (fn_patron_busqueda(p_buscar) is null
               or lower(coalesce(tm.tempo_id, '') || ' ' || coalesce(tm.track_artist_concat, '')) like fn_patron_busqueda(p_buscar))
    )
    select b.*, count(*) over () as total
    from base b
    order by b.pais_code, b.track_artist_concat, b.id
    limit greatest(p_limite, 0) offset greatest(p_offset, 0);
$function$;

-- Valores de los filtros de la tabla por territorio (como el filtro de Excel). '—' = sin valor.
CREATE OR REPLACE FUNCTION public.fn_territory_opciones()
 RETURNS TABLE(campo text, valor text)
 LANGUAGE sql
 STABLE
AS $function$
    select 'reclamos', v from (select distinct coalesce(reclamos, '—') as v from territory_bo_report where deleted_at is null
                               union select '—') s
    union all
    select 'estado_trabajo', v from (select distinct coalesce(estado_trabajo, '—') as v from territory_bo_report where deleted_at is null
                                     union select '—') s
    order by 1, 2;
$function$;

-- Cantidad de obras de cada opción de descarga (reporte BO o CSV) con los filtros de la tabla principal: las mismas
-- que tomaría fn_preparar_envio.
DROP FUNCTION IF EXISTS public.fn_envio_conteo(text, date, date, pais_code_enum);   -- antes devolvía "nuevas"
CREATE OR REPLACE FUNCTION public.fn_envio_conteo(p_tipo text, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date,
    p_pais pais_code_enum DEFAULT NULL::pais_code_enum)
 RETURNS TABLE(todas bigint, identificadas bigint)
 LANGUAGE sql
 STABLE
AS $function$
    select count(*),
           count(*) filter (where fn_envio_identificada(p_tipo, v.tempo_id) and not exists (
               select 1 from envio_identificadas ei where ei.tipo = p_tipo and ei.track_master_id = v.id))
    from fn_master_view(p_date_from, p_date_to, p_pais, false) v
    where p_tipo <> 'reporte_bo' or fn_envio_identificada(p_tipo, v.tempo_id);
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
