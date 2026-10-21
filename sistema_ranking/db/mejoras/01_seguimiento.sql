-- =====================================================================
-- Mejora propia (no viene de Supabase): seguimiento de envíos.
--
-- Registra qué obras salieron en cada "Reporte BO" y en cada descarga del CSV de la tabla principal. Así se puede
-- descargar solo lo nuevo (obras que nunca salieron en ese tipo de envío) o todo (la revisión completa, por ejemplo
-- cada trimestre), y la tabla principal muestra cuándo se envió cada obra por última vez.
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
-- registra. p_modo 'nuevas': solo las que nunca salieron en un envío de ese tipo; 'todas': todas.
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
    if p_modo is null or p_modo not in ('nuevas', 'todas') then
        raise exception 'Modo de envío desconocido: %', p_modo;
    end if;

    insert into envios (tipo, modo, pais_code, date_from, date_to)
    values (p_tipo, p_modo, p_pais, p_date_from, p_date_to)
    returning id into v_envio;

    insert into envio_obras (envio_id, track_master_id)
    select v_envio, v.id
    from fn_master_view(p_date_from, p_date_to, p_pais, false) v
    where (p_tipo <> 'reporte_bo' or trim(coalesce(v.tempo_id, '')) ~ '^[0-9]+$')
      and (p_modo = 'todas' or not exists (
            select 1 from envio_obras eo join envios e on e.id = eo.envio_id
            where e.tipo = p_tipo and eo.track_master_id = v.id and e.id <> v_envio));
    get diagnostics v_obras = row_count;

    if v_obras = 0 then
        delete from envios where id = v_envio;
        return query select null::bigint, null::integer, 0;
        return;
    end if;
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
