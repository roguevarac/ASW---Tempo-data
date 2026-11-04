-- =====================================================================
-- Mejora propia (no viene de Supabase): ticket y fecha para todas las obras filtradas de la tabla por territorio
-- (pedido del usuario, 04/11/2026: "todas las cargas son en bulk de tickets, no se manda ticket por una canción sola,
-- sino por varias al mismo tiempo, por el filtro aplicado").
--
-- fn_ticket_filtrado toma los mismos filtros que la pantalla (los de fn_territory_pagina, sin las eliminadas):
--   p_aplicar = false  solo cuenta: obras que quedan con el ticket y cuántas ya tenían otro (se reemplaza)
--   p_aplicar = true   guarda ticket y fecha en todas, en una sola transacción (si la fecha no es válida, ninguna)
-- Sin ningún filtro no hace nada: un ticket nunca se carga a la tabla entera.
-- Idempotente: se aplica en cada arranque (db/mejoras.sh).
-- =====================================================================
SET search_path = public;

CREATE OR REPLACE FUNCTION public.fn_ticket_filtrado(p_ticket text, p_fecha text, p_aplicar boolean DEFAULT false,
    p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_pais pais_code_enum DEFAULT NULL::pais_code_enum,
    p_buscar text DEFAULT NULL::text, p_reclamos text DEFAULT NULL::text, p_estado_trabajo text DEFAULT NULL::text,
    p_estado text DEFAULT NULL::text)
 RETURNS TABLE(obras integer, con_otro_ticket integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_ticket text := nullif(trim(coalesce(p_ticket, '')), '');
    r record;
begin
    if coalesce(fn_app_role(), '') not in ('admin', 'usuario_estandar') then
        raise exception 'Sin permiso para modificar obras.' using errcode = 'insufficient_privilege';
    end if;
    if p_date_from is null and p_date_to is null and p_pais is null and nullif(trim(coalesce(p_buscar, '')), '') is null
       and p_reclamos is null and p_estado_trabajo is null and p_estado is null then
        raise exception 'Aplicá al menos un filtro: el ticket se carga a las obras filtradas.' using errcode = '22023';
    end if;
    obras := 0; con_otro_ticket := 0;
    for r in select v.track_master_id, v.pais_code, v.ticket
             from fn_territory_pagina(p_date_from, p_date_to, p_pais, false, p_buscar, p_reclamos, p_estado_trabajo,
                                      2147483647, 0, p_estado) v
    loop
        obras := obras + 1;
        if r.ticket is not null and r.ticket is distinct from v_ticket then con_otro_ticket := con_otro_ticket + 1; end if;
        if p_aplicar then
            if v_ticket is null then
                raise exception 'Ingresá el número de ticket.' using errcode = '22023';
            end if;
            perform fn_guardar_seguimiento(r.track_master_id, r.pais_code, 'ticket', v_ticket);
            perform fn_guardar_seguimiento(r.track_master_id, r.pais_code, 'fecha', p_fecha);
        end if;
    end loop;
    return next;
end;
$function$;
REVOKE ALL ON FUNCTION public.fn_ticket_filtrado(text, text, boolean, date, date, pais_code_enum, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_ticket_filtrado(text, text, boolean, date, date, pais_code_enum, text, text, text, text)
    TO authenticated, service_role;
