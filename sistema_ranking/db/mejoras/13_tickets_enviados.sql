-- =====================================================================
-- Mejora propia (no viene de Supabase): tickets enviados (pedido del usuario, 04/11/2026).
--
--  * Con ticket, el estado de trabajo de la obra en ese territorio pasa a TICKET ENVIADO (el trigger de
--    10_estado_trabajo.sql lo mantiene mientras la obra tenga problemas; si un reporte nuevo la deja sin problemas,
--    vuelve a OK). Al quitar el ticket se recalcula.
--  * public.tickets: cada número de ticket, quién lo cargó primero y cuándo. La pestaña "Tickets enviados" lo muestra
--    con la fecha del ticket, los países y la cantidad de obras que lo tienen hoy (fn_tickets_lista, fn_ticket_obras).
--
-- Idempotente: se aplica en cada arranque (db/mejoras.sh).
-- =====================================================================
SET search_path = public;

CREATE TABLE IF NOT EXISTS public.tickets (
    ticket     text PRIMARY KEY,
    creado_por text NOT NULL DEFAULT COALESCE((auth.uid())::text, (CURRENT_USER)::text),
    creado_el  timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.tickets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tickets_select ON public.tickets;
CREATE POLICY tickets_select ON public.tickets AS PERMISSIVE FOR SELECT TO authenticated USING (true);
GRANT SELECT ON public.tickets TO authenticated;
GRANT ALL ON public.tickets TO service_role;

-- Tickets cargados antes de esta mejora: quien los cargó primero y cuándo, según las obras que los tienen.
INSERT INTO public.tickets (ticket, creado_por, creado_el)
SELECT DISTINCT ON (s.ticket) s.ticket, s.updated_by, min(s.updated_at) OVER (PARTITION BY s.ticket)
FROM public.territory_seguimiento s
WHERE nullif(trim(s.ticket), '') IS NOT NULL
ORDER BY s.ticket, s.updated_at
ON CONFLICT (ticket) DO NOTHING;

-- Ticket y fecha de una obra en un territorio (tabla por territorio). p_campo: 'ticket' o 'fecha'. La fecha se escribe
-- como DDMMAAAA (26092026), DD/MM/AAAA o DD-MM-AAAA; vacío la borra. Devuelve el valor guardado.
CREATE OR REPLACE FUNCTION public.fn_guardar_seguimiento(p_track_id uuid, p_pais pais_code_enum, p_campo text, p_valor text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v text := nullif(trim(coalesce(p_valor, '')), '');
    d text;
    v_fecha date;
begin
    if coalesce(fn_app_role(), '') not in ('admin', 'usuario_estandar') then
        raise exception 'Sin permiso para modificar obras.' using errcode = 'insufficient_privilege';
    end if;
    if p_campo not in ('ticket', 'fecha') then
        raise exception 'Campo desconocido: %', p_campo;
    end if;
    if not exists (select 1 from tracks_master where id = p_track_id and deleted_at is null) then
        raise exception 'La obra no existe o fue eliminada.';
    end if;
    if p_campo = 'fecha' and v is not null then
        d := regexp_replace(v, '[^0-9]', '', 'g');
        if v ~ '^\d{4}-\d{1,2}-\d{1,2}$' then
            d := to_char(v::date, 'DDMMYYYY');
        elsif v ~ '^\d{1,2}[/.-]\d{1,2}[/.-]\d{4}$' then
            d := lpad(split_part(regexp_replace(v, '[/.-]', '/', 'g'), '/', 1), 2, '0')
              || lpad(split_part(regexp_replace(v, '[/.-]', '/', 'g'), '/', 2), 2, '0')
              || split_part(regexp_replace(v, '[/.-]', '/', 'g'), '/', 3);
        end if;
        begin
            if d !~ '^\d{8}$' then raise exception 'formato'; end if;
            v_fecha := to_date(d, 'DDMMYYYY');
            if to_char(v_fecha, 'DDMMYYYY') <> d then raise exception 'fecha inexistente'; end if;
        exception when others then
            raise exception 'Fecha no válida: "%". Escribila como DDMMAAAA, por ejemplo 26092026.', v using errcode = '22023';
        end;
    end if;
    insert into territory_seguimiento (track_master_id, pais_code, ticket, ticket_fecha)
    values (p_track_id, p_pais, case when p_campo = 'ticket' then v end, v_fecha)
    on conflict (track_master_id, pais_code) do update
    set ticket = case when p_campo = 'ticket' then excluded.ticket else territory_seguimiento.ticket end,
        ticket_fecha = case when p_campo = 'fecha' then excluded.ticket_fecha else territory_seguimiento.ticket_fecha end,
        updated_at = now(), updated_by = COALESCE((auth.uid())::text, (CURRENT_USER)::text);
    if p_campo = 'ticket' then
        if v is not null then
            insert into tickets (ticket) values (v) on conflict (ticket) do nothing;
            -- El trigger del reporte BO decide: TICKET ENVIADO si la obra tiene problemas (o estaba marcada a mano).
            update territory_bo_report set estado_trabajo = 'TICKET ENVIADO'
            where track_master_id = p_track_id and pais_code = p_pais and deleted_at is null;
        else
            update territory_bo_report set estado_trabajo = null
            where track_master_id = p_track_id and pais_code = p_pais and deleted_at is null and estado_trabajo = 'TICKET ENVIADO';
        end if;
    end if;
    return case when p_campo = 'ticket' then coalesce(v, '') else coalesce(to_char(v_fecha, 'DD/MM/YYYY'), '') end;
end;
$function$;
REVOKE ALL ON FUNCTION public.fn_guardar_seguimiento(uuid, pais_code_enum, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_guardar_seguimiento(uuid, pais_code_enum, text, text) TO authenticated, service_role;

-- Pestaña "Tickets enviados": un renglón por ticket que hoy tiene alguna obra, el más nuevo primero.
CREATE OR REPLACE FUNCTION public.fn_tickets_lista()
 RETURNS TABLE(ticket text, creado_por text, creado_el timestamp with time zone, fecha date, paises text, obras bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    -- Sale de las obras; public.tickets aporta quién lo cargó y cuándo (si falta, por ejemplo tras restaurar un respaldo
    -- anterior, se toma la primera obra que lo recibió).
    with g as (
        select s.ticket, min(s.ticket_fecha) as fecha, string_agg(distinct s.pais_code::text, ', ' order by s.pais_code::text) as paises,
               count(*) as obras, min(s.updated_at) as primero, (array_agg(s.updated_by order by s.updated_at))[1] as por
        from territory_seguimiento s
        join tracks_master tm on tm.id = s.track_master_id and tm.deleted_at is null
        where nullif(trim(s.ticket), '') is not null
        group by s.ticket
    )
    select g.ticket, coalesce(u.email::text, t.creado_por, g.por), coalesce(t.creado_el, g.primero), g.fecha, g.paises, g.obras
    from g
    left join tickets t on t.ticket = g.ticket
    left join auth.users u on u.id::text = coalesce(t.creado_por, g.por)
    order by 3 desc, 1;
$function$;
REVOKE EXECUTE ON FUNCTION public.fn_tickets_lista() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_tickets_lista() TO authenticated, service_role;

-- Las obras que tienen un ticket, por país y título.
CREATE OR REPLACE FUNCTION public.fn_ticket_obras(p_ticket text)
 RETURNS TABLE(pais_code text, track_artist_concat text, tempo_id text, ticket_fecha date, estado_trabajo text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    select s.pais_code::text, tm.track_artist_concat, tm.tempo_id, s.ticket_fecha, br.estado_trabajo
    from territory_seguimiento s
    join tracks_master tm on tm.id = s.track_master_id and tm.deleted_at is null
    left join territory_bo_report br on br.track_master_id = s.track_master_id and br.pais_code = s.pais_code
         and br.deleted_at is null
    where s.ticket = p_ticket
    order by s.pais_code, tm.track_artist_concat;
$function$;
GRANT EXECUTE ON FUNCTION public.fn_ticket_obras(text) TO authenticated, service_role;

-- Obras que ya tenían ticket antes de esta mejora: su estado de trabajo se recalcula (TICKET ENVIADO si tienen problemas).
UPDATE public.territory_bo_report br SET estado_trabajo = br.estado_trabajo
FROM public.territory_seguimiento s
WHERE s.track_master_id = br.track_master_id AND s.pais_code = br.pais_code AND nullif(trim(s.ticket), '') IS NOT NULL
  AND br.deleted_at IS NULL AND fn_estado_automatico(br.estado_trabajo);
