-- =====================================================================
-- Mejora propia (no viene de Supabase): estado del acceso desde otras computadoras (Tailscale Funnel, 29/10/2026).
--
-- ranking.sh (el mantenedor cada minuto, verificar y compartir) le pasa lo que informa el contenedor "tunel":
--   {"status": <tailscale status --json>, "funnel": <tailscale funnel status --json>}   o NULL si no está corriendo.
-- Esta función lo traduce al estado que muestra el Panel de control (panel.servicios, servicio 'tunel'):
--   activo        sesión iniciada y enlace público habilitado (url = https://<equipo>.<red>.ts.net/)
--   sin_sesion    hay que iniciar sesión en Tailscale (primera vez o sesión vencida)
--   sin_funnel    sesión iniciada pero el enlace público no está habilitado
--   iniciando     Tailscale está arrancando
--   detenido      el contenedor no está corriendo
-- vence: cuándo vence la sesión del equipo (sin valor si se desactivó el vencimiento en Tailscale).
--
-- Idempotente: se aplica en cada arranque (db/mejoras.sh).
-- =====================================================================
SET search_path = public;

CREATE OR REPLACE FUNCTION panel.latido_tunel(p jsonb)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    SELECT panel.latido('tunel', jsonb_strip_nulls(jsonb_build_object(
        'estado', e.estado,
        'url', e.url,
        'acceso', 'cualquiera',
        'vence', e.vence,
        'mensaje', CASE e.estado
            WHEN 'activo' THEN NULL
            WHEN 'sin_sesion' THEN 'La sesión de Tailscale venció o no se completó. En la terminal de Ubuntu: bash ranking.sh compartir'
            WHEN 'sin_funnel' THEN 'El enlace público no está habilitado. En la terminal de Ubuntu: bash ranking.sh compartir'
            WHEN 'iniciando' THEN 'Tailscale está iniciando.'
            ELSE 'El acceso no está funcionando: se inicia con el sistema (bash ranking.sh abrir).' END)))
    FROM (SELECT CASE
                     WHEN p IS NULL OR jsonb_typeof(p -> 'status') IS DISTINCT FROM 'object' THEN 'detenido'
                     WHEN p -> 'status' ->> 'BackendState' = 'NeedsLogin' THEN 'sin_sesion'
                     WHEN p -> 'status' ->> 'BackendState' IS DISTINCT FROM 'Running' THEN 'iniciando'
                     WHEN coalesce(p -> 'funnel' -> 'AllowFunnel', '{}') = '{}' THEN 'sin_funnel'
                     ELSE 'activo' END AS estado,
                 'https://' || nullif(rtrim(p -> 'status' -> 'Self' ->> 'DNSName', '.'), '') || '/' AS url,
                 p -> 'status' -> 'Self' ->> 'KeyExpiry' AS vence) e;
$$;
REVOKE ALL ON FUNCTION panel.latido_tunel(jsonb) FROM PUBLIC;
