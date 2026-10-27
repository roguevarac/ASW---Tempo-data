-- =====================================================================
-- Mejora propia (no viene de Supabase): estado de trabajo con más casos (pedido del usuario, 28/10/2026).
--
-- Problemas (una obra puede tener varios; se muestran todos, separados por " / ", y el filtro la encuentra por
-- cualquiera de ellos):
--   RECLAMO ACTIVO    el Reporte BackOffice informa un reclamo (columna Reclamos con un valor que no sea "sin reclamo")
--   REVISAR NOT WORK  el estado de BO no es WORK: una obra que figura en los rankings tiene usos, así que debería estar
--                     registrada como WORK
--   REVISAR %         el % Mech de BO y el de Tempo no coinciden (antes "REVISAR")
-- Sin problemas: OK BO-Tempo / OK - Obra AR / OK - Obra MX, como antes.
-- Los manuales (duplicada, dif de split) no se pisan. Las filas ya cargadas se recalculan.
-- Idempotente: se aplica en cada arranque (db/mejoras.sh).
-- =====================================================================
SET search_path = public;

-- Si la columna Reclamos indica un reclamo vigente. Vacío, "No", "None", "0", "N/A" o resuelto/cerrado: no.
CREATE OR REPLACE FUNCTION public.fn_reclamo_activo(p_reclamos text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select coalesce(nullif(regexp_replace(lower(unaccent(coalesce(p_reclamos, ''))), '[^a-z0-9]', '', 'g'), ''), 'no')
           !~ '^(no|none|ninguno|ninguna|na|nan|null|0|false|sinreclamo|sinreclamos|resolved|resuelto|cerrado|closed|inactive|inactivo)$';
$function$;

-- Si el estado lo puso el sistema (todos sus elementos son automáticos): se recalcula. Los manuales no se tocan.
CREATE OR REPLACE FUNCTION public.fn_estado_automatico(p_estado text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select p_estado is null or string_to_array(p_estado, ' / ') <@ array['REVISAR', 'REVISAR %', 'RECLAMO ACTIVO',
           'REVISAR NOT WORK', 'OK BO-Tempo', 'OK - Obra AR', 'OK - Obra MX'];
$function$;

CREATE OR REPLACE FUNCTION public.trg_bo_report_auto_revisar()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare
    v_mech_tempo numeric;
    v_oficina    text;
    v_pct        text;
    v_problemas  text[] := '{}';
begin
    if fn_estado_automatico(new.estado_trabajo) then

        select tr.mech_pc, upper(unaccent(trim(coalesce(tr.originating_office, ''))))
          into v_mech_tempo, v_oficina
        from territory_tempo_report tr
        where tr.track_master_id = new.track_master_id
          and tr.pais_code = new.pais_code
          and tr.deleted_at is null;

        -- Comparación de porcentajes (como antes).
        if v_mech_tempo is not null and new.mech_bo is not null then
            if abs(v_mech_tempo - new.mech_bo) <= 0.1 then
                v_pct := 'OK BO-Tempo';
            -- Excepción: BO informa 0% pero Tempo tiene porcentaje, y la obra se originó en Argentina o México.
            elsif new.mech_bo = 0 and v_mech_tempo <> 0 and v_oficina like '%ARGENTINA%' then
                v_pct := 'OK - Obra AR';
            elsif new.mech_bo = 0 and v_mech_tempo <> 0 and v_oficina like '%MEXICO%' then
                v_pct := 'OK - Obra MX';
            else
                v_pct := 'REVISAR %';
            end if;
        end if;

        if fn_reclamo_activo(new.reclamos) then
            v_problemas := array_append(v_problemas, 'RECLAMO ACTIVO');
        end if;
        if nullif(trim(coalesce(new.bo_status, '')), '') is not null and upper(trim(new.bo_status)) <> 'WORK' then
            v_problemas := array_append(v_problemas, 'REVISAR NOT WORK');
        end if;
        if v_pct = 'REVISAR %' then
            v_problemas := array_append(v_problemas, 'REVISAR %');
        end if;
        new.estado_trabajo := case when cardinality(v_problemas) > 0 then array_to_string(v_problemas, ' / ') else v_pct end;
    end if;
    return new;
end;
$function$;

-- Filas ya cargadas: se recalculan los estados automáticos (también los "REVISAR" de antes).
UPDATE public.territory_bo_report SET estado_trabajo = estado_trabajo
WHERE deleted_at IS NULL AND fn_estado_automatico(estado_trabajo);
