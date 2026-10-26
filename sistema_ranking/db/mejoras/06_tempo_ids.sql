-- =====================================================================
-- Mejora propia (no viene de Supabase): carga masiva de Tempo IDs desde una planilla "Título // Artistas" + Tempo ID
-- (bash ranking.sh cargar-tempo-ids <archivo>). Busca cada obra entre las ya cargadas con la misma normalización que la
-- carga de charts (fn_normalize_text: tildes, "&", versiones en vivo) y, además, sin mayúsculas, signos ni espacios.
--
-- Niveles de coincidencia (se usa el primero que encuentra la obra):
--   1 exacta          mismo título y mismos artistas, en el mismo orden
--   2 artistas        mismo título y mismos artistas, en otro orden
--   3 un artista      mismo título y al menos un artista en común (por ejemplo, Spotify lista más artistas que YouTube)
--   4 sin feat.       mismo título sin "(feat. ...)" / "(with ...)" y al menos un artista en común
--   5 solo título     la fila no trae artistas y hay una sola obra con ese título
-- Una fila puede coincidir con varias obras (la misma canción escrita distinto en cada chart): todas reciben el Tempo ID
-- y quedan unificadas en una, como cuando se asigna a mano un Tempo ID repetido.
--
-- Reglas: nunca se pisa un Tempo ID numérico distinto (queda como conflicto). Los marcadores (UNCONTROLLED, COMPILADO)
-- se cargan en las obras sin Tempo ID numérico (se pueden repetir: 07_marcadores.sql) y nunca unifican obras; si la
-- misma obra recibe un número de otra fila, gana el número. Los vacíos solo se informan.
-- Idempotente: se aplica en cada arranque (db/mejoras.sh).
-- =====================================================================
SET search_path = public;

-- Clave de comparación: normalizada como los charts, en minúsculas, sin tildes, sin signos ni espacios. Conserva letras
-- de cualquier alfabeto (coreano, japonés, cirílico).
CREATE OR REPLACE FUNCTION public.fn_clave_texto(p_texto text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select nullif(regexp_replace(lower(unaccent(coalesce(fn_normalize_text(p_texto), ''))),
                                 '[[:space:][:punct:]¿¡’‘“”´`¨–—…·°«»|/\\]+', '', 'g'), '');
$function$;

-- Artistas como conjunto ordenado de claves ("A, B & C", "A x B", "A feat. B" -> {a, b, c}).
CREATE OR REPLACE FUNCTION public.fn_claves_artistas(p_artistas text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select coalesce(array_agg(distinct k order by k) filter (where k is not null), '{}')
    from regexp_split_to_table(coalesce(fn_normalize_text(p_artistas), ''),
                               '\s*,\s*|\s+(x|feat\.?|ft\.?|featuring|with)\s+', 'i') as a(nombre)
    cross join lateral (select fn_clave_texto(a.nombre) as k) c;
$function$;

-- Título sin los artistas invitados: "(feat. X)", "[with X]", "(ft. X)", " - feat. X", " feat. X" al final.
CREATE OR REPLACE FUNCTION public.fn_clave_titulo_base(p_titulo text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select fn_clave_texto(regexp_replace(regexp_replace(coalesce(p_titulo, ''),
               '\s*[\(\[]\s*(feat[.,]?|ft[.,]?|featuring|with|con)\s[^\)\]]*[\)\]]', '', 'gi'),
               '\s*-?\s*\y(feat[.,]?|ft[.,]?|featuring)\s.*$', '', 'i'));
$function$;

-- p_filas: [{"fila": n, "texto": "...", "titulo": "...", "artistas": "...", "tempo_id": "..."}] (ya limpias por el
-- importador). Devuelve una fila por fila del archivo con el resultado. Aplica los cambios: para simular, llamarla
-- dentro de una transacción que se deshace (ROLLBACK).
CREATE OR REPLACE FUNCTION public.fn_cargar_tempo_ids(p_filas jsonb)
 RETURNS TABLE(fila integer, texto text, tempo_id text, estado text, coincidencia text, obras text, detalle text)
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare
    p record;
    v_otra uuid;
    v_actual text;
begin
    create temp table if not exists _ti_archivo (fila int, texto text, tempo text, marcador text, k_tit text,
        k_base text, k_art text, a_art text[]) on commit drop;
    create temp table if not exists _ti_obras (id uuid, tempo text, concat text, k_tit text, k_base text, k_art text,
        a_art text[]) on commit drop;
    create temp table if not exists _ti_cand (fila int, obra uuid, nivel int) on commit drop;
    create temp table if not exists _ti_match (fila int, obra uuid, nivel int) on commit drop;
    create temp table if not exists _ti_res (obra uuid, tempo text, resultado text, detalle text) on commit drop;
    truncate _ti_archivo, _ti_obras, _ti_cand, _ti_match, _ti_res;

    insert into _ti_archivo
    select (e ->> 'fila')::int, e ->> 'texto', t.tempo, t.marcador,
           fn_clave_texto(e ->> 'titulo'), fn_clave_titulo_base(e ->> 'titulo'),
           fn_clave_texto(e ->> 'artistas'), fn_claves_artistas(e ->> 'artistas')
    from jsonb_array_elements(p_filas) e
    cross join lateral (select nullif(upper(trim(coalesce(e ->> 'tempo_id', ''))), '') as v) v
    cross join lateral (select
        case when v.v ~ '^[0-9]+$' then nullif(ltrim(v.v, '0'), '') end as tempo,
        case when v.v is null or v.v ~ '^0+$' then 'vacío' when v.v !~ '^[0-9]+$' then v.v end as marcador) t;

    insert into _ti_obras
    select tm.id, tm.tempo_id, tm.track_artist_concat, fn_clave_texto(tm.track_name_clean),
           fn_clave_titulo_base(tm.track_name_clean), fn_clave_texto(tm.artist_name_clean),
           fn_claves_artistas(tm.artist_name_clean)
    from tracks_master tm where tm.deleted_at is null;
    create index on _ti_obras (k_tit);
    create index on _ti_obras (k_base);
    analyze _ti_archivo; analyze _ti_obras;

    -- Todas las coincidencias posibles.
    insert into _ti_cand
    select * from (
        select a.fila, o.id as obra,
               case when o.k_tit = a.k_tit and o.k_art = a.k_art then 1
                    when o.k_tit = a.k_tit and o.a_art = a.a_art then 2
                    when o.k_tit = a.k_tit and o.a_art && a.a_art then 3
                    when o.k_base = a.k_base and o.a_art && a.a_art then 4
                    when o.k_tit = a.k_tit and cardinality(a.a_art) = 0 then 5 end as nivel
        from _ti_archivo a
        join _ti_obras o on o.k_tit = a.k_tit or o.k_base = a.k_base
        where a.k_tit is not null
    ) c where c.nivel is not null;
    -- Cada obra que coincide con la fila (niveles 1 a 4) recibe su Tempo ID: son la misma canción escrita distinto en
    -- cada chart. Solo por título, únicamente si la fila no tiene otra coincidencia y hay una sola obra con ese título.
    insert into _ti_match select c.fila, c.obra, c.nivel from _ti_cand c where c.nivel <= 4;
    insert into _ti_match
    select c.fila, c.obra, c.nivel from _ti_cand c
    where c.nivel = 5 and not exists (select 1 from _ti_cand x where x.fila = c.fila and x.nivel <= 4)
      and (select count(*) from _ti_cand x where x.fila = c.fila and x.nivel = 5) = 1;

    -- Una obra que coincide (en cualquier nivel) con filas de Tempo ID distintos: no se carga ninguno.
    insert into _ti_res (obra, tempo, resultado, detalle)
    select c.obra, null, 'CONFLICTO EN EL ARCHIVO',
           'El archivo trae para esta obra los Tempo ID ' || string_agg(distinct a.tempo, ', ')
    from _ti_match c join _ti_archivo a on a.fila = c.fila
    where a.tempo is not null
    group by c.obra having count(distinct a.tempo) > 1;

    -- Asignación, obra por obra (las que ya tienen el Tempo ID en otra obra se unifican con esa).
    for p in
        select distinct on (m.obra) m.obra, a.tempo
        from _ti_match m join _ti_archivo a on a.fila = m.fila
        where a.tempo is not null and m.obra not in (select r.obra from _ti_res r)
        order by m.obra, m.nivel, a.fila
    loop
        select tm.tempo_id into v_actual from tracks_master tm where tm.id = p.obra and tm.deleted_at is null;
        if not found then   -- ya unificada con otra obra en esta misma carga
            insert into _ti_res values (p.obra, p.tempo, 'CARGADO', 'Unificada con otra obra del mismo Tempo ID');
            continue;
        end if;
        if v_actual = p.tempo then
            insert into _ti_res values (p.obra, p.tempo, 'SIN CAMBIOS', 'Ya tenía ese Tempo ID');
        elsif v_actual ~ '^[0-9]+$' then
            insert into _ti_res values (p.obra, p.tempo, 'CONFLICTO', 'Ya tiene el Tempo ID ' || v_actual || ' (no se pisó)');
        else
            select tm.id into v_otra from tracks_master tm where tm.tempo_id = p.tempo and tm.id <> p.obra;
            if v_otra is null then
                update tracks_master set tempo_id = p.tempo, estado_bo = 'ok' where id = p.obra;
                insert into _ti_res values (p.obra, p.tempo, 'CARGADO', null);
            else
                perform unificar_obras(p.obra, v_otra, p.tempo);
                insert into _ti_res values (p.obra, p.tempo, 'CARGADO',
                    'Unificada con "' || (select concat from _ti_obras where id = v_otra) || '" (mismo Tempo ID)');
            end if;
        end if;
    end loop;

    -- Marcadores (UNCONTROLLED, COMPILADO): en las obras sin Tempo ID numérico, después de los números.
    for p in
        select distinct on (m.obra) m.obra, a.marcador as tempo
        from _ti_match m join _ti_archivo a on a.fila = m.fila
        where a.tempo is null and a.marcador <> 'vacío'
          and m.obra not in (select r.obra from _ti_res r where r.resultado like 'CONFLICTO%')
        order by m.obra, m.nivel, a.fila
    loop
        select tm.tempo_id into v_actual from tracks_master tm where tm.id = p.obra and tm.deleted_at is null;
        if not found then
            insert into _ti_res values (p.obra, p.tempo, 'SIN CAMBIOS',
                'La obra quedó unificada con otra que tiene Tempo ID numérico; el marcador no se carga');
        elsif v_actual = p.tempo then
            insert into _ti_res values (p.obra, p.tempo, 'SIN CAMBIOS', 'Ya tenía ese marcador');
        elsif v_actual ~ '^[0-9]+$' then
            insert into _ti_res values (p.obra, p.tempo, 'SIN CAMBIOS',
                'Tiene el Tempo ID ' || v_actual || '; el marcador no se carga');
        else
            update tracks_master
            set tempo_id = p.tempo,
                estado_bo = case when p.tempo = 'UNCONTROLLED' then 'uncontrolled'::estado_bo_enum else estado_bo end
            where id = p.obra;
            insert into _ti_res values (p.obra, p.tempo, 'CARGADO', null);
        end if;
    end loop;

    return query
    select a.fila, a.texto, coalesce(a.tempo, a.marcador),
           case when a.tempo is null and a.marcador = 'vacío' then 'SIN TEMPO ID'
                when not exists (select 1 from _ti_match m where m.fila = a.fila)
                     and exists (select 1 from tracks_master tm where tm.tempo_id = a.tempo) then 'SIN CAMBIOS'
                when not exists (select 1 from _ti_match m where m.fila = a.fila) then 'NO ENCONTRADA'
                else (select r.resultado from _ti_match m join _ti_res r on r.obra = m.obra where m.fila = a.fila
                        and (r.tempo is null or r.tempo = coalesce(a.tempo, a.marcador))
                      order by array_position(array['CARGADO', 'SIN CAMBIOS', 'CONFLICTO', 'CONFLICTO EN EL ARCHIVO'],
                                              r.resultado) limit 1) end,
           (select case min(m.nivel) when 1 then 'exacta' when 2 then 'artistas en otro orden'
                                     when 3 then 'un artista en común' when 4 then 'título sin feat.'
                                     when 5 then 'solo título' end
            from _ti_match m where m.fila = a.fila),
           (select string_agg(o.concat || coalesce(' [' || lower(r.resultado) || ']', ''), E'\n' order by o.concat)
            from _ti_match m join _ti_obras o on o.id = m.obra
            left join _ti_res r on r.obra = m.obra and r.resultado like 'CONFLICTO%'
            where m.fila = a.fila),
           case when a.tempo is null and a.marcador = 'vacío' then 'Sin Tempo ID en el archivo'
                when not exists (select 1 from _ti_match m where m.fila = a.fila) then coalesce(
                    (select 'El Tempo ID ya está en "' || tm.track_artist_concat || '"' from tracks_master tm
                     where tm.tempo_id = a.tempo), 'No hay una obra cargada con ese título')
                else (select string_agg(distinct r.detalle, '; ') from _ti_match m join _ti_res r on r.obra = m.obra
                      where m.fila = a.fila and r.detalle is not null
                        and (r.tempo is null or r.tempo = coalesce(a.tempo, a.marcador))) end
    from _ti_archivo a
    order by a.fila;
end;
$function$;
REVOKE ALL ON FUNCTION public.fn_cargar_tempo_ids(jsonb) FROM PUBLIC;   -- solo la consola (ranking.sh)
