-- =====================================================================
-- Mejora propia (no viene de Supabase): obras con el Tempo ID duplicado en Tempo (pedido del usuario, 16/11/2026).
--
-- "123-456" en la tabla principal (o en la columna tempo_id de la carga de Tempo IDs): la obra queda con el Tempo ID
-- principal 123 y el duplicado 456 (tabla tempo_duplicado, en 00). Desde ese momento se siguen por separado: en la
-- tabla por territorio la obra aparece una vez por cada Tempo ID, cada uno con sus datos de BO y Tempo (que siguen al
-- Tempo ID, 15) y su ticket, con *dup* y el estado DUPLICADA. El reporte BO lleva una línea por cada Tempo ID. Si después
-- se unifican en Tempo, se escribe un solo Tempo ID y la obra deja de tener duplicados.
-- Idempotente: se aplica en cada arranque (db/mejoras.sh).
-- =====================================================================
SET search_path = public;

-- Asigna los Tempo ID "123-456" a la obra: el primero es el principal y los demás, duplicados. Ninguno puede ser de
-- otra obra. Devuelve cuántos Tempo ID quedaron. La llaman fn_asignar_tempo_id y la carga de Tempo IDs (sin prefijo
-- fn_: la API no la publica).
CREATE OR REPLACE FUNCTION public.asignar_tempo_duplicado(p_obra uuid, p_valor text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_ids text[] := regexp_split_to_array(trim(coalesce(p_valor, '')), '\s*-\s*');
    v text;
    v_otra text;
begin
    if coalesce(fn_app_role(), '') not in ('admin', 'usuario_estandar') then
        raise exception 'Sin permiso para modificar obras.' using errcode = 'insufficient_privilege';
    end if;
    if cardinality(v_ids) < 2 or exists (select 1 from unnest(v_ids) x where x !~ '^[0-9]+$') then
        raise exception 'Tempo ID duplicado no válido: "%". Ingresá los dos números separados por un guion, por ejemplo 123-456.',
            trim(coalesce(p_valor, '')) using errcode = '22023';
    end if;
    if (select count(distinct x) from unnest(v_ids) x) <> cardinality(v_ids) then
        raise exception 'Tempo ID duplicado no válido: "%". El mismo número figura dos veces.', trim(p_valor) using errcode = '22023';
    end if;
    if not exists (select 1 from tracks_master where id = p_obra and deleted_at is null) then
        raise exception 'La obra no existe o fue eliminada.';
    end if;
    foreach v in array v_ids loop
        select tm.track_artist_concat into v_otra from tracks_master tm
        where tm.tempo_id = v and tm.id <> p_obra and tm.deleted_at is null;
        if v_otra is null then
            select tm.track_artist_concat into v_otra from tempo_duplicado d join tracks_master tm on tm.id = d.track_master_id
            where d.tempo_id = v and d.track_master_id <> p_obra;
        end if;
        if v_otra is not null then
            raise exception 'El Tempo ID % ya está asignado a "%".', v, v_otra using errcode = 'unique_violation';
        end if;
    end loop;
    -- Primero los duplicados que dejan de serlo; después el principal; al final los duplicados nuevos (así cada fila de
    -- reporte se ubica en la obra correcta en cada paso).
    delete from tempo_duplicado where track_master_id = p_obra and tempo_id <> all (v_ids[2:]);
    update tracks_master set tempo_id = v_ids[1], estado_bo = 'ok'
    where id = p_obra and tempo_id is distinct from v_ids[1];
    insert into tempo_duplicado (tempo_id, track_master_id, orden)
    select x, p_obra, n from unnest(v_ids[2:]) with ordinality as u(x, n)
    on conflict (tempo_id) do update set orden = excluded.orden;
    return cardinality(v_ids);
end;
$function$;
REVOKE ALL ON FUNCTION public.asignar_tempo_duplicado(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.asignar_tempo_duplicado(uuid, text) TO authenticated;

-- La obra vuelve a tener un solo Tempo ID (por ejemplo, cuando los duplicados se unificaron en Tempo).
CREATE OR REPLACE FUNCTION public.quitar_tempos_duplicados(p_obra uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    delete from tempo_duplicado where track_master_id = p_obra;
$function$;
REVOKE ALL ON FUNCTION public.quitar_tempos_duplicados(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quitar_tempos_duplicados(uuid) TO authenticated;

-- Al agregar o quitar un duplicado, sus datos de BO y Tempo se vuelven a ubicar (pasan a la obra o quedan en espera).
CREATE OR REPLACE FUNCTION public.trg_tempo_duplicado_reportes()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_ids text[] := array_remove(array[case when tg_op <> 'INSERT' then old.tempo_id end,
                                       case when tg_op <> 'DELETE' then new.tempo_id end], null);
begin
    update territory_tempo_report set tempo_id = tempo_id where tempo_id = any(v_ids);
    update territory_control set tempo_id = tempo_id where tempo_id = any(v_ids);
    update territory_bo_report set tempo_id = tempo_id where tempo_id = any(v_ids);
    return null;
end;
$function$;
DROP TRIGGER IF EXISTS trg_ai_tempo_duplicado_reportes ON public.tempo_duplicado;
CREATE TRIGGER trg_ai_tempo_duplicado_reportes AFTER INSERT OR UPDATE OR DELETE ON public.tempo_duplicado
    FOR EACH ROW EXECUTE FUNCTION trg_tempo_duplicado_reportes();

-- ---------------------------------------------------------------- carga de reportes con un Tempo ID duplicado
-- Las cargas del Reporte BackOffice, del Reporte Tempo Control y de controles buscaban la obra solo por su Tempo ID
-- principal: con un duplicado respondían "no existe en la tabla principal". Son las de db/03 con la búsqueda ampliada.
CREATE OR REPLACE FUNCTION public.fn_upsert_bo_report_row(p_tempo_id text, p_pais_code pais_code_enum, p_bo_id text, p_ca text, p_bo_status text, p_reclamos text, p_mech_bo numeric)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare
    v_master_id uuid;
    v_tempo_id  text;
    v_bo_id     text;
    v_row_id    uuid;
begin
    select tm.id, tm.tempo_id into v_master_id, v_tempo_id
    from tracks_master tm
    where fn_norm_tempo_id(tm.tempo_id) = fn_norm_tempo_id(p_tempo_id)
      and tm.deleted_at is null
    limit 1;

    if v_master_id is null then   -- Tempo ID duplicado de una obra (17_tempo_duplicado.sql)
        select d.track_master_id, d.tempo_id into v_master_id, v_tempo_id
        from tempo_duplicado d join tracks_master tm on tm.id = d.track_master_id and tm.deleted_at is null
        where fn_norm_tempo_id(d.tempo_id) = fn_norm_tempo_id(p_tempo_id)
        limit 1;
    end if;

    if v_master_id is null then
        raise exception 'tempo_id % no existe en la tabla principal.', p_tempo_id;
    end if;

    -- BO ID sin ceros de relleno (solo si es numérico).
    v_bo_id := case
        when trim(coalesce(p_bo_id, '')) ~ '^[0-9]+$' then ltrim(trim(p_bo_id), '0')
        else nullif(trim(p_bo_id), '')
    end;

    insert into territory_bo_report (track_master_id, tempo_id, pais_code, bo_id, ca, bo_status, reclamos, mech_bo)
    values (v_master_id, v_tempo_id, p_pais_code, v_bo_id, p_ca, p_bo_status, p_reclamos, p_mech_bo)
    on conflict (tempo_id, pais_code)
    do update set
        bo_id = excluded.bo_id, ca = excluded.ca, bo_status = excluded.bo_status,
        reclamos = excluded.reclamos, mech_bo = excluded.mech_bo,
        deleted_at = null, updated_at = now()
        -- estado_trabajo queda afuera a propósito: no se pisa.
    returning id into v_row_id;

    return v_row_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_upsert_tempo_report_row(p_tempo_id text, p_pais_code pais_code_enum, p_created_date date, p_perf_pc numeric, p_mech_pc numeric, p_sync_pc numeric, p_publishers text, p_contratos text, p_estado_obra text, p_song_title text, p_perf_raw text, p_mech_raw text, p_sync_raw text, p_originating_office text)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare
    v_master_id uuid;
    v_tempo_id  text;
    v_row_id    uuid;
begin
    select tm.id, tm.tempo_id into v_master_id, v_tempo_id
    from tracks_master tm
    where fn_norm_tempo_id(tm.tempo_id) = fn_norm_tempo_id(p_tempo_id)
      and tm.deleted_at is null
    limit 1;

    if v_master_id is null then   -- Tempo ID duplicado de una obra (17_tempo_duplicado.sql)
        select d.track_master_id, d.tempo_id into v_master_id, v_tempo_id
        from tempo_duplicado d join tracks_master tm on tm.id = d.track_master_id and tm.deleted_at is null
        where fn_norm_tempo_id(d.tempo_id) = fn_norm_tempo_id(p_tempo_id)
        limit 1;
    end if;

    if v_master_id is null then
        raise exception 'tempo_id % no existe en la tabla principal.', p_tempo_id;
    end if;

    insert into territory_tempo_report (
        track_master_id, tempo_id, pais_code, created_date, perf_pc, mech_pc, sync_pc,
        publishers, contratos, estado_obra, song_title, perf_raw, mech_raw, sync_raw,
        originating_office
    ) values (
        v_master_id, v_tempo_id, p_pais_code, p_created_date, p_perf_pc, p_mech_pc, p_sync_pc,
        p_publishers, p_contratos, p_estado_obra, p_song_title, p_perf_raw, p_mech_raw, p_sync_raw,
        p_originating_office
    )
    on conflict (tempo_id, pais_code)
    do update set
        created_date = excluded.created_date,
        perf_pc = excluded.perf_pc, mech_pc = excluded.mech_pc, sync_pc = excluded.sync_pc,
        publishers = excluded.publishers, contratos = excluded.contratos,
        estado_obra = excluded.estado_obra, song_title = excluded.song_title,
        perf_raw = excluded.perf_raw, mech_raw = excluded.mech_raw, sync_raw = excluded.sync_raw,
        originating_office = excluded.originating_office,
        deleted_at = null, updated_at = now()
    returning id into v_row_id;

    return v_row_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_upsert_tempo_report_row(p_tempo_id text, p_pais_code pais_code_enum, p_created_date date, p_perf_pc numeric, p_mech_pc numeric, p_sync_pc numeric, p_publishers text, p_contratos text, p_estado_obra text, p_song_title text)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare
    v_master_id uuid;
    v_tempo_id  text;
    v_row_id    uuid;
begin
    select tm.id, tm.tempo_id into v_master_id, v_tempo_id
    from tracks_master tm
    where fn_norm_tempo_id(tm.tempo_id) = fn_norm_tempo_id(p_tempo_id)
      and tm.deleted_at is null
    limit 1;

    if v_master_id is null then   -- Tempo ID duplicado de una obra (17_tempo_duplicado.sql)
        select d.track_master_id, d.tempo_id into v_master_id, v_tempo_id
        from tempo_duplicado d join tracks_master tm on tm.id = d.track_master_id and tm.deleted_at is null
        where fn_norm_tempo_id(d.tempo_id) = fn_norm_tempo_id(p_tempo_id)
        limit 1;
    end if;

    if v_master_id is null then
        raise exception 'tempo_id % no existe en la tabla principal.', p_tempo_id;
    end if;

    insert into territory_tempo_report (
        track_master_id, tempo_id, pais_code, created_date, perf_pc, mech_pc,
        sync_pc, publishers, contratos, estado_obra, song_title
    ) values (
        v_master_id, v_tempo_id, p_pais_code, p_created_date, p_perf_pc, p_mech_pc,
        p_sync_pc, p_publishers, p_contratos, p_estado_obra, p_song_title
    )
    on conflict (tempo_id, pais_code)
    do update set
        created_date = excluded.created_date, perf_pc = excluded.perf_pc,
        mech_pc = excluded.mech_pc, sync_pc = excluded.sync_pc,
        publishers = excluded.publishers, contratos = excluded.contratos,
        estado_obra = excluded.estado_obra, song_title = excluded.song_title,
        deleted_at = null, updated_at = now()
    returning id into v_row_id;

    return v_row_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_upsert_control_row(p_tempo_id text, p_pais_code pais_code_enum, p_percent_ctrl numeric, p_collect_mec numeric, p_collect_ejec numeric, p_control text, p_cwr text, p_nota text)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare v_master_id uuid; v_row_id uuid;
begin
    select id into v_master_id from tracks_master where tempo_id = p_tempo_id and deleted_at is null;
    if v_master_id is null then   -- Tempo ID duplicado de una obra (17_tempo_duplicado.sql)
        select d.track_master_id into v_master_id
        from tempo_duplicado d join tracks_master tm on tm.id = d.track_master_id and tm.deleted_at is null
        where d.tempo_id = p_tempo_id;
    end if;
    if v_master_id is null then
        raise exception 'tempo_id % no existe en la tabla principal. Cargalo ahí primero.', p_tempo_id;
    end if;

    insert into territory_control (track_master_id, tempo_id, pais_code, percent_ctrl, collect_mec, collect_ejec, control, cwr, nota)
    values (v_master_id, p_tempo_id, p_pais_code, p_percent_ctrl, p_collect_mec, p_collect_ejec, p_control, p_cwr, p_nota)
    on conflict (tempo_id, pais_code)
    do update set
        percent_ctrl = excluded.percent_ctrl, collect_mec = excluded.collect_mec, collect_ejec = excluded.collect_ejec,
        control = excluded.control, cwr = excluded.cwr, nota = excluded.nota,
        deleted_at = null, updated_at = now()
    returning id into v_row_id;

    return v_row_id;
end;
$function$;
