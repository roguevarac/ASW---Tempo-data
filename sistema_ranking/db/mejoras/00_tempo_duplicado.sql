-- =====================================================================
-- Mejora propia (no viene de Supabase): obras con el Tempo ID duplicado en Tempo (pedido del usuario, 16/11/2026).
--
-- A veces una canción tiene dos obras en Tempo (dos Tempo ID). En la tabla principal se escribe "123-456": la obra
-- conserva su Tempo ID principal (tracks_master.tempo_id = 123) y los demás quedan acá. En la tabla por territorio la
-- obra aparece una vez por cada Tempo ID, con sus datos de BO y Tempo y su ticket por separado (*dup*, DUPLICADA).
-- La lógica está en 17_tempo_duplicado.sql; la tabla y fn_tempo_texto van primero porque las usan funciones de
-- mejoras anteriores (01, 03). Va en los TRUNCATE (apunta a tracks_master).
-- Idempotente: se aplica en cada arranque (db/mejoras.sh).
-- =====================================================================
SET search_path = public;

CREATE TABLE IF NOT EXISTS public.tempo_duplicado (
    tempo_id        text PRIMARY KEY CHECK (tempo_id ~ '^[0-9]+$'),
    track_master_id uuid NOT NULL REFERENCES public.tracks_master(id) ON DELETE CASCADE,
    orden           integer NOT NULL DEFAULT 1,
    created_at      timestamp with time zone NOT NULL DEFAULT now(),
    created_by      text NOT NULL DEFAULT COALESCE((auth.uid())::text, (CURRENT_USER)::text)
);
CREATE INDEX IF NOT EXISTS ix_tempo_duplicado_track ON public.tempo_duplicado (track_master_id);
ALTER TABLE public.tempo_duplicado ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tempo_duplicado_select ON public.tempo_duplicado;
CREATE POLICY tempo_duplicado_select ON public.tempo_duplicado AS PERMISSIVE FOR SELECT TO authenticated USING (true);
GRANT SELECT ON public.tempo_duplicado TO authenticated;
GRANT ALL ON public.tempo_duplicado TO service_role;

-- El Tempo ID como se muestra y se descarga: el principal y los duplicados, "123-456".
CREATE OR REPLACE FUNCTION public.fn_tempo_texto(p_obra uuid, p_tempo text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
    select nullif(coalesce(p_tempo, '') || coalesce((select string_agg('-' || d.tempo_id, '' order by d.orden, d.created_at)
                                                     from tempo_duplicado d where d.track_master_id = p_obra), ''), '');
$function$;
GRANT EXECUTE ON FUNCTION public.fn_tempo_texto(uuid, text) TO authenticated;
