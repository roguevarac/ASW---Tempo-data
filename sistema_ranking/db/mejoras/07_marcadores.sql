-- =====================================================================
-- Mejora propia (no viene de Supabase): Tempo ID con marcadores repetibles.
--
-- En Supabase, UNIQUE(tempo_id) impedía que dos obras tuvieran el mismo marcador de texto (UNCONTROLLED, COMPILADO),
-- aunque el diseño original quería repetirlos (fn_merge_tempo_duplicates solo unifica numéricos). Ahora:
--   * un Tempo ID numérico sigue siendo único (índice único parcial, con el mismo nombre que la restricción vieja);
--   * los marcadores se pueden repetir.
-- La clave foránea territory_tracks.tempo_id -> tracks_master(tempo_id) exigía la restricción única y solo copiaba el
-- Tempo ID a los charts: eso ya lo hace el trigger trg_sync_tempo_id_to_territory, así que se quita.
-- Idempotente: se aplica en cada arranque (db/mejoras.sh).
-- =====================================================================
SET search_path = public;

ALTER TABLE public.territory_tracks DROP CONSTRAINT IF EXISTS fk_territory_tempo_id;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_tracks_master_tempo_id') THEN
        ALTER TABLE public.tracks_master DROP CONSTRAINT uq_tracks_master_tempo_id;
    END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS uq_tracks_master_tempo_id ON public.tracks_master (tempo_id)
    WHERE tempo_id ~ '^[0-9]+$';
COMMENT ON INDEX public.uq_tracks_master_tempo_id IS
    'Un Tempo ID numérico pertenece a una sola obra; los marcadores (UNCONTROLLED, COMPILADO) se pueden repetir.';

-- El trigger copiaba el Tempo ID también a territory_control, que exige (tempo_id, pais) único: con un marcador
-- repetido fallaría. Ahí solo se copian los numéricos (los controles son de obras con Tempo ID real).
CREATE OR REPLACE FUNCTION public.trg_sync_tempo_id_to_territory()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
    if new.tempo_id is distinct from old.tempo_id then
        update territory_tracks set tempo_id = new.tempo_id, updated_at = now()
        where track_master_id = new.id;
        if new.tempo_id ~ '^[0-9]+$' then
            update territory_control set tempo_id = new.tempo_id, updated_at = now()
            where track_master_id = new.id;
        end if;
    end if;
    return new;
end;
$function$;
