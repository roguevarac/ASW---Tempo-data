-- =====================================================================
-- Mejora propia (no viene de Supabase): uso diario en la empresa.
--
--  * Sesiones en la base: cerrar sesión las anula en el servidor; mientras se usa la aplicación la sesión se renueva
--    sola y vence por inactividad (SESSION_HOURS sin usarla), no a las 8 horas del ingreso.
--  * Cambio de contraseña desde la pantalla de ingreso, y restablecimiento con un código si se olvidó.
--  * Carga de un archivo en una sola transacción: los datos y su registro en el historial quedan juntos o no queda
--    nada (antes se mandaba de a 250 filas y un corte dejaba el archivo cargado a medias y sin registro).
--  * Tempo ID repetido: la obra se unifica con la que ya tenía ese Tempo ID (lo que buscaba fn_set_tempo_id, que
--    nunca llegaba a hacerlo porque la restricción UNIQUE rechazaba el cambio antes).
--  * Descarga de la tabla por territorio con todos los filtros de la pantalla.
--
-- Idempotente: se aplica en cada arranque (db/mejoras.sh).
-- =====================================================================
SET search_path = public;

-- ---------------------------------------------------------------- sesiones
CREATE TABLE IF NOT EXISTS auth.sesiones (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    creada     timestamptz NOT NULL DEFAULT now(),
    ultimo_uso timestamptz NOT NULL DEFAULT now(),
    cerrada    timestamptz
);
CREATE INDEX IF NOT EXISTS ix_sesiones_usuario ON auth.sesiones (user_id) WHERE cerrada IS NULL;
COMMENT ON TABLE auth.sesiones IS 'Sesiones abiertas de la aplicación. La API valida cada pedido contra esta tabla.';

-- Abre una sesión para un usuario recién validado (la llama la API al ingresar). Limpia las sesiones viejas.
CREATE OR REPLACE FUNCTION auth.abrir_sesion(p_user uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
    DELETE FROM auth.sesiones WHERE coalesce(cerrada, ultimo_uso) < now() - interval '30 days';
    INSERT INTO auth.sesiones (user_id) VALUES (p_user) RETURNING id INTO v_id;
    RETURN v_id;
END $$;

-- La API la consulta en cada pedido: la sesión vale si no se cerró, no pasó p_inactividad sin usarse y el usuario no
-- está bloqueado ni borrado. Registra el uso (como mucho una escritura por minuto).
CREATE OR REPLACE FUNCTION auth.sesion_valida(p_sesion uuid, p_user uuid, p_inactividad interval) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uso timestamptz;
BEGIN
    SELECT s.ultimo_uso INTO v_uso
    FROM auth.sesiones s JOIN auth.users u ON u.id = s.user_id
    WHERE s.id = p_sesion AND s.user_id = p_user AND s.cerrada IS NULL
      AND (u.banned_until IS NULL OR u.banned_until < now());
    IF v_uso IS NULL OR v_uso < now() - p_inactividad THEN
        RETURN false;
    END IF;
    IF v_uso < now() - interval '1 minute' THEN
        UPDATE auth.sesiones SET ultimo_uso = now() WHERE id = p_sesion;
    END IF;
    RETURN true;
END $$;

CREATE OR REPLACE FUNCTION auth.cerrar_sesion(p_sesion uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    UPDATE auth.sesiones SET cerrada = now() WHERE id = p_sesion AND cerrada IS NULL;
$$;

-- Contraseñas desde la pantalla de ingreso. Al cambiarla se cierran todas las sesiones del usuario.
DROP FUNCTION IF EXISTS auth.cambiar_clave(uuid, uuid, text, text);   -- versión anterior (desde la aplicación)

CREATE OR REPLACE FUNCTION auth.validar_clave_nueva(p_nueva text) RETURNS void
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF length(coalesce(p_nueva, '')) < 10 THEN
        RAISE EXCEPTION 'La contraseña nueva debe tener al menos 10 caracteres.';
    END IF;
END $$;

-- Cambio con la contraseña actual. Devuelve false si el email o la contraseña actual no son correctos.
CREATE OR REPLACE FUNCTION auth.cambiar_clave(p_email text, p_actual text, p_nueva text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
    PERFORM auth.validar_clave_nueva(p_nueva);
    SELECT u.id INTO v_id FROM auth.users u
    WHERE lower(u.email) = lower(trim(p_email)) AND (u.banned_until IS NULL OR u.banned_until < now())
      AND u.encrypted_password = crypt(coalesce(p_actual, ''), u.encrypted_password);
    IF v_id IS NULL THEN
        RETURN false;
    END IF;
    IF p_nueva = p_actual THEN
        RAISE EXCEPTION 'La contraseña nueva debe ser distinta de la actual.';
    END IF;
    UPDATE auth.users SET encrypted_password = crypt(p_nueva, gen_salt('bf', 10)) WHERE id = v_id;
    UPDATE auth.sesiones SET cerrada = now() WHERE user_id = v_id AND cerrada IS NULL;
    RETURN true;
END $$;

-- Contraseña olvidada: quien administra el sistema genera un código de un solo uso (ranking.sh usuarios), válido 30
-- minutos y por 5 intentos. Se guarda solo su hash.
CREATE TABLE IF NOT EXISTS auth.codigos_clave (
    user_id     uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    codigo_hash text NOT NULL,
    vence       timestamptz NOT NULL,
    intentos    integer NOT NULL DEFAULT 0
);

CREATE OR REPLACE FUNCTION auth.normalizar_codigo(p_codigo text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT regexp_replace(upper(coalesce(p_codigo, '')), '[^A-Z0-9]', '', 'g')
$$;

-- Uso administrativo (consola o Panel de control): devuelve el código, con formato XXXX-XXXX, válido p_minutos.
-- Reemplaza al anterior del usuario. Para un usuario nuevo sirve de código de activación (elige su contraseña).
DROP FUNCTION IF EXISTS auth.generar_codigo_clave(text);
CREATE OR REPLACE FUNCTION auth.generar_codigo_clave(p_email text, p_minutos integer DEFAULT 30) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_id uuid;
    v_letras text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';   -- sin 0/O ni 1/I, que se confunden
    v_bytes bytea := gen_random_bytes(8);
    v_codigo text := '';
BEGIN
    SELECT id INTO v_id FROM auth.users WHERE lower(email) = lower(trim(p_email));
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'No existe ese usuario.';
    END IF;
    FOR i IN 0..7 LOOP
        v_codigo := v_codigo || substr(v_letras, 1 + get_byte(v_bytes, i) % 32, 1);
    END LOOP;
    INSERT INTO auth.codigos_clave (user_id, codigo_hash, vence)
    VALUES (v_id, encode(digest(v_codigo, 'sha256'), 'hex'), now() + make_interval(mins => greatest(p_minutos, 1)))
    ON CONFLICT (user_id) DO UPDATE SET codigo_hash = excluded.codigo_hash, vence = excluded.vence, intentos = 0;
    RETURN substr(v_codigo, 1, 4) || '-' || substr(v_codigo, 5, 4);
END $$;

-- Restablece la contraseña con el código. Devuelve false si el código no corresponde, venció o se agotaron los
-- intentos. El código sirve una sola vez.
CREATE OR REPLACE FUNCTION auth.restablecer_clave(p_email text, p_codigo text, p_nueva text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c auth.codigos_clave%ROWTYPE;
BEGIN
    PERFORM auth.validar_clave_nueva(p_nueva);
    SELECT k.* INTO c FROM auth.codigos_clave k JOIN auth.users u ON u.id = k.user_id
    WHERE lower(u.email) = lower(trim(p_email));
    IF c.user_id IS NULL OR c.vence < now() OR c.intentos >= 5 THEN
        RETURN false;
    END IF;
    IF c.codigo_hash <> encode(digest(auth.normalizar_codigo(p_codigo), 'sha256'), 'hex') THEN
        UPDATE auth.codigos_clave SET intentos = intentos + 1 WHERE user_id = c.user_id;
        RETURN false;
    END IF;
    UPDATE auth.users SET encrypted_password = crypt(p_nueva, gen_salt('bf', 10)) WHERE id = c.user_id;
    DELETE FROM auth.codigos_clave WHERE user_id = c.user_id;
    UPDATE auth.sesiones SET cerrada = now() WHERE user_id = c.user_id AND cerrada IS NULL;
    RETURN true;
END $$;

REVOKE ALL ON FUNCTION auth.abrir_sesion(uuid), auth.sesion_valida(uuid, uuid, interval), auth.cerrar_sesion(uuid),
    auth.cambiar_clave(text, text, text), auth.generar_codigo_clave(text, integer), auth.restablecer_clave(text, text, text)
    FROM PUBLIC;
GRANT EXECUTE ON FUNCTION auth.abrir_sesion(uuid), auth.cerrar_sesion(uuid), auth.cambiar_clave(text, text, text),
    auth.restablecer_clave(text, text, text) TO authenticator;
GRANT EXECUTE ON FUNCTION auth.sesion_valida(uuid, uuid, interval) TO authenticated, service_role;

-- ---------------------------------------------------------------- carga de un archivo
-- Carga las filas ya interpretadas por el front (mismo formato que las funciones *_batch) y registra la carga en
-- csv_uploads, todo en la misma transacción. Sin formato (archivo ilegible o desconocido) solo registra los avisos. p_errores: los avisos del front (filas descartadas antes de llegar acá).
-- Devuelve updated, created_tracks y errors (los mismos datos que quedan en csv_uploads).
CREATE OR REPLACE FUNCTION public.fn_cargar_archivo(p_formato text, p_filas jsonb, p_archivo text, p_ruta text,
    p_total integer, p_pais pais_code_enum DEFAULT NULL::pais_code_enum, p_errores jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
    v_filas jsonb := coalesce(p_filas, '[]'::jsonb);
    v_errores text[] := array(select jsonb_array_elements_text(coalesce(p_errores, '[]'::jsonb)));
    v_ok integer := 0;
    v_nuevas integer := 0;
    v_clave text;
    v_res jsonb;
    r record;
begin
    if p_formato is not null and p_formato not in ('spotify', 'youtube', 'bo_report', 'tempo_report', 'master_tempo') then
        raise exception 'Tipo de archivo desconocido: %', p_formato;
    end if;
    if p_formato is not null and jsonb_array_length(v_filas) > 0 then
        v_clave := case when p_formato in ('spotify', 'youtube') then 'track_name'
                        when p_formato in ('bo_report', 'tempo_report') then 'tempo_id' end;
        if p_formato in ('spotify', 'youtube') then
            v_res := (select jsonb_agg(to_jsonb(b) order by b.idx) from fn_upsert_ranking_batch(v_filas, p_formato) b);
        elsif p_formato = 'bo_report' then
            v_res := (select jsonb_agg(to_jsonb(b) order by b.idx) from fn_upsert_bo_report_batch(v_filas, p_pais) b);
        elsif p_formato = 'tempo_report' then
            v_res := (select jsonb_agg(to_jsonb(b) order by b.idx) from fn_upsert_tempo_report_batch(v_filas) b);
        else
            v_res := (select jsonb_agg(to_jsonb(b) order by b.idx) from fn_upsert_master_tempo_batch(v_filas) b);
        end if;
        for r in select (e ->> 'idx')::int as idx, coalesce((e ->> 'track_created')::boolean, false) as track_created,
                        e ->> 'error_message' as error_message
                 from jsonb_array_elements(coalesce(v_res, '[]'::jsonb)) e
        loop
            if r.error_message is not null then
                v_errores := v_errores || case when v_clave is null then r.error_message
                    else coalesce(nullif(v_filas -> (r.idx - 1) ->> v_clave, ''), 'fila') || ': ' || r.error_message end;
            else
                v_ok := v_ok + 1;
                if r.track_created then v_nuevas := v_nuevas + 1; end if;
            end if;
        end loop;
    end if;
    insert into csv_uploads (filename, total_rows, created_tracks, updated_rows, error_count, errors, file_path, format)
    values (p_archivo, coalesce(p_total, 0), v_nuevas, v_ok, coalesce(array_length(v_errores, 1), 0),
            to_jsonb(v_errores[1:100]), p_ruta, p_formato);
    return jsonb_build_object('updated', v_ok, 'created_tracks', v_nuevas, 'errors', to_jsonb(v_errores));
end;
$function$;

-- ---------------------------------------------------------------- Tempo ID
-- Valores admitidos: el número de Tempo ID o uno de estos marcadores (pedido del usuario, 27/10/2026). Se aceptan con
-- otras mayúsculas, espacios o sin tilde ("pending espana") y se guardan siempre igual.
CREATE OR REPLACE FUNCTION public.fn_marcadores_tempo()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select array['UNCONTROLLED', 'PENDING ARGENTINA', 'PENDING CHILE', 'PENDING URUGUAY', 'PENDING MIAMI', 'PENDING USA',
                 'PENDING MEXICO', 'PENDING COREA', 'PENDING ESPAÑA'];
$function$;

-- El valor estándar (número o marcador) o NULL si no es válido. Vacío -> ''.
CREATE OR REPLACE FUNCTION public.fn_tempo_estandar(p_valor text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    with v as (select upper(regexp_replace(trim(coalesce(p_valor, '')), '\s+', ' ', 'g')) as v)
    select case when v.v = '' then ''
                when v.v ~ '^[0-9]+$' then v.v
                else (select m from unnest(fn_marcadores_tempo()) m
                      where unaccent(m) = unaccent(v.v) or unaccent(m) = unaccent(replace(v.v, 'PENDIENTE ', 'PENDING ')))
           end
    from v;
$function$;

-- Igual, pero con un error claro si el valor no es válido (lo muestra la pantalla). Vacío -> NULL (quita el Tempo ID).
CREATE OR REPLACE FUNCTION public.fn_valor_tempo(p_valor text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
    v text := fn_tempo_estandar(p_valor);
begin
    if v is null then
        raise exception 'Tempo ID no válido: "%". Ingresá el número o uno de estos valores: %.', trim(p_valor),
            array_to_string(fn_marcadores_tempo(), ', ') using errcode = '22023';
    end if;
    return nullif(v, '');
end;
$function$;

-- Fusión real de obras. Cuando dos obras se unifican, el nombre de la que deja de existir queda como alias de la que
-- queda: las próximas cargas de charts con ese nombre van directo a la obra unificada (no se vuelve a crear).
CREATE TABLE IF NOT EXISTS public.obra_alias (
    clave text PRIMARY KEY,                      -- lower(título limpio || ' - ' || artistas limpios), como track_artist_concat
    track_raw text NOT NULL,
    artist_raw text NOT NULL,
    track_master_id uuid NOT NULL REFERENCES public.tracks_master(id) ON DELETE CASCADE,
    created_at timestamp with time zone NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_obra_alias_track ON public.obra_alias (track_master_id);
-- Streams de cada nombre de una obra unificada en la misma semana, país y plataforma (por ejemplo, dos versiones de la
-- canción en el mismo chart): territory_tracks guarda la suma y el mejor puesto. Volver a cargar el mismo archivo
-- reemplaza la parte de ese nombre, no la suma dos veces.
CREATE TABLE IF NOT EXISTS public.territory_tracks_partes (
    territory_track_id uuid NOT NULL REFERENCES public.territory_tracks(id) ON DELETE CASCADE,
    clave text NOT NULL,
    rank integer,
    streams bigint,
    PRIMARY KEY (territory_track_id, clave)
);
ALTER TABLE public.obra_alias ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.territory_tracks_partes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS obra_alias_select ON public.obra_alias;
CREATE POLICY obra_alias_select ON public.obra_alias AS PERMISSIVE FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS territory_tracks_partes_select ON public.territory_tracks_partes;
CREATE POLICY territory_tracks_partes_select ON public.territory_tracks_partes AS PERMISSIVE FOR SELECT TO authenticated USING (true);
GRANT SELECT ON public.obra_alias, public.territory_tracks_partes TO authenticated;
GRANT ALL ON public.obra_alias, public.territory_tracks_partes TO service_role;

-- Una obra con alias guarda los streams de cada nombre por separado (territory_tracks_partes) en todas sus filas.
CREATE OR REPLACE FUNCTION public.fn_partes_iniciales(p_obra uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    insert into territory_tracks_partes (territory_track_id, clave, rank, streams)
    select tt.id, lower(tm.track_artist_concat), tt.rank, tt.streams
    from territory_tracks tt join tracks_master tm on tm.id = tt.track_master_id
    where tt.track_master_id = p_obra
      and not exists (select 1 from territory_tracks_partes p where p.territory_track_id = tt.id)
    on conflict do nothing;
$function$;

-- Unifica dos obras que son la misma canción (mismo Tempo ID): charts, reportes, controles, tickets y envíos de
-- p_origen pasan a p_destino y p_origen deja de existir. En la misma semana, país y plataforma se suman los streams y
-- queda el mejor puesto; en los reportes por territorio queda lo de p_destino. El nombre de p_origen queda como alias.
-- Interna: la usan fn_asignar_tempo_id (con la confirmación de la persona), la carga de Tempo IDs y la limpieza. Sin
-- el prefijo fn_ a propósito: la API solo publica funciones fn_*, así que no se puede llamar directamente.
CREATE OR REPLACE FUNCTION public.unificar_obras(p_origen uuid, p_destino uuid, p_tempo_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    perform set_config('app.allow_hard_delete', 'true', true);
    -- Alias: el nombre de la obra que deja de existir (y sus alias) apuntan a la que queda.
    insert into obra_alias (clave, track_raw, artist_raw, track_master_id)
    select lower(track_artist_concat), track_name_raw, artist_name_raw, p_destino from tracks_master where id = p_origen
    on conflict (clave) do update set track_master_id = excluded.track_master_id;
    update obra_alias set track_master_id = p_destino where track_master_id = p_origen;
    -- Charts: streams por nombre; la misma semana, país y plataforma se juntan en la fila de p_destino.
    perform fn_partes_iniciales(p_destino);
    perform fn_partes_iniciales(p_origen);
    insert into territory_tracks_partes (territory_track_id, clave, rank, streams)
    select s.id, p.clave, p.rank, p.streams
    from territory_tracks tt
    join territory_tracks s on s.track_master_id = p_destino and s.pais_code = tt.pais_code
         and s.snapshot_date = tt.snapshot_date and s.platform = tt.platform
    join territory_tracks_partes p on p.territory_track_id = tt.id
    where tt.track_master_id = p_origen
    on conflict (territory_track_id, clave) do update set rank = excluded.rank, streams = excluded.streams;
    delete from territory_tracks tt where tt.track_master_id = p_origen and exists (
        select 1 from territory_tracks s where s.track_master_id = p_destino and s.pais_code = tt.pais_code
           and s.snapshot_date = tt.snapshot_date and s.platform = tt.platform);
    update territory_tracks set track_master_id = p_destino, tempo_id = p_tempo_id where track_master_id = p_origen;
    update territory_tracks tt set streams = x.streams, rank = x.rank
    from (select p.territory_track_id, sum(p.streams) as streams, min(p.rank) as rank
          from territory_tracks_partes p join territory_tracks t on t.id = p.territory_track_id
          where t.track_master_id = p_destino group by 1) x
    where tt.id = x.territory_track_id and (tt.streams is distinct from x.streams or tt.rank is distinct from x.rank);
    -- Reportes, controles y tickets por territorio: queda lo de p_destino.
    delete from territory_bo_report t where t.track_master_id = p_origen and exists (
        select 1 from territory_bo_report s where s.track_master_id = p_destino and s.pais_code = t.pais_code);
    update territory_bo_report set track_master_id = p_destino where track_master_id = p_origen;
    delete from territory_tempo_report t where t.track_master_id = p_origen and exists (
        select 1 from territory_tempo_report s where s.track_master_id = p_destino and s.pais_code = t.pais_code);
    update territory_tempo_report set track_master_id = p_destino where track_master_id = p_origen;
    delete from territory_control t where t.track_master_id = p_origen and exists (
        select 1 from territory_control s where s.track_master_id = p_destino and s.pais_code = t.pais_code);
    update territory_control set track_master_id = p_destino where track_master_id = p_origen;
    delete from territory_seguimiento t where t.track_master_id = p_origen and exists (
        select 1 from territory_seguimiento s where s.track_master_id = p_destino and s.pais_code = t.pais_code);
    update territory_seguimiento set track_master_id = p_destino where track_master_id = p_origen;
    insert into envio_obras (envio_id, track_master_id)
        select envio_id, p_destino from envio_obras where track_master_id = p_origen
        on conflict do nothing;
    insert into envio_identificadas (tipo, track_master_id, envio_id)
        select tipo, p_destino, envio_id from envio_identificadas where track_master_id = p_origen
        on conflict do nothing;
    delete from tracks_master where id = p_origen;   -- sus envio_obras y envio_identificadas se borran en cascada
    update tracks_master set estado_bo = 'ok' where id = p_destino and estado_bo <> 'ok';
end;
$function$;
REVOKE ALL ON FUNCTION public.unificar_obras(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.unificar_obras(uuid, uuid, text) TO authenticated;
REVOKE ALL ON FUNCTION public.fn_partes_iniciales(uuid) FROM PUBLIC;

-- Unifica dos obras eligiendo el Tempo ID que queda (el número gana al marcador). Si las dos tienen números distintos
-- no hace nada y devuelve false. Interna (consola, carga de Tempo IDs y limpieza).
CREATE OR REPLACE FUNCTION public.fusionar_obras(p_origen uuid, p_destino uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    t_o text; t_d text; v_tempo text;
begin
    select tempo_id into t_o from tracks_master where id = p_origen;
    select tempo_id into t_d from tracks_master where id = p_destino;
    if t_o ~ '^[0-9]+$' and t_d ~ '^[0-9]+$' and t_o <> t_d then
        return false;
    end if;
    v_tempo := case when t_d ~ '^[0-9]+$' then t_d when t_o ~ '^[0-9]+$' then t_o else coalesce(t_d, t_o) end;
    perform unificar_obras(p_origen, p_destino, v_tempo);
    if v_tempo is distinct from t_d then
        update tracks_master set tempo_id = v_tempo where id = p_destino;
    end if;
    return true;
end;
$function$;
REVOKE ALL ON FUNCTION public.fusionar_obras(uuid, uuid) FROM PUBLIC;

-- Carga de una fila de chart (reemplaza a la original): el nombre de una obra unificada va a la obra que quedó, y en
-- las obras con alias los streams de cada nombre se guardan por separado y se suman.
CREATE OR REPLACE FUNCTION public.fn_upsert_ranking_row(p_track_name text, p_artist_names text, p_pais_code pais_code_enum, p_rank integer, p_peak_rank integer, p_previous_rank integer, p_weeks_on_chart integer, p_streams bigint, p_source text, p_uri text, p_platform text DEFAULT 'spotify'::text, p_weekly_growth numeric DEFAULT NULL::numeric, p_snapshot_date date DEFAULT CURRENT_DATE)
 RETURNS TABLE(territory_id uuid, track_created boolean)
 LANGUAGE plpgsql
AS $function$
declare
    v_master_id uuid; v_tempo_id text; v_created boolean := false; v_territory_id uuid;
    v_artist text := coalesce(nullif(trim(p_artist_names), ''), 'Sin artista');
    v_clave text := lower(fn_normalize_text(p_track_name) || ' - ' || fn_normalize_text(v_artist));
    v_partes boolean;
begin
    select a.track_master_id, tm.tempo_id into v_master_id, v_tempo_id
    from obra_alias a join tracks_master tm on tm.id = a.track_master_id and tm.deleted_at is null
    where a.clave = v_clave;
    if v_master_id is null then
        insert into tracks_master (track_name_raw, artist_name_raw, tempo_id, bo_id, estado_bo)
        values (p_track_name, v_artist, null, null, 'uncontrolled')
        on conflict (lower(track_name_clean), lower(artist_name_clean)) where deleted_at is null
        do update set updated_at = tracks_master.updated_at
        returning id, tempo_id, (xmax = 0) into v_master_id, v_tempo_id, v_created;
    end if;
    v_partes := exists (select 1 from obra_alias a where a.track_master_id = v_master_id);

    insert into territory_tracks (
        track_master_id, tempo_id, pais_code, rank, peak_rank, previous_rank,
        weeks_on_chart, streams, source, uri, platform, weekly_growth, snapshot_date
    ) values (
        v_master_id, v_tempo_id, p_pais_code, p_rank, p_peak_rank, p_previous_rank,
        p_weeks_on_chart, p_streams, p_source, p_uri, p_platform, p_weekly_growth, p_snapshot_date
    )
    on conflict (track_master_id, pais_code, snapshot_date, platform)
    do update set
        rank = excluded.rank, peak_rank = excluded.peak_rank, previous_rank = excluded.previous_rank,
        weeks_on_chart = excluded.weeks_on_chart, streams = excluded.streams, source = excluded.source,
        uri = excluded.uri, weekly_growth = excluded.weekly_growth, tempo_id = excluded.tempo_id,
        deleted_at = null, updated_at = now()
    returning id into v_territory_id;

    if v_partes then
        insert into territory_tracks_partes (territory_track_id, clave, rank, streams)
        values (v_territory_id, v_clave, p_rank, p_streams)
        on conflict (territory_track_id, clave) do update set rank = excluded.rank, streams = excluded.streams;
        update territory_tracks tt set streams = x.streams, rank = x.rank
        from (select sum(p.streams) as streams, min(p.rank) as rank from territory_tracks_partes p
              where p.territory_track_id = v_territory_id) x
        where tt.id = v_territory_id;
    end if;

    return query select v_territory_id, v_created;
end;
$function$;
GRANT INSERT, UPDATE ON public.territory_tracks_partes TO authenticated;
DROP POLICY IF EXISTS territory_tracks_partes_carga ON public.territory_tracks_partes;
CREATE POLICY territory_tracks_partes_carga ON public.territory_tracks_partes AS PERMISSIVE FOR ALL TO authenticated
    USING (fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text]))
    WITH CHECK (fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text]));

-- Carga CSV de "Tempo IDs" (reemplaza a la original): busca la obra también por los nombres unificados, solo admite
-- los valores estándar y, si el Tempo ID numérico ya está en otra obra, las unifica (es la misma canción).
CREATE OR REPLACE FUNCTION public.fn_upsert_master_tempo_batch(p_rows jsonb)
 RETURNS TABLE(idx integer, error_message text)
 LANGUAGE plpgsql
AS $function$
declare
    r jsonb;
    i integer := 0;
    v_obra uuid;
    v_otra uuid;
    v_valor text;
begin
    for r in select * from jsonb_array_elements(p_rows) loop
        i := i + 1;
        begin
            v_valor := fn_valor_tempo(r->>'tempo_id');
            select tm.id into v_obra from tracks_master tm
            where lower(tm.track_artist_concat) = lower(trim(r->>'track_artist')) and tm.deleted_at is null;
            if v_obra is null then
                select a.track_master_id into v_obra from obra_alias a where a.clave = lower(trim(r->>'track_artist'));
            end if;
            if v_obra is null then
                idx := i;
                error_message := 'No se encontró la obra "' || (r->>'track_artist') || '" en la tabla principal.';
                return next;
                continue;
            end if;
            select tm.id into v_otra from tracks_master tm
            where v_valor ~ '^[0-9]+$' and tm.tempo_id = v_valor and tm.id <> v_obra and tm.deleted_at is null;
            if v_otra is not null then
                if (select tempo_id from tracks_master where id = v_obra) ~ '^[0-9]+$' then
                    update tracks_master set tempo_id = null where id = v_obra;   -- cambia de número: queda el del archivo
                end if;
                perform unificar_obras(v_obra, v_otra, v_valor);
            else
                update tracks_master
                set tempo_id = v_valor,
                    estado_bo = case when v_valor ~ '^[0-9]+$' then 'ok'::estado_bo_enum
                                     when v_valor = 'UNCONTROLLED' then 'uncontrolled'::estado_bo_enum else estado_bo end
                where id = v_obra;
            end if;
            idx := i; error_message := null;
            return next;
        exception when others then
            idx := i; error_message := sqlerrm;
            return next;
        end;
    end loop;
end;
$function$;


-- Asigna (o quita) el Tempo ID de una obra. Si otra obra ya lo tiene:
--  * Tempo ID numérico y p_unificar: es la misma canción (por ejemplo, escrita distinto en Spotify y en YouTube). La
--    obra se unifica con la que ya lo tenía: sus charts, reportes, controles y envíos pasan a esa obra y la editada
--    deja de existir. Devuelve 1.
--  * Si no: error que nombra la obra que lo tiene.
-- Sin conflicto, asigna el Tempo ID como fn_set_tempo_id y devuelve 0.
CREATE OR REPLACE FUNCTION public.fn_asignar_tempo_id(p_track_id uuid, p_tempo_id text, p_unificar boolean DEFAULT false)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
    v_clean text := fn_valor_tempo(p_tempo_id);   -- número o marcador estándar; error si no es válido
    v_otra record;
begin
    if coalesce(fn_app_role(), '') not in ('admin', 'usuario_estandar') then
        raise exception 'Sin permiso para modificar obras.' using errcode = 'insufficient_privilege';
    end if;
    if not exists (select 1 from tracks_master where id = p_track_id and deleted_at is null) then
        raise exception 'La obra no existe o fue eliminada.';
    end if;
    -- Solo un Tempo ID numérico es de una sola obra; los marcadores (UNCONTROLLED, COMPILADO) se repiten.
    select id, track_artist_concat, deleted_at into v_otra
    from tracks_master where tempo_id = v_clean and id <> p_track_id and v_clean ~ '^[0-9]+$';

    if v_otra.id is null then
        update tracks_master
        set tempo_id = v_clean,
            estado_bo = case when v_clean ~ '^[0-9]+$' then 'ok'::estado_bo_enum
                             when v_clean = 'UNCONTROLLED' then 'uncontrolled'::estado_bo_enum else estado_bo end
        where id = p_track_id;
        return 0;
    end if;
    if v_otra.deleted_at is not null then
        raise exception 'El Tempo ID % ya está asignado a una obra eliminada: "%".', v_clean, v_otra.track_artist_concat
            using errcode = 'unique_violation';
    end if;
    if not p_unificar or v_clean !~ '^[0-9]+$' then
        raise exception 'El Tempo ID % ya está asignado a "%".', v_clean, v_otra.track_artist_concat
            using errcode = 'unique_violation';
    end if;

    perform unificar_obras(p_track_id, v_otra.id, v_clean);
    return 1;
end;
$function$;

-- envio_obras es de solo lectura para los usuarios; la unificación necesita pasar los envíos a la obra que queda.
GRANT INSERT ON public.envio_obras TO authenticated;
DROP POLICY IF EXISTS envio_obras_unificar ON public.envio_obras;
CREATE POLICY envio_obras_unificar ON public.envio_obras AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text]));
GRANT INSERT ON public.envio_identificadas TO authenticated;
DROP POLICY IF EXISTS envio_identificadas_unificar ON public.envio_identificadas;
CREATE POLICY envio_identificadas_unificar ON public.envio_identificadas AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text]));

-- ---------------------------------------------------------------- descarga de la tabla por territorio
-- Las columnas de la tabla por territorio, en su orden (con Ticket y Fecha), con todos los filtros de la pantalla
-- (también reclamos, estado de trabajo y la búsqueda).
DROP FUNCTION IF EXISTS public.fn_territory_exportar(date, date, pais_code_enum, text, text, text);
CREATE OR REPLACE FUNCTION public.fn_territory_exportar(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date,
    p_pais pais_code_enum DEFAULT NULL::pais_code_enum, p_buscar text DEFAULT NULL::text,
    p_reclamos text DEFAULT NULL::text, p_estado_trabajo text DEFAULT NULL::text)
 RETURNS TABLE("Pais" text, "Track - Artista" text, "Created date" text, "Tempo ID" text,
               "% Perf Tempo" text, "% Mech Tempo" text, "BO ID" text, "C/A" text, "% Mech BO" text, "Estado" text,
               "Reclamos" text, "Estado de trabajo" text, "Ticket" text, "Fecha" text)
 LANGUAGE sql
 STABLE
AS $function$
    select
        v.pais_code::text,
        v.track_artist_concat,
        coalesce(v.created_date::text, ''),
        coalesce(v.tempo_id, ''),
        case when v.perf_raw ~ '^[0-9.]+$' then v.perf_raw || '%' else coalesce(v.perf_raw, '') end,
        case when v.mech_raw ~ '^[0-9.]+$' then v.mech_raw || '%' else coalesce(v.mech_raw, '') end,
        coalesce(v.bo, ''),
        coalesce(v.ca, ''),
        coalesce(v.mech_bo::text || '%', ''),
        coalesce(v.estado, ''),
        coalesce(v.reclamos, ''),
        coalesce(v.estado_trabajo, ''),
        coalesce(v.ticket, ''),
        coalesce(to_char(v.ticket_fecha, 'DD/MM/YYYY'), '')
    from fn_territory_pagina(p_date_from, p_date_to, p_pais, false, p_buscar, p_reclamos, p_estado_trabajo,
                             2147483647, 0) v;
$function$;

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
    return case when p_campo = 'ticket' then coalesce(v, '') else coalesce(to_char(v_fecha, 'DD/MM/YYYY'), '') end;
end;
$function$;
REVOKE ALL ON FUNCTION public.fn_guardar_seguimiento(uuid, pais_code_enum, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_guardar_seguimiento(uuid, pais_code_enum, text, text) TO authenticated, service_role;
