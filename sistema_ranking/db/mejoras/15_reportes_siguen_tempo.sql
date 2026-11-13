-- =====================================================================
-- Mejora propia (no viene de Supabase): los datos de BO y Tempo siguen al Tempo ID (pedido del usuario, 13/11/2026),
-- y "UNCONTROLLED DUP" para unificar obras sin Tempo ID numérico.
--
-- Los reportes (territory_bo_report, territory_tempo_report, territory_control) se cargan por Tempo ID y país, pero
-- quedaban atados a la obra que tenía ese Tempo ID al cargarlos. Si después el Tempo ID pasa a otra obra (estaba mal
-- asignado), los datos tienen que pasar con él:
--   * trg_reporte_sigue_tempo (BEFORE en cada reporte): la fila va a la obra que hoy tiene su Tempo ID. Si ninguna lo
--     tiene, queda en espera (oculta, en_espera = true) hasta que alguna obra lo reciba. El ticket del territorio pasa
--     con los datos de BO.
--   * trg_tracks_master_reportes_tempo (AFTER en tracks_master): al cambiar el Tempo ID de una obra, vuelve a ubicar
--     las filas del Tempo ID anterior y del nuevo.
--   Un traslado explícito (unificar_obras) no se recalcula.
--
-- fn_unificar_uncontrolled: el valor "UNCONTROLLED DUP" de la tabla principal. La obra se unifica con la que tiene
-- exactamente el Track - Artista indicado y queda una sola, UNCONTROLLED.
-- Idempotente: se aplica en cada arranque (db/mejoras.sh).
-- =====================================================================
SET search_path = public;

ALTER TABLE public.territory_bo_report ADD COLUMN IF NOT EXISTS en_espera boolean NOT NULL DEFAULT false;
ALTER TABLE public.territory_tempo_report ADD COLUMN IF NOT EXISTS en_espera boolean NOT NULL DEFAULT false;
ALTER TABLE public.territory_control ADD COLUMN IF NOT EXISTS en_espera boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.territory_bo_report.en_espera IS
    'Ninguna obra tiene hoy este Tempo ID: la fila queda oculta hasta que una obra lo reciba.';

-- La obra que hoy tiene un Tempo ID numérico (NULL si ninguna).
CREATE OR REPLACE FUNCTION public.fn_obra_del_tempo(p_tempo text)
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    select id from tracks_master
    where tempo_id = p_tempo and tempo_id ~ '^[0-9]+$' and deleted_at is null
    limit 1;
$function$;

CREATE OR REPLACE FUNCTION public.trg_reporte_sigue_tempo()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_obra uuid;
begin
    if tg_op = 'UPDATE' and new.track_master_id is distinct from old.track_master_id then
        return new;   -- traslado explícito (unificación de obras)
    end if;
    v_obra := fn_obra_del_tempo(new.tempo_id);
    if v_obra is not null then
        if v_obra <> new.track_master_id then
            -- El ticket de ese territorio acompaña a los datos de BO, si la obra destino no tiene uno propio y en la
            -- obra anterior no quedan otros datos de BO de ese territorio.
            if tg_table_name = 'territory_bo_report'
               and not exists (select 1 from territory_seguimiento s where s.track_master_id = v_obra and s.pais_code = new.pais_code)
               and not exists (select 1 from territory_bo_report b where b.track_master_id = new.track_master_id
                               and b.pais_code = new.pais_code and b.id <> new.id and b.deleted_at is null) then
                update territory_seguimiento set track_master_id = v_obra
                where track_master_id = new.track_master_id and pais_code = new.pais_code;
            end if;
            new.track_master_id := v_obra;
        end if;
        if new.en_espera then
            new.en_espera := false;
            new.deleted_at := null;
        end if;
    elsif not new.en_espera and new.deleted_at is null
          and (select tempo_id from tracks_master where id = new.track_master_id) is distinct from new.tempo_id then
        new.en_espera := true;
        new.deleted_at := now();
    end if;
    return new;
end;
$function$;

-- "trg_b0_": antes que los demás BEFORE (se ejecutan por orden alfabético), así el estado de trabajo se calcula con la
-- obra correcta.
DROP TRIGGER IF EXISTS trg_b0_bo_report_sigue_tempo ON public.territory_bo_report;
CREATE TRIGGER trg_b0_bo_report_sigue_tempo BEFORE INSERT OR UPDATE ON public.territory_bo_report
    FOR EACH ROW EXECUTE FUNCTION trg_reporte_sigue_tempo();
DROP TRIGGER IF EXISTS trg_b0_tempo_report_sigue_tempo ON public.territory_tempo_report;
CREATE TRIGGER trg_b0_tempo_report_sigue_tempo BEFORE INSERT OR UPDATE ON public.territory_tempo_report
    FOR EACH ROW EXECUTE FUNCTION trg_reporte_sigue_tempo();
DROP TRIGGER IF EXISTS trg_b0_control_sigue_tempo ON public.territory_control;
CREATE TRIGGER trg_b0_control_sigue_tempo BEFORE INSERT OR UPDATE ON public.territory_control
    FOR EACH ROW EXECUTE FUNCTION trg_reporte_sigue_tempo();

-- Al cambiar el Tempo ID de una obra: las filas del Tempo ID anterior y del nuevo se vuelven a ubicar (primero Tempo,
-- después BO, para que el estado de trabajo compare con los datos de Tempo de la obra nueva).
CREATE OR REPLACE FUNCTION public.trg_tracks_master_reportes_tempo()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_ids text[];
begin
    if tg_op = 'UPDATE' and new.tempo_id is not distinct from old.tempo_id then
        return null;
    end if;
    select array_agg(x) into v_ids
    from unnest(array[case when tg_op = 'UPDATE' then old.tempo_id end, new.tempo_id]) x
    where x ~ '^[0-9]+$';
    if v_ids is null then
        return null;
    end if;
    update territory_tempo_report set tempo_id = tempo_id where tempo_id = any(v_ids);
    update territory_control set tempo_id = tempo_id where tempo_id = any(v_ids);
    update territory_bo_report set tempo_id = tempo_id where tempo_id = any(v_ids);
    return null;
end;
$function$;
DROP TRIGGER IF EXISTS trg_ai_tracks_master_reportes_tempo ON public.tracks_master;
CREATE TRIGGER trg_ai_tracks_master_reportes_tempo AFTER INSERT OR UPDATE OF tempo_id ON public.tracks_master
    FOR EACH ROW EXECUTE FUNCTION trg_tracks_master_reportes_tempo();

-- El Tempo ID de la obra se copia a sus charts (territory_tracks). A territory_control ya no: sus filas son de un Tempo
-- ID y siguen a la obra que lo tenga (trigger de arriba); renombrarlas mezclaba datos de dos Tempo ID.
CREATE OR REPLACE FUNCTION public.trg_sync_tempo_id_to_territory()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
    if new.tempo_id is distinct from old.tempo_id then
        update territory_tracks set tempo_id = new.tempo_id, updated_at = now()
        where track_master_id = new.id;
    end if;
    return new;
end;
$function$;

-- Datos ya cargados que quedaron en una obra que hoy tiene otro Tempo ID: pasan a la obra que lo tiene o quedan en espera.
UPDATE public.territory_tempo_report r SET tempo_id = r.tempo_id
WHERE r.deleted_at IS NULL AND NOT EXISTS (SELECT 1 FROM public.tracks_master tm
    WHERE tm.id = r.track_master_id AND tm.tempo_id = r.tempo_id AND tm.deleted_at IS NULL);
UPDATE public.territory_control r SET tempo_id = r.tempo_id
WHERE r.deleted_at IS NULL AND NOT EXISTS (SELECT 1 FROM public.tracks_master tm
    WHERE tm.id = r.track_master_id AND tm.tempo_id = r.tempo_id AND tm.deleted_at IS NULL);
UPDATE public.territory_bo_report r SET tempo_id = r.tempo_id
WHERE r.deleted_at IS NULL AND NOT EXISTS (SELECT 1 FROM public.tracks_master tm
    WHERE tm.id = r.track_master_id AND tm.tempo_id = r.tempo_id AND tm.deleted_at IS NULL);

-- ---------------------------------------------------------------- UNCONTROLLED DUP
-- La obra p_track_id es la misma canción que la que tiene exactamente el Track - Artista p_track_artista: se unifican
-- (charts, streams, reportes y descargas, como en la unificación por Tempo ID) y queda una sola, UNCONTROLLED, con el
-- nombre de la indicada. Las próximas cargas con el nombre de p_track_id van a esa obra. Devuelve el nombre que queda.
CREATE OR REPLACE FUNCTION public.fn_unificar_uncontrolled(p_track_id uuid, p_track_artista text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v text := nullif(trim(coalesce(p_track_artista, '')), '');
    o record;
    d record;
begin
    if coalesce(fn_app_role(), '') not in ('admin', 'usuario_estandar') then
        raise exception 'Sin permiso para modificar obras.' using errcode = 'insufficient_privilege';
    end if;
    if v is null then
        raise exception 'Pegá el Track - Artista de la obra con la que se unifica, tal como figura en la tabla principal.'
            using errcode = '22023';
    end if;
    select * into o from tracks_master where id = p_track_id and deleted_at is null;
    if not found then
        raise exception 'La obra no existe o fue eliminada.';
    end if;
    select * into d from tracks_master
    where deleted_at is null and id <> p_track_id
      and lower(fn_normalize_text(track_artist_concat)) = lower(fn_normalize_text(v))
    order by created_at
    limit 1;
    if not found then
        if lower(fn_normalize_text(o.track_artist_concat)) = lower(fn_normalize_text(v)) then
            raise exception 'Se pegó el nombre de esta misma obra. Pegá el Track - Artista de la otra obra.' using errcode = '22023';
        end if;
        raise exception 'No se encontró en la tabla principal la obra "%". Copiá el Track - Artista tal como figura en la tabla.', v
            using errcode = '22023';
    end if;
    if coalesce(o.tempo_id, '') ~ '^[0-9]+$' or coalesce(d.tempo_id, '') ~ '^[0-9]+$' then
        raise exception 'La obra "%" tiene el Tempo ID %. UNCONTROLLED DUP es para obras sin Tempo ID numérico; si es la misma canción, ingresá ese número para unificarlas.',
            case when coalesce(o.tempo_id, '') ~ '^[0-9]+$' then o.track_artist_concat else d.track_artist_concat end,
            case when coalesce(o.tempo_id, '') ~ '^[0-9]+$' then o.tempo_id else d.tempo_id end
            using errcode = '22023';
    end if;
    perform unificar_obras(o.id, d.id, 'UNCONTROLLED');
    update tracks_master set tempo_id = 'UNCONTROLLED', estado_bo = 'uncontrolled' where id = d.id;
    return d.track_artist_concat;
end;
$function$;
REVOKE ALL ON FUNCTION public.fn_unificar_uncontrolled(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_unificar_uncontrolled(uuid, text) TO authenticated;
