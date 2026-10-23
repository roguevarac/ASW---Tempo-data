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
    v_clean text := nullif(trim(p_tempo_id), '');
    v_otra record;
begin
    if coalesce(fn_app_role(), '') not in ('admin', 'usuario_estandar') then
        raise exception 'Sin permiso para modificar obras.' using errcode = 'insufficient_privilege';
    end if;
    if not exists (select 1 from tracks_master where id = p_track_id and deleted_at is null) then
        raise exception 'La obra no existe o fue eliminada.';
    end if;
    select id, track_artist_concat, deleted_at into v_otra
    from tracks_master where tempo_id = v_clean and id <> p_track_id;

    if v_otra.id is null then
        update tracks_master
        set tempo_id = v_clean,
            estado_bo = case when v_clean is not null then 'ok'::estado_bo_enum else estado_bo end
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

    perform set_config('app.allow_hard_delete', 'true', true);
    -- Lo que la obra editada comparte con la otra (mismo territorio y semana, o mismo territorio) queda de la otra.
    delete from territory_tracks tt where tt.track_master_id = p_track_id and exists (
        select 1 from territory_tracks s where s.track_master_id = v_otra.id and s.pais_code = tt.pais_code
           and s.snapshot_date = tt.snapshot_date and s.platform = tt.platform);
    update territory_tracks set track_master_id = v_otra.id, tempo_id = v_clean where track_master_id = p_track_id;
    delete from territory_bo_report t where t.track_master_id = p_track_id and exists (
        select 1 from territory_bo_report s where s.track_master_id = v_otra.id and s.pais_code = t.pais_code);
    update territory_bo_report set track_master_id = v_otra.id where track_master_id = p_track_id;
    delete from territory_tempo_report t where t.track_master_id = p_track_id and exists (
        select 1 from territory_tempo_report s where s.track_master_id = v_otra.id and s.pais_code = t.pais_code);
    update territory_tempo_report set track_master_id = v_otra.id where track_master_id = p_track_id;
    delete from territory_control t where t.track_master_id = p_track_id and exists (
        select 1 from territory_control s where s.track_master_id = v_otra.id and s.pais_code = t.pais_code);
    update territory_control set track_master_id = v_otra.id where track_master_id = p_track_id;
    insert into envio_obras (envio_id, track_master_id)
        select envio_id, v_otra.id from envio_obras where track_master_id = p_track_id
        on conflict do nothing;
    delete from tracks_master where id = p_track_id;   -- sus envio_obras se borran en cascada
    update tracks_master set estado_bo = 'ok' where id = v_otra.id and estado_bo <> 'ok';
    return 1;
end;
$function$;

-- envio_obras es de solo lectura para los usuarios; la unificación necesita pasar los envíos a la obra que queda.
GRANT INSERT ON public.envio_obras TO authenticated;
DROP POLICY IF EXISTS envio_obras_unificar ON public.envio_obras;
CREATE POLICY envio_obras_unificar ON public.envio_obras AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text]));

-- ---------------------------------------------------------------- descarga de la tabla por territorio
-- Mismas columnas que fn_territory_export, con todos los filtros de la pantalla (también reclamos, estado de trabajo
-- y la búsqueda).
CREATE OR REPLACE FUNCTION public.fn_territory_exportar(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date,
    p_pais pais_code_enum DEFAULT NULL::pais_code_enum, p_buscar text DEFAULT NULL::text,
    p_reclamos text DEFAULT NULL::text, p_estado_trabajo text DEFAULT NULL::text)
 RETURNS TABLE("Pais" text, "Track - Artista" text, "Created date" text, "Tempo ID" text, "BO" text, "C/A" text,
               "% Perf Tempo" text, "% Mech Tempo" text, "Estado" text, "Reclamos" text, "% Mech BO" text,
               "Estado de trabajo" text)
 LANGUAGE sql
 STABLE
AS $function$
    select
        v.pais_code::text,
        v.track_artist_concat,
        coalesce(v.created_date::text, ''),
        coalesce(v.tempo_id, ''),
        coalesce(v.bo, ''),
        coalesce(v.ca, ''),
        case when v.perf_raw ~ '^[0-9.]+$' then v.perf_raw || '%' else coalesce(v.perf_raw, '') end,
        case when v.mech_raw ~ '^[0-9.]+$' then v.mech_raw || '%' else coalesce(v.mech_raw, '') end,
        coalesce(v.estado, ''),
        coalesce(v.reclamos, ''),
        coalesce(v.mech_bo::text || '%', ''),
        coalesce(v.estado_trabajo, '')
    from fn_territory_pagina(p_date_from, p_date_to, p_pais, false, p_buscar, p_reclamos, p_estado_trabajo,
                             2147483647, 0) v;
$function$;
