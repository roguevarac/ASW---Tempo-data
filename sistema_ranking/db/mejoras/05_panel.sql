-- =====================================================================
-- Mejora propia (no viene de Supabase): Panel de control.
--
-- Control visual del sistema sin terminal, solo para las personas de panel.acceso (se agregan desde la consola:
-- bash ranking.sh usuarios). Todo pasa por funciones SECURITY DEFINER que verifican el acceso al empezar: los usuarios
-- comunes no ven el esquema "panel" ni pueden llamarlas.
--
--  * panel.eventos: registro de lo que hacen los servicios (espejo de OneDrive, respaldos) y las acciones del panel.
--  * panel.servicios: último aviso de cada servicio (así se sabe si está funcionando sin acceso a Docker).
--  * panel.solicitudes: pedidos del panel a los servicios ("Respaldar ahora"), que el servicio "respaldo" atiende.
--
-- Idempotente: se aplica en cada arranque (db/mejoras.sh).
-- =====================================================================
SET search_path = public;
-- Crear un esquema requiere al superusuario (las mejoras corren con SET ROLE app_owner); el resto, como app_owner.
RESET ROLE;
CREATE SCHEMA IF NOT EXISTS panel AUTHORIZATION app_owner;
SET ROLE app_owner;
REVOKE ALL ON SCHEMA panel FROM PUBLIC;
GRANT USAGE ON SCHEMA panel TO authenticated;   -- solo para llamar a las funciones (las tablas no tienen permisos)

CREATE TABLE IF NOT EXISTS panel.acceso (
    email   text PRIMARY KEY CHECK (email = lower(trim(email))),
    agregado timestamptz NOT NULL DEFAULT now()
);
-- Acceso inicial pedido por la usuaria (23/10/2026).
INSERT INTO panel.acceso (email) VALUES ('rocio.guevara@sonymusicpub.com') ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS panel.eventos (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fecha    timestamptz NOT NULL DEFAULT now(),
    servicio text NOT NULL,                 -- espejo, respaldo, panel, instalador, ranking.sh
    nivel    text NOT NULL CHECK (nivel IN ('ok', 'aviso', 'error')),
    mensaje  text NOT NULL,
    usuario  text
);
CREATE INDEX IF NOT EXISTS ix_panel_eventos_fecha ON panel.eventos (fecha DESC);
CREATE INDEX IF NOT EXISTS ix_panel_eventos_servicio ON panel.eventos (servicio, fecha DESC);

CREATE TABLE IF NOT EXISTS panel.servicios (
    servicio     text PRIMARY KEY,
    ultimo_aviso timestamptz NOT NULL DEFAULT now(),
    detalle      jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS panel.solicitudes (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tipo       text NOT NULL CHECK (tipo IN ('respaldo')),
    pedido_por text,
    pedido     timestamptz NOT NULL DEFAULT now(),
    estado     text NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente', 'en curso', 'listo', 'error')),
    terminado  timestamptz,
    mensaje    text
);

-- Para los servicios (conectados como postgres) y ranking.sh: registran eventos y avisos de vida.
CREATE OR REPLACE FUNCTION panel.registrar(p_servicio text, p_nivel text, p_mensaje text, p_usuario text DEFAULT NULL)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    INSERT INTO panel.eventos (servicio, nivel, mensaje, usuario) VALUES (p_servicio, p_nivel, p_mensaje, p_usuario);
    DELETE FROM panel.eventos WHERE fecha < now() - interval '180 days';
$$;
CREATE OR REPLACE FUNCTION panel.latido(p_servicio text, p_detalle jsonb DEFAULT '{}'::jsonb)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    INSERT INTO panel.servicios (servicio, ultimo_aviso, detalle) VALUES (p_servicio, now(), coalesce(p_detalle, '{}'))
    ON CONFLICT (servicio) DO UPDATE SET ultimo_aviso = now(), detalle = excluded.detalle;
$$;
REVOKE ALL ON FUNCTION panel.registrar(text, text, text, text), panel.latido(text, jsonb) FROM PUBLIC;

-- ---------------------------------------------------------------- acceso
CREATE OR REPLACE FUNCTION panel.usuario_actual() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT lower(u.email) FROM auth.users u WHERE u.id = auth.uid()
$$;
CREATE OR REPLACE FUNCTION panel.tiene_acceso() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT EXISTS (SELECT 1 FROM panel.acceso a WHERE a.email = panel.usuario_actual())
$$;
CREATE OR REPLACE FUNCTION panel.exigir_acceso() RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT panel.tiene_acceso() THEN
        RAISE EXCEPTION 'Sin acceso al Panel de control.' USING errcode = 'insufficient_privilege';
    END IF;
    RETURN panel.usuario_actual();
END $$;

-- ---------------------------------------------------------------- estado
CREATE OR REPLACE FUNCTION panel.estado() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    PERFORM panel.exigir_acceso();
    RETURN jsonb_build_object(
        'base', jsonb_build_object(
            'version', current_setting('server_version'),
            'tamano', pg_database_size(current_database()),
            'iniciada', pg_postmaster_start_time(),
            'conexiones', (SELECT count(*) FROM pg_stat_activity WHERE datname = current_database())),
        'servicios', (SELECT coalesce(jsonb_object_agg(servicio, jsonb_build_object(
                          'ultimo_aviso', ultimo_aviso, 'segundos', extract(epoch FROM now() - ultimo_aviso)::int,
                          'detalle', detalle)), '{}') FROM panel.servicios),
        'datos', jsonb_build_object(
            'obras', (SELECT count(*) FROM tracks_master WHERE deleted_at IS NULL),
            'obras_sin_tempo', (SELECT count(*) FROM tracks_master WHERE deleted_at IS NULL AND tempo_id IS NULL),
            'filas_charts', (SELECT count(*) FROM territory_tracks WHERE deleted_at IS NULL),
            'reportes_bo', (SELECT count(*) FROM territory_bo_report),
            'reportes_tempo', (SELECT count(*) FROM territory_tempo_report WHERE deleted_at IS NULL),
            'archivos', (SELECT count(*) FROM storage.objects WHERE bucket_id = 'csv-uploads'),
            'tamano_archivos', (SELECT coalesce(sum((metadata ->> 'size')::bigint), 0) FROM storage.objects
                                WHERE bucket_id = 'csv-uploads')),
        'respaldos', jsonb_build_object(
            'ultimo_respaldo', (SELECT jsonb_build_object('fecha', fecha, 'mensaje', mensaje) FROM panel.eventos
                                WHERE servicio IN ('respaldo', 'ranking.sh') AND nivel = 'ok' AND mensaje LIKE 'Respaldo%'
                                ORDER BY fecha DESC LIMIT 1),
            'ultima_copia_onedrive', (SELECT jsonb_build_object('fecha', fecha, 'mensaje', mensaje) FROM panel.eventos
                                      WHERE servicio IN ('respaldo', 'ranking.sh') AND nivel = 'ok' AND mensaje LIKE 'Copia en OneDrive%'
                                      ORDER BY fecha DESC LIMIT 1),
            'ultimo_error', (SELECT jsonb_build_object('fecha', fecha, 'mensaje', mensaje) FROM panel.eventos
                             WHERE servicio = 'respaldo' AND nivel <> 'ok' ORDER BY fecha DESC LIMIT 1),
            'solicitudes', (SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.id DESC), '[]') FROM
                            (SELECT * FROM panel.solicitudes ORDER BY id DESC LIMIT 5) s)),
        'ultimo_arranque', (SELECT jsonb_build_object('fecha', fecha, 'mensaje', mensaje) FROM panel.eventos
                            WHERE servicio = 'ranking.sh' AND mensaje LIKE 'Arranque del sistema%' ORDER BY fecha DESC LIMIT 1),
        'espejo', jsonb_build_object(
            'ultima_copia', (SELECT jsonb_build_object('fecha', fecha, 'mensaje', mensaje) FROM panel.eventos
                             WHERE servicio = 'espejo' AND nivel = 'ok' AND mensaje LIKE 'Copiado%' ORDER BY fecha DESC LIMIT 1),
            'ultimo_aviso', (SELECT jsonb_build_object('fecha', fecha, 'mensaje', mensaje, 'nivel', nivel) FROM panel.eventos
                             WHERE servicio = 'espejo' AND nivel <> 'ok' ORDER BY fecha DESC LIMIT 1)),
        'acceso', (SELECT coalesce(jsonb_agg(email ORDER BY email), '[]') FROM panel.acceso)
    );
END $$;

CREATE OR REPLACE FUNCTION panel.eventos(p_servicio text DEFAULT NULL, p_nivel text DEFAULT NULL, p_limite integer DEFAULT 200)
RETURNS TABLE(fecha timestamptz, servicio text, nivel text, mensaje text, usuario text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
BEGIN
    PERFORM panel.exigir_acceso();
    RETURN QUERY SELECT e.fecha, e.servicio, e.nivel, e.mensaje, e.usuario FROM panel.eventos e
                 WHERE (p_servicio IS NULL OR e.servicio = p_servicio) AND (p_nivel IS NULL OR e.nivel = p_nivel)
                 ORDER BY e.id DESC LIMIT least(greatest(p_limite, 1), 1000);
END $$;

-- "Respaldar ahora": lo atiende el servicio "respaldo" en pocos segundos.
CREATE OR REPLACE FUNCTION panel.pedir_respaldo() RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_quien text := panel.exigir_acceso(); v_id bigint;
BEGIN
    SELECT id INTO v_id FROM panel.solicitudes WHERE tipo = 'respaldo' AND estado IN ('pendiente', 'en curso');
    IF v_id IS NOT NULL THEN
        RETURN v_id;   -- ya hay uno en curso
    END IF;
    INSERT INTO panel.solicitudes (tipo, pedido_por) VALUES ('respaldo', v_quien) RETURNING id INTO v_id;
    PERFORM panel.registrar('panel', 'ok', 'Respaldo solicitado desde el Panel de control', v_quien);
    RETURN v_id;
END $$;

-- ---------------------------------------------------------------- usuarios
CREATE OR REPLACE FUNCTION panel.usuarios()
RETURNS TABLE(email text, rol text, oficina text, creado timestamptz, ultimo_ingreso timestamptz, bloqueado boolean,
              sin_clave boolean, sesiones_abiertas bigint, ultimo_uso timestamptz, codigo_vence timestamptz, panel boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
BEGIN
    PERFORM panel.exigir_acceso();
    RETURN QUERY
    SELECT u.email, a.app_role, a.oficina, u.created_at, u.last_sign_in_at,
           coalesce(u.banned_until > now(), false), u.encrypted_password IS NULL,
           (SELECT count(*) FROM auth.sesiones s WHERE s.user_id = u.id AND s.cerrada IS NULL
              AND s.ultimo_uso > now() - interval '1 day'),
           (SELECT max(s.ultimo_uso) FROM auth.sesiones s WHERE s.user_id = u.id),
           (SELECT k.vence FROM auth.codigos_clave k WHERE k.user_id = u.id AND k.vence > now()),
           EXISTS (SELECT 1 FROM panel.acceso p WHERE p.email = lower(u.email))
    FROM auth.users u LEFT JOIN app_users a ON a.user_id = u.id
    ORDER BY lower(u.email);
END $$;

-- Alta: el usuario queda sin contraseña y recibe un código de activación (válido 72 horas) para elegirla en
-- "¿Olvidaste la contraseña?". Quien administra nunca conoce la contraseña.
CREATE OR REPLACE FUNCTION panel.crear_usuario(p_email text, p_rol text, p_oficina text DEFAULT NULL) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_quien text := panel.exigir_acceso(); v_email text := lower(trim(p_email)); v_id uuid;
BEGIN
    IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
        RAISE EXCEPTION 'El email no es válido.';
    END IF;
    IF p_rol NOT IN ('admin', 'usuario_estandar', 'auditor') THEN
        RAISE EXCEPTION 'Rol desconocido: %', p_rol;
    END IF;
    IF EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = v_email) THEN
        RAISE EXCEPTION 'Ya existe un usuario con ese email.' USING errcode = 'unique_violation';
    END IF;
    INSERT INTO auth.users (email) VALUES (v_email) RETURNING id INTO v_id;
    INSERT INTO app_users (user_id, app_role, oficina) VALUES (v_id, p_rol, nullif(trim(p_oficina), ''));
    PERFORM panel.registrar('panel', 'ok', format('Alta de %s (%s)', v_email, p_rol), v_quien);
    RETURN auth.generar_codigo_clave(v_email, 72 * 60);
END $$;

CREATE OR REPLACE FUNCTION panel.cambiar_rol(p_email text, p_rol text, p_oficina text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_quien text := panel.exigir_acceso(); v_id uuid;
BEGIN
    IF p_rol NOT IN ('admin', 'usuario_estandar', 'auditor') THEN
        RAISE EXCEPTION 'Rol desconocido: %', p_rol;
    END IF;
    SELECT id INTO v_id FROM auth.users WHERE lower(email) = lower(trim(p_email));
    IF v_id IS NULL THEN RAISE EXCEPTION 'No existe ese usuario.'; END IF;
    INSERT INTO app_users (user_id, app_role, oficina) VALUES (v_id, p_rol, nullif(trim(p_oficina), ''))
    ON CONFLICT (user_id) DO UPDATE SET app_role = excluded.app_role, oficina = excluded.oficina;
    PERFORM panel.registrar('panel', 'ok', format('Rol de %s: %s%s', lower(p_email), p_rol,
                            coalesce(', oficina ' || nullif(trim(p_oficina), ''), '')), v_quien);
END $$;

CREATE OR REPLACE FUNCTION panel.bloquear(p_email text, p_bloquear boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_quien text := panel.exigir_acceso(); v_id uuid;
BEGIN
    IF lower(trim(p_email)) = v_quien AND p_bloquear THEN
        RAISE EXCEPTION 'No podés bloquear tu propio usuario.';
    END IF;
    UPDATE auth.users SET banned_until = CASE WHEN p_bloquear THEN 'infinity'::timestamptz END
    WHERE lower(email) = lower(trim(p_email)) RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'No existe ese usuario.'; END IF;
    IF p_bloquear THEN
        UPDATE auth.sesiones SET cerrada = now() WHERE user_id = v_id AND cerrada IS NULL;
    END IF;
    PERFORM panel.registrar('panel', 'ok', format('%s %s', CASE WHEN p_bloquear THEN 'Bloqueo de' ELSE 'Desbloqueo de' END,
                            lower(p_email)), v_quien);
END $$;

CREATE OR REPLACE FUNCTION panel.codigo_clave(p_email text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_quien text := panel.exigir_acceso(); v_codigo text;
BEGIN
    v_codigo := auth.generar_codigo_clave(p_email, 30);
    PERFORM panel.registrar('panel', 'ok', format('Código para restablecer la contraseña de %s', lower(p_email)), v_quien);
    RETURN v_codigo;
END $$;

CREATE OR REPLACE FUNCTION panel.cerrar_sesiones(p_email text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_quien text := panel.exigir_acceso(); v_n integer;
BEGIN
    UPDATE auth.sesiones s SET cerrada = now() FROM auth.users u
    WHERE u.id = s.user_id AND lower(u.email) = lower(trim(p_email)) AND s.cerrada IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    PERFORM panel.registrar('panel', 'ok', format('Cierre de %s sesiones de %s', v_n, lower(p_email)), v_quien);
    RETURN v_n;
END $$;

-- ---------------------------------------------------------------- actividad
CREATE INDEX IF NOT EXISTS ix_audit_logs_changed_at ON public.audit_logs (changed_at);

-- Lo que hizo cada persona: ingresos, cargas, descargas y cambios hechos a mano. Los cambios se agrupan por usuario,
-- tabla y minuto; los de una carga se informan en la carga (no fila por fila) y los de procesos del sistema (como la
-- carga de históricos) no se listan. Sin fechas: los últimos 90 días.
CREATE OR REPLACE FUNCTION panel.actividad(p_usuario text DEFAULT NULL, p_tipo text DEFAULT NULL,
    p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL, p_limite integer DEFAULT 300)
RETURNS TABLE(fecha timestamptz, usuario text, tipo text, detalle text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
DECLARE
    v_desde timestamptz := coalesce(p_desde::timestamptz, now() - interval '90 days');
    v_hasta timestamptz := coalesce((p_hasta + 1)::timestamptz, 'infinity');
    v_quien uuid;
BEGIN
    PERFORM panel.exigir_acceso();
    SELECT id INTO v_quien FROM auth.users WHERE lower(email) = lower(p_usuario);
    IF p_usuario IS NOT NULL AND v_quien IS NULL THEN
        RETURN;
    END IF;
    RETURN QUERY
    WITH nombres AS (SELECT u.id::text AS id, lower(u.email) AS email FROM auth.users u),
    cargas AS (
        SELECT c.uploaded_at AS fecha, coalesce(n.email, c.uploaded_by, '—') AS usuario, 'Carga'::text AS tipo,
               format('%s · %s · %s de %s filas%s', c.filename, coalesce(c.format, 'formato desconocido'),
                      c.updated_rows, c.total_rows,
                      CASE WHEN c.error_count > 0 THEN format(' · %s avisos', c.error_count) ELSE '' END) AS detalle
        FROM csv_uploads c LEFT JOIN nombres n ON n.id = c.uploaded_by
        WHERE coalesce(c.format, '') NOT IN ('bo_generado', 'csv_principal')
          AND c.uploaded_at >= v_desde AND c.uploaded_at < v_hasta
          AND (v_quien IS NULL OR c.uploaded_by = v_quien::text) AND (p_tipo IS NULL OR p_tipo = 'Carga')
    ),
    por_minuto AS (   -- primero se agrupa (pocas filas) y después se descartan los minutos de una carga
        SELECT al.changed_by AS quien, al.table_name AS tabla, date_trunc('minute', al.changed_at) AS minuto,
               max(al.changed_at) AS fecha, count(*) AS n,
               bool_or(al.operation = 'UPDATE' AND al.new_data ->> 'tempo_id' IS DISTINCT FROM al.old_data ->> 'tempo_id') AS c_tempo,
               bool_or(al.operation = 'UPDATE' AND al.new_data ->> 'estado_trabajo' IS DISTINCT FROM al.old_data ->> 'estado_trabajo') AS c_estado,
               bool_or(al.operation IN ('SOFT_DELETE', 'HARD_DELETE')) AS c_bajas
        FROM audit_logs al
        WHERE al.changed_at >= v_desde AND al.changed_at < v_hasta
          AND (v_quien IS NULL OR al.changed_by = v_quien::text) AND (p_tipo IS NULL OR p_tipo = 'Cambio')
        GROUP BY 1, 2, 3
    ),
    ventanas AS (
        SELECT DISTINCT c.uploaded_by AS quien, date_trunc('minute', c.uploaded_at) - k * interval '1 minute' AS minuto
        FROM csv_uploads c CROSS JOIN generate_series(0, 2) k
        WHERE c.uploaded_at >= v_desde - interval '3 minutes' AND c.uploaded_at < v_hasta
    ),
    cambios AS (
        SELECT pm.fecha, n.email AS usuario, 'Cambio'::text AS tipo,
               format('%s %s en %s', pm.n, CASE WHEN pm.n = 1 THEN 'fila modificada' ELSE 'filas modificadas' END,
                      CASE pm.tabla WHEN 'tracks_master' THEN 'la tabla principal'
                                    WHEN 'territory_bo_report' THEN 'datos de BO'
                                    WHEN 'territory_tempo_report' THEN 'datos de Tempo'
                                    WHEN 'territory_seguimiento' THEN 'tickets de la tabla por territorio' ELSE pm.tabla END)
               || coalesce(' (' || nullif(concat_ws(', ', CASE WHEN pm.c_tempo THEN 'Tempo ID' END,
                                                    CASE WHEN pm.c_estado THEN 'estado de trabajo' END,
                                                    CASE WHEN pm.c_bajas THEN 'bajas' END), '') || ')', '') AS detalle
        FROM por_minuto pm JOIN nombres n ON n.id = pm.quien   -- solo personas: los procesos del sistema no se listan
        WHERE NOT EXISTS (SELECT 1 FROM ventanas v WHERE v.quien = pm.quien AND v.minuto = pm.minuto)
    ),
    descargas AS (
        SELECT e.created_at, coalesce(n.email, e.created_by), 'Descarga'::text,
               format('%s · %s · %s obras%s', CASE e.tipo WHEN 'reporte_bo' THEN 'Reporte BO' ELSE 'CSV de la tabla principal' END,
                      CASE e.modo WHEN 'nuevas' THEN 'solo las nuevas' WHEN 'identificadas' THEN 'identificadas desde la última descarga' ELSE 'todas' END, e.obras,
                      coalesce(' · carga ' || e.carga, ''))
        FROM envios e LEFT JOIN nombres n ON n.id = e.created_by
        WHERE e.created_at >= v_desde AND e.created_at < v_hasta
          AND (v_quien IS NULL OR e.created_by = v_quien::text) AND (p_tipo IS NULL OR p_tipo = 'Descarga')
    ),
    ingresos AS (
        SELECT s.creada, lower(u.email), 'Ingreso'::text,
               CASE WHEN s.cerrada IS NOT NULL THEN format('Sesión cerrada (duró %s min)', greatest(1, extract(epoch FROM s.cerrada - s.creada)::int / 60))
                    ELSE format('Sesión abierta (en uso durante %s min)', greatest(1, extract(epoch FROM s.ultimo_uso - s.creada)::int / 60)) END
        FROM auth.sesiones s JOIN auth.users u ON u.id = s.user_id
        WHERE s.creada >= v_desde AND s.creada < v_hasta
          AND (v_quien IS NULL OR s.user_id = v_quien) AND (p_tipo IS NULL OR p_tipo = 'Ingreso')
    )
    SELECT t.fecha, t.usuario, t.tipo, t.detalle FROM (
        SELECT * FROM cargas UNION ALL SELECT * FROM cambios UNION ALL SELECT * FROM descargas UNION ALL SELECT * FROM ingresos
    ) t
    ORDER BY t.fecha DESC LIMIT least(greatest(p_limite, 1), 2000);
END $$;

-- ---------------------------------------------------------------- integridad
-- Por territorio y plataforma: semanas cargadas, primera y última, filas y semanas faltantes entre la primera y la
-- última (una semana falta si no hay ningún chart a menos de 3 días de la fecha esperada).
CREATE OR REPLACE FUNCTION panel.integridad_charts()
RETURNS TABLE(pais text, plataforma text, semanas bigint, primera date, ultima date, filas bigint, faltantes date[])
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
BEGIN
    PERFORM panel.exigir_acceso();
    RETURN QUERY
    WITH sem AS (
        SELECT tt.pais_code::text AS pais, tt.platform AS plataforma, tt.snapshot_date AS fecha, count(*) AS filas
        FROM territory_tracks tt WHERE tt.deleted_at IS NULL GROUP BY 1, 2, 3
    ), res AS (
        SELECT s.pais, s.plataforma, count(*) AS semanas, min(s.fecha) AS primera, max(s.fecha) AS ultima, sum(s.filas)::bigint AS filas
        FROM sem s GROUP BY 1, 2
    )
    SELECT r.pais, r.plataforma, r.semanas, r.primera, r.ultima, r.filas,
           coalesce(ARRAY(SELECT g::date FROM generate_series(r.primera, r.ultima, interval '7 days') g
                          WHERE NOT EXISTS (SELECT 1 FROM sem s WHERE s.pais = r.pais AND s.plataforma = r.plataforma
                                            AND s.fecha BETWEEN g::date - 3 AND g::date + 3)
                          ORDER BY 1), '{}')
    FROM res r ORDER BY r.pais, r.plataforma;
END $$;

-- Cargas con avisos o sin filas cargadas (las descargas no cuentan), con los primeros mensajes.
CREATE OR REPLACE FUNCTION panel.cargas_con_problemas(p_limite integer DEFAULT 100)
RETURNS TABLE(fecha timestamptz, usuario text, archivo text, formato text, total integer, cargadas integer,
              avisos integer, errores jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
BEGIN
    PERFORM panel.exigir_acceso();
    RETURN QUERY
    SELECT c.uploaded_at, coalesce(lower(u.email), c.uploaded_by), c.filename, c.format, c.total_rows, c.updated_rows,
           c.error_count, c.errors
    FROM csv_uploads c LEFT JOIN auth.users u ON u.id::text = c.uploaded_by
    WHERE (c.error_count > 0 OR c.updated_rows = 0) AND coalesce(c.format, '') NOT IN ('bo_generado', 'csv_principal')
    ORDER BY c.uploaded_at DESC LIMIT least(greatest(p_limite, 1), 1000);
END $$;

-- Archivos registrados (para que la API compare con los archivos reales del almacenamiento).
CREATE OR REPLACE FUNCTION panel.archivos_registrados()
RETURNS TABLE(nombre text, tamano bigint, filename text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
BEGIN
    PERFORM panel.exigir_acceso();
    RETURN QUERY
    SELECT o.name, (o.metadata ->> 'size')::bigint, c.filename
    FROM storage.objects o LEFT JOIN csv_uploads c ON c.file_path = o.name
    WHERE o.bucket_id = 'csv-uploads';
END $$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA panel FROM PUBLIC;
GRANT EXECUTE ON FUNCTION panel.tiene_acceso(), panel.estado(), panel.eventos(text, text, integer), panel.pedir_respaldo(),
    panel.usuarios(), panel.crear_usuario(text, text, text), panel.cambiar_rol(text, text, text),
    panel.bloquear(text, boolean), panel.codigo_clave(text), panel.cerrar_sesiones(text),
    panel.actividad(text, text, date, date, integer), panel.integridad_charts(), panel.cargas_con_problemas(integer),
    panel.archivos_registrados() TO authenticated;
