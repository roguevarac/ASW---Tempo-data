-- =====================================================================
-- Mejora propia (no viene de Supabase): la misma obra escrita de otra forma (pedido del usuario, 16/11/2026).
--
--  * Invitados en el título: "Danza Kuduro (feat. Lucenzo) - Don Omar" y "Danza Kuduro - Don Omar, Lucenzo" son la
--    misma obra. fn_clave_obra compara el título sin "(feat. X)" / "(with X)" / "(con X)" / "feat. X" y el conjunto de
--    artistas, sumando los invitados del título. También ignora mayúsculas, signos y comillas.
--  * Artista incompleto: algunos charts traen la lista de artistas con un nombre vacío (", Myke Towers" en lugar de
--    "Eladio Carrión, Myke Towers"). Esa fila es la obra del mismo título cuyos artistas incluyen a los indicados, si
--    hay una sola.
-- Las cargas de charts (fn_upsert_ranking_row, en 04) usan misma_obra: el nombre nuevo queda como nombre unificado de la
-- obra que ya existe. Las obras ya cargadas se unifican abajo (con Tempo ID numéricos distintos quedan separadas) y, si
-- el nombre principal tiene el artista incompleto, pasa a ser principal el nombre completo.
-- Idempotente: se aplica en cada arranque (db/mejoras.sh).
-- =====================================================================
SET search_path = public;

-- Los invitados que figuran en el título: "(feat. A & B)", "[with C]", "(con D)", " feat. E" al final.
CREATE OR REPLACE FUNCTION public.fn_invitados_titulo(p_titulo text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select nullif(concat_ws(', ',
        (select string_agg(m[2], ', ')
         from regexp_matches(coalesce(p_titulo, ''), '[\(\[]\s*(feat[.,]?|ft[.,]?|featuring|with|con)\s+([^\)\]]*)[\)\]]', 'gi') m),
        (select m[2]
         from regexp_matches(regexp_replace(coalesce(p_titulo, ''), '[\(\[][^\)\]]*[\)\]]', '', 'g'),
                             '\s-?\s*\y(feat[.,]?|ft[.,]?|featuring)\s+(.*)$', 'i') m)), '');
$function$;

-- Los artistas de una obra (los del campo artista más los invitados del título), como claves ordenadas.
CREATE OR REPLACE FUNCTION public.fn_artistas_obra(p_titulo text, p_artistas text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select coalesce(array_agg(distinct x order by x), '{}')
    from unnest(fn_claves_artistas(p_artistas) || fn_claves_artistas(fn_invitados_titulo(p_titulo))) x;
$function$;

-- Clave de una obra para reconocerla escrita de otra forma: título sin invitados | artistas (con los invitados).
-- Con search_path fijo: la usa un índice, y PostgreSQL 17 arma los índices con un search_path restringido.
CREATE OR REPLACE FUNCTION public.fn_clave_obra(p_titulo text, p_artistas text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
    select coalesce(fn_clave_titulo_base(p_titulo), '') || '|' || array_to_string(fn_artistas_obra(p_titulo, p_artistas), ',');
$function$;

-- La lista de artistas tiene un nombre vacío (", Myke Towers", "A, , B", "A,").
CREATE OR REPLACE FUNCTION public.fn_artista_incompleto(p_artistas text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select coalesce(p_artistas, '') ~ '^\s*[,&]|[,&]\s*[,&]|[,&]\s*$';
$function$;

CREATE INDEX IF NOT EXISTS ix_tracks_master_clave_obra ON public.tracks_master (fn_clave_obra(track_name_clean, artist_name_clean))
    WHERE deleted_at IS NULL;

-- La obra ya cargada que es esta misma (título y artista tal como llegan), o NULL si no hay una sola.
CREATE OR REPLACE FUNCTION public.misma_obra(p_titulo text, p_artistas text)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
    v_t text := fn_normalize_text(p_titulo);
    v_a text := fn_normalize_text(p_artistas);
    v_ids uuid[];
    v_artistas text[];
begin
    select array_agg(id) into v_ids from (
        select tm.id from tracks_master tm
        where tm.deleted_at is null and fn_clave_obra(tm.track_name_clean, tm.artist_name_clean) = fn_clave_obra(v_t, v_a)
        limit 2) x;
    if cardinality(v_ids) = 1 then
        return v_ids[1];
    end if;
    if fn_artista_incompleto(p_artistas) then
        v_artistas := fn_artistas_obra(v_t, v_a);
        if cardinality(v_artistas) > 0 then
            select array_agg(id) into v_ids from (
                select tm.id from tracks_master tm
                where tm.deleted_at is null
                  and fn_clave_titulo_base(tm.track_name_clean) = fn_clave_titulo_base(v_t)
                  and fn_artistas_obra(tm.track_name_clean, tm.artist_name_clean) @> v_artistas
                  and not fn_artista_incompleto(tm.artist_name_raw)
                limit 2) x;
            if cardinality(v_ids) = 1 then
                return v_ids[1];
            end if;
        end if;
    end if;
    return null;
end;
$function$;
REVOKE ALL ON FUNCTION public.misma_obra(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.misma_obra(text, text) TO authenticated;

-- Para la carga de un chart: si el nombre es otra forma de escribir una obra ya cargada, lo registra como nombre
-- unificado de esa obra (con sus streams por nombre) y la devuelve; si no, NULL.
CREATE OR REPLACE FUNCTION public.vincular_misma_obra(p_titulo text, p_artistas text, p_clave text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_obra uuid := misma_obra(p_titulo, p_artistas);
begin
    if v_obra is not null then
        perform fn_partes_iniciales(v_obra);
        insert into obra_alias (clave, track_raw, artist_raw, track_master_id)
        values (p_clave, p_titulo, p_artistas, v_obra)
        on conflict (clave) do nothing;
    end if;
    return v_obra;
end;
$function$;
REVOKE ALL ON FUNCTION public.vincular_misma_obra(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.vincular_misma_obra(text, text, text) TO authenticated;

-- Obras ya cargadas.
DO $$
DECLARE
    g record;
    o uuid;
    r record;
    v_destino uuid;
    v_alias text;
BEGIN
    -- 1) Misma clave: se unifican en la que tiene Tempo ID numérico (si no, la más antigua).
    FOR g IN
        SELECT array_agg(id ORDER BY (coalesce(tempo_id, '') ~ '^[0-9]+$') DESC, created_at, id) AS ids
        FROM public.tracks_master
        WHERE deleted_at IS NULL
        GROUP BY fn_clave_obra(track_name_clean, artist_name_clean)
        HAVING count(*) > 1
    LOOP
        FOREACH o IN ARRAY g.ids[2:] LOOP
            IF EXISTS (SELECT 1 FROM public.tracks_master WHERE id = o AND deleted_at IS NULL)
               AND EXISTS (SELECT 1 FROM public.tracks_master WHERE id = g.ids[1] AND deleted_at IS NULL) THEN
                PERFORM fusionar_obras(o, g.ids[1]);   -- con Tempo ID numéricos distintos no hace nada
            END IF;
        END LOOP;
    END LOOP;

    -- 2) Artista incompleto: se unifica con la obra del mismo título que tiene la lista completa (si hay una sola).
    FOR r IN SELECT id, track_name_raw, artist_name_raw FROM public.tracks_master
             WHERE deleted_at IS NULL AND fn_artista_incompleto(artist_name_raw) ORDER BY created_at
    LOOP
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM public.tracks_master WHERE id = r.id AND deleted_at IS NULL);
        v_destino := misma_obra(r.track_name_raw, r.artist_name_raw);
        IF v_destino IS NOT NULL AND v_destino <> r.id THEN
            PERFORM fusionar_obras(r.id, v_destino);
        END IF;
    END LOOP;

    -- 3) Nombre principal con el artista incompleto y un nombre unificado completo: pasa a ser principal el completo.
    FOR r IN SELECT tm.id, tm.track_name_clean, tm.artist_name_clean FROM public.tracks_master tm
             WHERE tm.deleted_at IS NULL AND fn_artista_incompleto(tm.artist_name_raw)
    LOOP
        SELECT a.clave INTO v_alias FROM public.obra_alias a
        WHERE a.track_master_id = r.id AND NOT fn_artista_incompleto(a.artist_raw)
          AND fn_clave_titulo_base(a.track_raw) = fn_clave_titulo_base(r.track_name_clean)
          AND fn_artistas_obra(a.track_raw, a.artist_raw) @> fn_artistas_obra(r.track_name_clean, r.artist_name_clean)
        ORDER BY cardinality(fn_artistas_obra(a.track_raw, a.artist_raw)) DESC, a.created_at
        LIMIT 1;
        IF v_alias IS NOT NULL THEN
            PERFORM poner_nombre_principal(r.id, v_alias);
        END IF;
    END LOOP;
END $$;
