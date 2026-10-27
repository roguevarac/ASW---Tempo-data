-- =====================================================================
-- Mejora propia (no viene de Supabase): limpieza de textos y valores estándar (27/10/2026).
--
-- * Tildes mal codificadas: un archivo UTF-8 leído como Windows-1252 deja "Ã¡" en lugar de "á" y "â€¦" en lugar de
--   "…". Como después se quitan las tildes, quedaba "3 PECADOS DESPUESa€¦" además de "3 PECADOS DESPUES...". La
--   normalización ahora repara la codificación antes de limpiar y escribe "…" como "...".
-- * Las obras ya cargadas se vuelven a normalizar; si dos quedan con el mismo nombre, se unifican (si tienen Tempo ID
--   numéricos distintos quedan separadas). Los alias de obras unificadas se recalculan igual.
-- * Los Tempo ID existentes que equivalen a un valor estándar se escriben igual ("uncontrolled" -> "UNCONTROLLED").
-- Idempotente: se aplica en cada arranque (db/mejoras.sh); la segunda vez no encuentra nada que corregir.
-- =====================================================================
SET search_path = public;

-- Repara la codificación: el texto completo si se puede; si no, cada secuencia ("Ã¡", "â€¦") por separado. Deja igual
-- lo que no es una secuencia rota ("BATIDÃO", coreano, cirílico).
CREATE OR REPLACE FUNCTION public.fn_reparar_texto(p_texto text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
    v text := p_texto;
    m text[];
    r text;
    -- caracteres que Windows-1252 muestra para los bytes 0x80-0xBF
    cola constant text := '[€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ' || chr(129) || chr(141) || chr(143) || chr(144) || chr(157) || chr(160) || '-¿]';
begin
    if v is null or v !~ ('[ÃÂâ]' || cola) then
        return v;
    end if;
    begin
        r := convert_from(convert_to(v, 'WIN1252'), 'UTF8');
        if r is not null then return r; end if;
    exception when others then
        null;
    end;
    for m in select regexp_matches(v, '(â' || cola || cola || '|[ÃÂ]' || cola || ')', 'g') loop
        begin
            v := replace(v, m[1], convert_from(convert_to(m[1], 'WIN1252'), 'UTF8'));
        exception when others then
            null;
        end;
    end loop;
    return v;
end;
$function$;

-- La normalización de los charts (03_esquema), con la codificación reparada y "…" como "...".
CREATE OR REPLACE FUNCTION public.fn_normalize_text(p_input text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
    v_text text;
begin
    if p_input is null then
        return null;
    end if;

    v_text := replace(fn_reparar_texto(p_input), '…', '...');

    -- Proteger "¿" y "¡" de unaccent (los convierte en "?" y "!").
    v_text := replace(v_text, '¿', chr(1));
    v_text := replace(v_text,  '¡', chr(2));

    v_text := unaccent(v_text);

    v_text := regexp_replace(v_text, '\s*&\s*', ', ', 'g');

    -- (En vivo) / [Live Session] / (Grabado en vivo) ...
    v_text := regexp_replace(v_text, '\s*[\(\[][^\)\]]*\y(en\s+vivo|vivo|live)\y[^\)\]]*[\)\]]\s*', ' ', 'gi');

    -- Segmento entre guiones que arranca con en vivo/live, con o sin
    -- texto extra: "A - En Vivo Gran Rex - B" -> "A - B"
    v_text := regexp_replace(v_text, '\s*-\s*(en\s+vivo|vivo|live)\y[^-]*\s*-\s*', ' - ', 'gi');

    -- Lo mismo al final del título: "A - En Vivo en la Plaza..." -> "A"
    v_text := regexp_replace(v_text, '\s*-\s*(en\s+vivo|vivo|live)\y[^-]*$', '', 'gi');

    v_text := regexp_replace(v_text, '\s+', ' ', 'g');
    v_text := trim(v_text);

    v_text := replace(v_text, chr(1), '¿');
    v_text := replace(v_text, chr(2), '¡');

    return v_text;
end;
$function$;

-- Obras ya cargadas: volver a normalizar y unificar las que quedan iguales.
DO $$
DECLARE
    r record;
    v_t text;
    v_a text;
    v_otra uuid;
BEGIN
    FOR r IN
        SELECT id, track_name_raw, artist_name_raw FROM public.tracks_master
        WHERE deleted_at IS NULL
          AND (track_name_clean IS DISTINCT FROM fn_normalize_text(track_name_raw)
               OR artist_name_clean IS DISTINCT FROM fn_normalize_text(artist_name_raw))
        ORDER BY created_at
    LOOP
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM public.tracks_master WHERE id = r.id AND deleted_at IS NULL);
        v_t := fn_normalize_text(r.track_name_raw);
        v_a := fn_normalize_text(r.artist_name_raw);
        SELECT id INTO v_otra FROM public.tracks_master
        WHERE deleted_at IS NULL AND id <> r.id
          AND lower(track_name_clean) = lower(v_t) AND lower(artist_name_clean) = lower(v_a);
        IF v_otra IS NULL THEN
            UPDATE public.tracks_master SET track_name_raw = track_name_raw WHERE id = r.id;   -- el trigger normaliza
        ELSE
            PERFORM fusionar_obras(r.id, v_otra);   -- con Tempo ID numéricos distintos no hace nada
        END IF;
    END LOOP;
    UPDATE public.obra_alias a SET clave = x.nueva
    FROM (SELECT clave, lower(fn_normalize_text(track_raw) || ' - ' || fn_normalize_text(artist_raw)) AS nueva
          FROM public.obra_alias) x
    WHERE a.clave = x.clave AND x.nueva <> x.clave
      AND NOT EXISTS (SELECT 1 FROM public.obra_alias b WHERE b.clave = x.nueva);
END $$;

-- Tempo ID existentes escritos distinto de un valor estándar.
UPDATE public.tracks_master tm SET tempo_id = fn_tempo_estandar(tm.tempo_id)
WHERE tm.tempo_id IS NOT NULL AND fn_tempo_estandar(tm.tempo_id) IS NOT NULL AND fn_tempo_estandar(tm.tempo_id) <> ''
  AND fn_tempo_estandar(tm.tempo_id) <> tm.tempo_id
  AND NOT EXISTS (SELECT 1 FROM public.tracks_master o WHERE o.id <> tm.id AND o.tempo_id = fn_tempo_estandar(tm.tempo_id)
                  AND o.tempo_id ~ '^[0-9]+$');
