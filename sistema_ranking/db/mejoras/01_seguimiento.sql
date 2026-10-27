-- =====================================================================
-- Mejora propia (no viene de Supabase): seguimiento de envíos.
--
-- Registra qué obras salieron en cada "Reporte BO" y en cada descarga del CSV de la tabla principal. Cada descarga
-- es "Todas" (todas las obras) o "Identificadas" (las que obtuvieron Tempo ID desde la última descarga de ese tipo:
-- nunca figuraron identificadas en una descarga anterior). El modo "nuevas" (nunca incluidas) queda solo para el
-- historial.
--
-- Idempotente: se aplica en cada arranque (db/mejoras.sh), también sobre una base ya instalada.
-- =====================================================================
SET search_path = public;

CREATE TABLE IF NOT EXISTS public.envios (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tipo text NOT NULL CHECK (tipo IN ('reporte_bo', 'csv_principal')),
    modo text NOT NULL CHECK (modo IN ('nuevas', 'todas')),
    carga integer,                       -- número de carga del reporte BO (BOcargaN)
    pais_code pais_code_enum,            -- filtros que había en la tabla principal al descargar
    date_from date,
    date_to date,
    obras integer NOT NULL DEFAULT 0,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    created_by text NOT NULL DEFAULT COALESCE((auth.uid())::text, (CURRENT_USER)::text)
);
CREATE TABLE IF NOT EXISTS public.envio_obras (
    envio_id bigint NOT NULL REFERENCES public.envios(id) ON DELETE CASCADE,
    track_master_id uuid NOT NULL REFERENCES public.tracks_master(id) ON DELETE CASCADE,
    PRIMARY KEY (envio_id, track_master_id)
);
CREATE INDEX IF NOT EXISTS ix_envio_obras_track ON public.envio_obras (track_master_id);
ALTER TABLE public.envios DROP CONSTRAINT IF EXISTS envios_modo_check;
ALTER TABLE public.envios ADD CONSTRAINT envios_modo_check CHECK (modo IN ('nuevas', 'todas', 'identificadas'));

-- Obras que ya figuraron identificadas en una descarga de cada tipo (con el envío en que se vieron por primera vez).
-- Identificada: para el reporte BO, Tempo ID numérico; para el CSV, cualquier Tempo ID (también UNCONTROLLED).
DO $$
BEGIN
    IF to_regclass('public.envio_identificadas') IS NULL THEN
        CREATE TABLE public.envio_identificadas (
            tipo text NOT NULL CHECK (tipo IN ('reporte_bo', 'csv_principal')),
            track_master_id uuid NOT NULL REFERENCES public.tracks_master(id) ON DELETE CASCADE,
            envio_id bigint REFERENCES public.envios(id) ON DELETE SET NULL,
            PRIMARY KEY (tipo, track_master_id)
        );
        -- Lo ya descargado antes de este cambio: una obra figuró identificada si, al momento de su última descarga de
        -- ese tipo, su último cambio registrado tenía Tempo ID (el reporte BO solo llevaba obras con Tempo ID).
        INSERT INTO public.envio_identificadas (tipo, track_master_id, envio_id)
        SELECT u.tipo, u.track_master_id, u.envio_id
        FROM (SELECT DISTINCT ON (e.tipo, eo.track_master_id) e.tipo, eo.track_master_id, e.id AS envio_id, e.created_at
              FROM public.envio_obras eo JOIN public.envios e ON e.id = eo.envio_id
              ORDER BY e.tipo, eo.track_master_id, e.created_at DESC) u
        WHERE u.tipo = 'reporte_bo'
           OR coalesce((SELECT a.new_data ->> 'tempo_id' FROM public.audit_logs a
                        WHERE a.table_name = 'tracks_master' AND a.row_id = u.track_master_id AND a.changed_at <= u.created_at
                        ORDER BY a.changed_at DESC LIMIT 1), '') <> '';
    END IF;
END $$;
CREATE INDEX IF NOT EXISTS ix_envio_identificadas_track ON public.envio_identificadas (track_master_id);
ALTER TABLE public.envio_identificadas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS envio_identificadas_select ON public.envio_identificadas;
CREATE POLICY envio_identificadas_select ON public.envio_identificadas AS PERMISSIVE FOR SELECT TO authenticated USING (true);
GRANT SELECT ON public.envio_identificadas TO authenticated;
GRANT ALL ON public.envio_identificadas TO service_role;

-- Si la obra cuenta como identificada para ese tipo de descarga.
CREATE OR REPLACE FUNCTION public.fn_envio_identificada(p_tipo text, p_tempo_id text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select case when p_tipo = 'reporte_bo' then trim(coalesce(p_tempo_id, '')) ~ '^[0-9]+$'
                else trim(coalesce(p_tempo_id, '')) <> '' end;
$function$;
CREATE INDEX IF NOT EXISTS ix_envios_tipo_fecha ON public.envios (tipo, created_at DESC);

ALTER TABLE public.envios ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.envio_obras ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS envios_select ON public.envios;
CREATE POLICY envios_select ON public.envios AS PERMISSIVE FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS envio_obras_select ON public.envio_obras;
CREATE POLICY envio_obras_select ON public.envio_obras AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- Solo lectura para los usuarios: los envíos se registran con fn_preparar_envio.
GRANT SELECT ON public.envios, public.envio_obras TO authenticated;
GRANT ALL ON public.envios, public.envio_obras TO service_role;

-- Arma un envío con las obras de la tabla principal (mismos filtros de país y fechas que la pantalla) y lo
-- registra. p_modo 'todas': todas; 'identificadas': las identificadas que nunca figuraron identificadas en una descarga
-- de ese tipo; 'nuevas' (anterior): las que nunca salieron en ese tipo.
-- El reporte BO solo lleva obras con tempo_id numérico y toma el número de carga siguiente.
-- Sin obras no registra nada (ni gasta un número de carga) y devuelve obras = 0.
CREATE OR REPLACE FUNCTION public.fn_preparar_envio(p_tipo text, p_modo text, p_date_from date DEFAULT NULL::date,
                                                    p_date_to date DEFAULT NULL::date, p_pais pais_code_enum DEFAULT NULL::pais_code_enum)
 RETURNS TABLE(envio_id bigint, carga integer, obras integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare
    v_envio bigint;
    v_carga integer;
    v_obras integer;
begin
    if p_tipo is null or p_tipo not in ('reporte_bo', 'csv_principal') then
        raise exception 'Tipo de envío desconocido: %', p_tipo;
    end if;
    if p_modo is null or p_modo not in ('nuevas', 'todas', 'identificadas') then
        raise exception 'Modo de envío desconocido: %', p_modo;
    end if;

    insert into envios (tipo, modo, pais_code, date_from, date_to)
    values (p_tipo, p_modo, p_pais, p_date_from, p_date_to)
    returning id into v_envio;

    create temp table if not exists _envio_vista (id uuid, tempo_id text) on commit drop;
    truncate _envio_vista;
    insert into _envio_vista select v.id, v.tempo_id from fn_master_view(p_date_from, p_date_to, p_pais, false) v;

    insert into envio_obras (envio_id, track_master_id)
    select v_envio, v.id
    from _envio_vista v
    where (p_tipo <> 'reporte_bo' or fn_envio_identificada(p_tipo, v.tempo_id))
      and (p_modo <> 'identificadas' or (fn_envio_identificada(p_tipo, v.tempo_id) and not exists (
            select 1 from envio_identificadas ei where ei.tipo = p_tipo and ei.track_master_id = v.id)))
      and (p_modo <> 'nuevas' or not exists (
            select 1 from envio_obras eo join envios e on e.id = eo.envio_id
            where e.tipo = p_tipo and eo.track_master_id = v.id and e.id <> v_envio));
    get diagnostics v_obras = row_count;

    if v_obras = 0 then
        delete from envios where id = v_envio;
        return query select null::bigint, null::integer, 0;
        return;
    end if;
    -- Las identificadas de esta descarga ya no son nuevas para la próxima de este tipo.
    insert into envio_identificadas (tipo, track_master_id, envio_id)
    select p_tipo, eo.track_master_id, v_envio
    from envio_obras eo join _envio_vista v on v.id = eo.track_master_id
    where eo.envio_id = v_envio and fn_envio_identificada(p_tipo, v.tempo_id)
    on conflict do nothing;
    if p_tipo = 'reporte_bo' then
        v_carga := fn_next_bo_carga();
    end if;
    update envios set obras = v_obras, carga = v_carga where id = v_envio;
    return query select v_envio, v_carga, v_obras;
end;
$function$;
REVOKE EXECUTE ON FUNCTION public.fn_preparar_envio(text, text, date, date, pais_code_enum) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_preparar_envio(text, text, date, date, pais_code_enum) TO authenticated, service_role;

-- Las obras de un envío, para armar el archivo (CSV de la tabla principal o reporte BO).
CREATE OR REPLACE FUNCTION public.fn_envio_obras(p_envio_id bigint)
 RETURNS TABLE(track_artist_concat text, tempo_id text, track_name_clean text)
 LANGUAGE sql
 STABLE
AS $function$
    select tm.track_artist_concat, tm.tempo_id, tm.track_name_clean
    from envio_obras eo
    join tracks_master tm on tm.id = eo.track_master_id
    where eo.envio_id = p_envio_id
    order by tm.track_artist_concat, tm.id;
$function$;

-- Último envío de cada obra, por tipo (lo muestra la tabla principal y lo usa su filtro "Seguimiento").
CREATE OR REPLACE FUNCTION public.fn_envios_por_obra()
 RETURNS TABLE(track_master_id uuid, ult_bo_at timestamp with time zone, ult_bo_carga integer, ult_csv_at timestamp with time zone)
 LANGUAGE sql
 STABLE
AS $function$
    select eo.track_master_id,
           max(e.created_at) filter (where e.tipo = 'reporte_bo'),
           (array_agg(e.carga order by e.created_at desc) filter (where e.tipo = 'reporte_bo'))[1],
           max(e.created_at) filter (where e.tipo = 'csv_principal')
    from envio_obras eo
    join envios e on e.id = eo.envio_id
    group by eo.track_master_id
    order by eo.track_master_id;
$function$;
