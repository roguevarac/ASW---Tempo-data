-- =====================================================================
-- Mejora propia (no viene de Supabase): enviar el reporte BO al servidor de BO (pedido de la usuaria, 16/11/2026).
--
-- Antes el reporte BO se descargaba y se subía con FileZilla a intranet.backoffice-ms.com. Ahora el sistema lo sube
-- directamente (POST /bo/enviar en la API, api/envio_bo.py) con el usuario y la contraseña de BO de la persona, que se
-- piden en cada envío y no se guardan. Primero solo para las personas de envio_bo_usuarios (al comienzo, la usuaria
-- que lo pidió); se agregan desde la consola: usuarios.py envio-bo <email> si|no.
-- Idempotente: se aplica en cada arranque (db/mejoras.sh).
-- =====================================================================
SET search_path = public;

CREATE TABLE IF NOT EXISTS public.envio_bo_usuarios (
    email    text PRIMARY KEY CHECK (email = lower(trim(email))),
    agregado timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.envio_bo_usuarios ENABLE ROW LEVEL SECURITY;   -- sin políticas: solo las funciones de abajo
GRANT ALL ON public.envio_bo_usuarios TO service_role;
INSERT INTO public.envio_bo_usuarios (email) VALUES ('rocio.guevara@sonymusicpub.com') ON CONFLICT DO NOTHING;

-- La persona conectada puede enviar el reporte BO al servidor de BO.
CREATE OR REPLACE FUNCTION public.fn_envio_bo_habilitado()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    select coalesce(fn_app_role(), '') in ('admin', 'usuario_estandar')
       and exists (select 1 from envio_bo_usuarios e join auth.users u on lower(u.email) = e.email where u.id = auth.uid());
$function$;
REVOKE ALL ON FUNCTION public.fn_envio_bo_habilitado() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_envio_bo_habilitado() TO authenticated;

-- La API marca el envío como enviado al servidor (solo el de la propia persona).
CREATE OR REPLACE FUNCTION public.marcar_envio_enviado(p_envio bigint, p_destino text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    update envios set enviado_a = p_destino where id = p_envio and created_by = (auth.uid())::text;
$function$;
REVOKE ALL ON FUNCTION public.marcar_envio_enviado(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.marcar_envio_enviado(bigint, text) TO authenticated;

-- ---------------------------------------------------------------- certificado del servidor de BO (17/11/2026)
-- El servidor de BO presenta un certificado que no emitió una entidad reconocida. Como en FileZilla, una persona lo
-- acepta la primera vez (después de ver sus datos) y el sistema recuerda su huella SHA-256: desde entonces solo acepta
-- ese certificado. Lo acepta un Administrador (acceso al Panel de control) habilitado para el envío.
CREATE TABLE IF NOT EXISTS public.envio_bo_certificados (
    servidor     text NOT NULL,
    huella       text NOT NULL CHECK (huella ~ '^([0-9a-f]{2}:){31}[0-9a-f]{2}$'),
    detalle      jsonb,
    aceptado_por text,
    aceptado     timestamp with time zone NOT NULL DEFAULT now(),
    PRIMARY KEY (servidor, huella)
);
ALTER TABLE public.envio_bo_certificados ENABLE ROW LEVEL SECURITY;   -- sin políticas: solo las funciones de abajo
GRANT ALL ON public.envio_bo_certificados TO service_role;

-- Huellas aceptadas para el servidor (sin prefijo fn_: la API no la publica; la usa /bo/enviar).
CREATE OR REPLACE FUNCTION public.bo_certificados(p_servidor text)
 RETURNS text[]
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    select coalesce(array_agg(huella order by aceptado), '{}') from envio_bo_certificados
    where servidor = lower(p_servidor) and fn_envio_bo_habilitado();
$function$;
REVOKE ALL ON FUNCTION public.bo_certificados(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bo_certificados(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.aceptar_certificado_bo(p_servidor text, p_huella text, p_detalle jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_email text := panel.usuario_actual();
begin
    if not fn_envio_bo_habilitado() or not panel.tiene_acceso() then
        raise exception 'El certificado del servidor de BO lo acepta un Administrador.' using errcode = 'insufficient_privilege';
    end if;
    insert into envio_bo_certificados (servidor, huella, detalle, aceptado_por)
    values (lower(p_servidor), lower(p_huella), p_detalle, v_email)
    on conflict (servidor, huella) do nothing;
    perform panel.registrar('api', 'aviso', 'Certificado del servidor de BO aceptado (' || lower(p_servidor) || ', SHA-256 '
                            || lower(p_huella) || ')', v_email);
end;
$function$;
REVOKE ALL ON FUNCTION public.aceptar_certificado_bo(text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.aceptar_certificado_bo(text, text, jsonb) TO authenticated;

-- ---------------------------------------------------------------- habilitado para todos (17/11/2026)
-- Probado con la usuaria, se habilita para todas las personas (también las que se creen después): cada una ingresa su
-- usuario y contraseña de BO y el archivo va a su carpeta de carga. La fila se crea una sola vez: si desde la consola
-- se vuelve a "solo las de la lista" (usuarios.py envio-bo todos no), esa elección se mantiene en cada arranque.
CREATE TABLE IF NOT EXISTS public.envio_bo_config (
    id    boolean PRIMARY KEY DEFAULT true CHECK (id),
    todos boolean NOT NULL
);
ALTER TABLE public.envio_bo_config ENABLE ROW LEVEL SECURITY;   -- sin políticas: solo las funciones
GRANT ALL ON public.envio_bo_config TO service_role;
INSERT INTO public.envio_bo_config (id, todos) SELECT true, true WHERE NOT EXISTS (SELECT 1 FROM public.envio_bo_config);

CREATE OR REPLACE FUNCTION public.fn_envio_bo_habilitado()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    select coalesce(fn_app_role(), '') in ('admin', 'usuario_estandar')
       and (coalesce((select todos from envio_bo_config), true)   -- sin fila (respaldo anterior): todas
            or exists (select 1 from envio_bo_usuarios e join auth.users u on lower(u.email) = e.email where u.id = auth.uid()));
$function$;
