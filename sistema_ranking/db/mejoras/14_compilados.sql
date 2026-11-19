-- =====================================================================
-- Mejora propia (no viene de Supabase): compilados (pedido del usuario, 11/11/2026).
--
-- Un chart a veces trae varias canciones en un solo nombre: "A Un Milimetro De Mi / Tan Natural - Q' Lokura, Sergio
-- Torres". Quien identifica la obra ingresa los Tempo ID de cada canción separados por "/" (123/456) y la obra se
-- separa en una por canción ("A Un Milimetro De Mi - Q' Lokura, Sergio Torres" con 123 y "Tan Natural - ..." con 456):
--   * Si la canción ya existe (con ese Tempo ID, o con ese título y artista), se usa la existente: no se repite.
--   * Los charts del compilado pasan a cada canción con los streams divididos en partes iguales (el resto, de a uno, a
--     las primeras), por semana, país y plataforma, como streams de ese nombre (territory_tracks_partes).
--   * El nombre del compilado queda en compilado_partes (tabla en 04): las cargas siguientes con ese nombre reparten
--     los streams entre sus canciones (fn_upsert_ranking_row) y nunca vuelven a crear la obra.
-- Idempotente: se aplica en cada arranque (db/mejoras.sh).
-- =====================================================================
SET search_path = public;

-- Los Tempo ID de un compilado ("123/456", con espacios o marcadores como UNCONTROLLED), estandarizados; NULL si el
-- valor no tiene "/". Error claro si alguno no es válido, si hay menos de dos o si un número se repite.
CREATE OR REPLACE FUNCTION public.fn_tempo_compilado(p_valor text)
 RETURNS text[]
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
    v text;
    r text[] := '{}';
begin
    if p_valor is null or position('/' in p_valor) = 0 then
        return null;
    end if;
    foreach v in array regexp_split_to_array(trim(p_valor), '\s*/\s*') loop
        v := fn_tempo_estandar(v);
        if v is null or v = '' then
            raise exception 'Compilado no válido: "%". Ingresá el Tempo ID de cada canción separados por "/", por ejemplo 123/456.',
                trim(p_valor) using errcode = '22023';
        end if;
        r := array_append(r, v);
    end loop;
    if cardinality(r) < 2 then
        raise exception 'Compilado no válido: "%". Un compilado lleva al menos dos Tempo ID, por ejemplo 123/456.', trim(p_valor)
            using errcode = '22023';
    end if;
    if (select count(x) <> count(distinct x) from unnest(r) x where x ~ '^[0-9]+$') then
        raise exception 'Compilado no válido: "%". Un mismo Tempo ID figura dos veces.', trim(p_valor) using errcode = '22023';
    end if;
    return r;
end;
$function$;

-- Separa la obra p_obra (un compilado) en una obra por canción, con los Tempo ID de p_valor ("123/456"). Devuelve la
-- cantidad de canciones. La llaman fn_asignar_tempo_id (tabla principal) y la carga CSV de Tempo IDs. Sin el prefijo
-- fn_ a propósito: la API solo publica funciones fn_*, así que no se puede llamar directamente.
CREATE OR REPLACE FUNCTION public.separar_compilado(p_obra uuid, p_valor text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_ids text[] := fn_tempo_compilado(p_valor);
    c record;
    v_titulos text[];
    v_n integer;
    v_t text;
    v_parte uuid;
    v_por_numero uuid;
    v_por_nombre uuid;
    v_partes uuid[] := '{}';
    v_tempo_parte text;
    v_tt uuid;
    v_c text;
    r record;
begin
    if coalesce(fn_app_role(), '') not in ('admin', 'usuario_estandar') then
        raise exception 'Sin permiso para modificar obras.' using errcode = 'insufficient_privilege';
    end if;
    if v_ids is null then
        raise exception 'Compilado no válido: ingresá el Tempo ID de cada canción separados por "/".' using errcode = '22023';
    end if;
    select * into c from tracks_master where id = p_obra and deleted_at is null;
    if not found then
        raise exception 'La obra no existe o fue eliminada.';
    end if;
    v_titulos := regexp_split_to_array(trim(c.track_name_raw), '\s*/\s*');
    v_n := cardinality(v_ids);
    if cardinality(v_titulos) <> v_n or exists (select 1 from unnest(v_titulos) x where trim(x) = '') then
        raise exception 'Para separar un compilado, el título tiene que tener una canción por cada Tempo ID, separadas por "/": "%" tiene % y se ingresaron %.',
            c.track_name_raw, cardinality(v_titulos), v_n using errcode = '22023';
    end if;
    perform set_config('app.allow_hard_delete', 'true', true);

    -- Una obra por canción: la que ya tiene ese Tempo ID, la que tiene ese título y artista, o una nueva.
    for i in 1 .. v_n loop
        v_t := trim(v_titulos[i]);
        v_por_numero := null; v_por_nombre := null;
        if v_ids[i] ~ '^[0-9]+$' then
            select id into v_por_numero from tracks_master
            where tempo_id = v_ids[i] and deleted_at is null and id <> p_obra;
        end if;
        select id into v_por_nombre from tracks_master
        where deleted_at is null and id <> p_obra
          and lower(track_name_clean) = lower(fn_normalize_text(v_t)) and lower(artist_name_clean) = lower(c.artist_name_clean);
        if v_por_numero is not null then
            v_parte := v_por_numero;
            if v_por_nombre is not null and v_por_nombre <> v_por_numero then
                perform fusionar_obras(v_por_nombre, v_por_numero);   -- con otro número no las une
            end if;
        elsif v_por_nombre is not null then
            v_parte := v_por_nombre;
            select tempo_id into v_tempo_parte from tracks_master where id = v_parte;
            if v_tempo_parte ~ '^[0-9]+$' and v_ids[i] ~ '^[0-9]+$' and v_tempo_parte <> v_ids[i] then
                raise exception 'La obra "%" ya tiene el Tempo ID %; en el compilado se ingresó %.',
                    (select track_artist_concat from tracks_master where id = v_parte), v_tempo_parte, v_ids[i]
                    using errcode = '22023';
            end if;
        else
            insert into tracks_master (track_name_raw, artist_name_raw, estado_bo)
            values (v_t, c.artist_name_raw, 'uncontrolled')
            returning id into v_parte;
        end if;
        if v_parte = any(v_partes) then
            raise exception 'Dos canciones del compilado "%" corresponden a la misma obra.', c.track_artist_concat
                using errcode = '22023';
        end if;
        -- El Tempo ID de la canción; un número nunca se reemplaza por un marcador.
        update tracks_master
        set tempo_id = v_ids[i],
            estado_bo = case when v_ids[i] ~ '^[0-9]+$' then 'ok'::estado_bo_enum
                             when v_ids[i] = 'UNCONTROLLED' then 'uncontrolled'::estado_bo_enum else estado_bo end
        where id = v_parte and not (coalesce(tempo_id, '') ~ '^[0-9]+$' and v_ids[i] !~ '^[0-9]+$');
        v_partes := array_append(v_partes, v_parte);
    end loop;

    -- Charts: cada nombre del compilado (el suyo y los de obras que se le habían unificado) pasa a cada canción con los
    -- streams divididos en partes iguales.
    foreach v_parte in array v_partes loop
        perform fn_partes_iniciales(v_parte);
    end loop;
    perform fn_partes_iniciales(p_obra);
    for r in select tt.pais_code, tt.snapshot_date, tt.platform, tt.peak_rank, tt.previous_rank, tt.weeks_on_chart,
                    tt.source, tt.uri, tt.weekly_growth, p.clave, p.rank, p.streams
             from territory_tracks tt join territory_tracks_partes p on p.territory_track_id = tt.id
             where tt.track_master_id = p_obra and tt.deleted_at is null
    loop
        for i in 1 .. v_n loop
            insert into territory_tracks (track_master_id, tempo_id, pais_code, rank, peak_rank, previous_rank,
                                          weeks_on_chart, streams, source, uri, platform, weekly_growth, snapshot_date)
            values (v_partes[i], (select tempo_id from tracks_master where id = v_partes[i]), r.pais_code, r.rank,
                    r.peak_rank, r.previous_rank, r.weeks_on_chart, null, r.source, r.uri, r.platform, r.weekly_growth,
                    r.snapshot_date)
            on conflict (track_master_id, pais_code, snapshot_date, platform) do update set deleted_at = null
            returning id into v_tt;
            insert into territory_tracks_partes (territory_track_id, clave, rank, streams)
            values (v_tt, r.clave, r.rank, r.streams / v_n + case when i <= r.streams % v_n then 1 else 0 end)
            on conflict (territory_track_id, clave) do update set rank = excluded.rank, streams = excluded.streams;
        end loop;
    end loop;
    update territory_tracks tt set streams = x.streams, rank = x.rank
    from (select p.territory_track_id, sum(p.streams) as streams, min(p.rank) as rank
          from territory_tracks_partes p join territory_tracks t on t.id = p.territory_track_id
          where t.track_master_id = any(v_partes) group by 1) x
    where tt.id = x.territory_track_id and (tt.streams is distinct from x.streams or tt.rank is distinct from x.rank);

    -- Los nombres del compilado quedan registrados: las próximas cargas reparten los streams entre sus canciones.
    for v_c in select lower(c.track_artist_concat) union select a.clave from obra_alias a where a.track_master_id = p_obra loop
        delete from compilado_partes where clave = v_c;
        insert into compilado_partes (clave, parte, track_master_id, track_raw, artist_raw, tempo_ids)
        select v_c, o.n, o.id, c.track_name_raw, c.artist_name_raw, array_to_string(v_ids, '/')
        from unnest(v_partes) with ordinality as o(id, n);
    end loop;
    delete from obra_alias where track_master_id = p_obra;

    -- El compilado deja de existir como obra (lo que tenía por territorio corresponde a sus canciones).
    delete from territory_tracks where track_master_id = p_obra;
    delete from territory_bo_report where track_master_id = p_obra;
    delete from territory_tempo_report where track_master_id = p_obra;
    delete from territory_control where track_master_id = p_obra;
    delete from territory_seguimiento where track_master_id = p_obra;
    delete from tracks_master where id = p_obra;
    return v_n;
end;
$function$;
REVOKE ALL ON FUNCTION public.separar_compilado(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.separar_compilado(uuid, text) TO authenticated;
