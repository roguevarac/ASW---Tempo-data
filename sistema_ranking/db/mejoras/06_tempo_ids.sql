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
--   6 otra versión    mismo título sin "(Official Video)", "- Sped Up", "(Remastered)", "(Acústico)"... y al menos un
--                     artista en común (los remixes no: pueden ser otra obra)
-- Solo para las filas y las obras que quedan sin coincidencia (y obras sin Tempo ID numérico), por parecido:
--   7 título parecido un artista en común y el título casi igual (una letra de más, de menos o cambiada), con los mismos
--                     números ("Vol. 52" no es "Vol. 53") y la misma condición de remix; una sola obra posible
--   8 artista parecido el mismo título (largo) y el nombre del artista casi igual ("Jhay Cortez" / "Jhayco")
-- Lo que no alcanza esos niveles pero se parece queda en el reporte como sugerencia para revisar a mano.
-- Una fila puede coincidir con varias obras (la misma canción escrita distinto en cada chart): todas reciben el Tempo ID
-- y quedan unificadas en una, como cuando se asigna a mano un Tempo ID repetido.
--
-- Reglas: nunca se pisa un Tempo ID numérico distinto (queda como conflicto). Los marcadores (UNCONTROLLED, PENDING ...;
-- otros valores quedan como VALOR NO VÁLIDO)
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

-- Título sin la versión: "(Official Video)", "[Lyric Video]", "(Sped Up)", "- Slowed + Reverb", "(Remastered 2011)",
-- "(Acústico)", "(Versión ...)", "(Prod. X)". No quita los remixes (pueden tener otros autores).
CREATE OR REPLACE FUNCTION public.fn_clave_titulo_version(p_titulo text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select coalesce(fn_clave_texto(regexp_replace(regexp_replace(regexp_replace(
               regexp_replace(coalesce(p_titulo, ''),
                   '\s*[\(\[]\s*(feat[.,]?|ft[.,]?|featuring|with|con)\s[^\)\]]*[\)\]]', '', 'gi'),
               '\s*[\(\[](?![^\)\]]*(remix|rmx))[^\)\]]*\y(sped|slowed|reverb|remaster\w*|remasteri\w*|edit|ac[uú]stic[oa]?|acoustic|versi[oó]n|version|official|oficial|lyrics?|letra|visuali[sz]er|audio|video|videoclip|clip|explicit|expl[ií]cito|clean|extended|bonus|mono|stereo|est[eé]reo|demo|instrumental|prod)\y[^\)\]]*[\)\]]',
               '', 'gi'),
               '\s+-\s+(?![^-]*(remix|rmx))[^-]*\y(sped|slowed|reverb|remaster\w*|remasteri\w*|edit|ac[uú]stic[oa]?|acoustic|versi[oó]n|version|official|oficial|lyrics?|letra|visuali[sz]er|audio|video|videoclip|explicit|extended|bonus|mono|stereo|demo|instrumental|prod)\y[^-]*$',
               '', 'i'),
               '\s*-?\s*\y(feat[.,]?|ft[.,]?|featuring)\s.*$', '', 'i')),
           fn_clave_titulo_base(p_titulo));
$function$;

-- Trigramas de una clave (como pg_trgm, sin depender de la extensión) y parecido entre dos conjuntos (0 a 1).
CREATE OR REPLACE FUNCTION public.fn_trigramas(p_clave text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select coalesce(array_agg(distinct substr(s, i, 3)), '{}')
    from (select '  ' || coalesce(p_clave, '') || ' ' as s) x, generate_series(1, length(x.s) - 2) i
    where p_clave is not null;
$function$;

CREATE OR REPLACE FUNCTION public.fn_parecido(a text[], b text[])
 RETURNS real
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select case when cardinality(a) = 0 or cardinality(b) = 0 then 0
                else (n::real / (cardinality(a) + cardinality(b) - n)) end
    from (select count(*)::int as n from unnest(a) x where x = any(b)) c;
$function$;

-- Las dos claves difieren en una sola letra (una de más, de menos, cambiada o dos invertidas).
CREATE OR REPLACE FUNCTION public.fn_una_letra(a text, b text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
    i int := 1;
    la int := length(a);
    lb int := length(b);
begin
    if a is null or b is null or abs(la - lb) > 1 then
        return false;
    end if;
    while i <= least(la, lb) and substr(a, i, 1) = substr(b, i, 1) loop
        i := i + 1;
    end loop;
    if la = lb then
        return substr(a, i + 1) = substr(b, i + 1)
            or (substr(a, i, 2) = reverse(substr(b, i, 2)) and substr(a, i + 2) = substr(b, i + 2));
    elsif la > lb then
        return substr(a, i + 1) = substr(b, i);
    end if;
    return substr(a, i) = substr(b, i + 1);
end;
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
        k_base text, k_ver text, k_art text, a_art text[], g_tit text[], g_art text[], firma text) on commit drop;
    create temp table if not exists _ti_obras (id uuid, tempo text, concat text, k_tit text, k_base text, k_ver text,
        k_art text, a_art text[], g_tit text[], g_art text[], firma text) on commit drop;
    create temp table if not exists _ti_parecido (fila int, obra uuid, nivel int, parecido real) on commit drop;
    create temp table if not exists _ti_cand (fila int, obra uuid, nivel int) on commit drop;
    create temp table if not exists _ti_match (fila int, obra uuid, nivel int) on commit drop;
    create temp table if not exists _ti_res (obra uuid, tempo text, resultado text, detalle text) on commit drop;
    truncate _ti_archivo, _ti_obras, _ti_cand, _ti_match, _ti_res, _ti_parecido;

    insert into _ti_archivo
    select (e ->> 'fila')::int, e ->> 'texto', t.tempo, t.marcador,
           fn_clave_texto(e ->> 'titulo'), fn_clave_titulo_base(e ->> 'titulo'), fn_clave_titulo_version(e ->> 'titulo'),
           fn_clave_texto(e ->> 'artistas'), fn_claves_artistas(e ->> 'artistas'), null, null, null
    from jsonb_array_elements(p_filas) e
    cross join lateral (select nullif(upper(trim(coalesce(e ->> 'tempo_id', ''))), '') as v) v
    cross join lateral (select
        case when v.v ~ '^[0-9]+$' then nullif(ltrim(v.v, '0'), '') end as tempo,
        case when v.v is null or v.v ~ '^0+$' then 'vacío'
             when v.v !~ '^[0-9]+$' then coalesce(nullif(fn_tempo_estandar(v.v), ''), '¿' || v.v) end as marcador) t;   -- ¿ = no válido

    insert into _ti_obras
    select tm.id, tm.tempo_id, tm.track_artist_concat, fn_clave_texto(tm.track_name_clean),
           fn_clave_titulo_base(tm.track_name_clean), fn_clave_titulo_version(tm.track_name_clean),
           fn_clave_texto(tm.artist_name_clean), fn_claves_artistas(tm.artist_name_clean), null, null, null
    from tracks_master tm where tm.deleted_at is null;
    create index on _ti_obras (k_tit);
    create index on _ti_obras (k_base);
    create index on _ti_obras (k_ver);
    analyze _ti_archivo; analyze _ti_obras;

    -- Todas las coincidencias posibles.
    insert into _ti_cand
    select * from (
        select a.fila, o.id as obra,
               case when o.k_tit = a.k_tit and o.k_art = a.k_art then 1
                    when o.k_tit = a.k_tit and o.a_art = a.a_art then 2
                    when o.k_tit = a.k_tit and o.a_art && a.a_art then 3
                    when o.k_base = a.k_base and o.a_art && a.a_art then 4
                    when o.k_tit = a.k_tit and cardinality(a.a_art) = 0 then 5
                    when o.k_ver = a.k_ver and o.a_art && a.a_art then 6 end as nivel
        from _ti_archivo a
        join _ti_obras o on o.k_tit = a.k_tit or o.k_base = a.k_base or o.k_ver = a.k_ver
        where a.k_tit is not null
    ) c where c.nivel is not null;
    -- Cada obra que coincide con la fila (niveles 1 a 4) recibe su Tempo ID: son la misma canción escrita distinto en
    -- cada chart. Solo por título, únicamente si la fila no tiene otra coincidencia y hay una sola obra con ese título.
    insert into _ti_match select c.fila, c.obra, c.nivel from _ti_cand c where c.nivel in (1, 2, 3, 4, 6);
    insert into _ti_match
    select c.fila, c.obra, c.nivel from _ti_cand c
    where c.nivel = 5 and not exists (select 1 from _ti_cand x where x.fila = c.fila and x.nivel <> 5)
      and (select count(*) from _ti_cand x where x.fila = c.fila and x.nivel = 5) = 1;

    -- Por parecido: solo filas sin coincidencia y obras sin coincidencia ni Tempo ID numérico.
    -- firma = números del título + si es remix: tienen que ser iguales ("Vol. 52" / "Vol. 53", "X" / "X (Remix)").
    update _ti_archivo a set g_tit = fn_trigramas(a.k_ver), g_art = fn_trigramas(a.k_art),
           firma = coalesce((select string_agg(d[1], ',' order by d[1]) from regexp_matches(a.k_ver, '[0-9]+', 'g') d), '')
                   || case when a.k_tit ~ '(remix|rmx)' then '|remix' else '' end
    where a.k_ver is not null and not exists (select 1 from _ti_match m where m.fila = a.fila);
    update _ti_obras o set g_tit = fn_trigramas(o.k_ver), g_art = fn_trigramas(o.k_art),
           firma = coalesce((select string_agg(d[1], ',' order by d[1]) from regexp_matches(o.k_ver, '[0-9]+', 'g') d), '')
                   || case when o.k_tit ~ '(remix|rmx)' then '|remix' else '' end
    where o.k_ver is not null and coalesce(o.tempo, '') !~ '^[0-9]+$'
      and not exists (select 1 from _ti_match m where m.obra = o.id);
    create index on _ti_obras using gin (a_art);
    analyze _ti_obras;
    insert into _ti_parecido
    select a.fila, o.id, 7, fn_parecido(a.g_tit, o.g_tit)
    from _ti_archivo a join _ti_obras o on o.a_art && a.a_art
    where a.g_tit is not null and o.g_tit is not null
    union all
    select a.fila, o.id, 8, fn_parecido(a.g_art, o.g_art)
    from _ti_archivo a join _ti_obras o on o.k_ver = a.k_ver
    where a.g_tit is not null and o.g_tit is not null and cardinality(a.a_art) > 0 and not (o.a_art && a.a_art);
    -- Se acepta si es la única posible para la fila y la fila es la única para la obra (las demás quedan como sugerencia).
    insert into _ti_match
    select p.fila, p.obra, p.nivel
    from _ti_parecido p join _ti_archivo a on a.fila = p.fila join _ti_obras o on o.id = p.obra
    where a.firma = o.firma
      and ((p.nivel = 7 and p.parecido >= 0.75 and length(a.k_ver) >= 5 and length(o.k_ver) >= 5)
        or (p.nivel = 7 and length(a.k_ver) >= 8 and fn_una_letra(a.k_ver, o.k_ver))
        or (p.nivel = 8 and p.parecido >= 0.5 and length(a.k_ver) >= 8))
      and not exists (select 1 from _ti_parecido x where x.fila = p.fila and x.obra <> p.obra
                      and x.parecido >= p.parecido - 0.1 and x.parecido >= 0.4)
      and not exists (select 1 from _ti_parecido x join _ti_archivo xa on xa.fila = x.fila
                      where x.obra = p.obra and x.fila <> p.fila and x.parecido >= p.parecido - 0.1 and x.parecido >= 0.4
                        and coalesce(xa.tempo, xa.marcador) is distinct from coalesce(a.tempo, a.marcador));

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
        where a.tempo is null and a.marcador <> 'vacío' and a.marcador not like '¿%'
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
    select a.fila, a.texto, coalesce(a.tempo, ltrim(a.marcador, '¿')),
           case when a.tempo is null and a.marcador = 'vacío' then 'SIN TEMPO ID'
                when a.marcador like '¿%' then 'VALOR NO VÁLIDO'
                when not exists (select 1 from _ti_match m where m.fila = a.fila)
                     and exists (select 1 from tracks_master tm where tm.tempo_id = a.tempo) then 'SIN CAMBIOS'
                when not exists (select 1 from _ti_match m where m.fila = a.fila) then 'NO ENCONTRADA'
                else (select r.resultado from _ti_match m join _ti_res r on r.obra = m.obra where m.fila = a.fila
                        and (r.tempo is null or r.tempo = coalesce(a.tempo, a.marcador))
                      order by array_position(array['CARGADO', 'SIN CAMBIOS', 'CONFLICTO', 'CONFLICTO EN EL ARCHIVO'],
                                              r.resultado) limit 1) end,
           (select case min(m.nivel) when 1 then 'exacta' when 2 then 'artistas en otro orden'
                                     when 3 then 'un artista en común' when 4 then 'título sin feat.'
                                     when 5 then 'solo título' when 6 then 'otra versión'
                                     when 7 then 'título parecido' when 8 then 'artista parecido' end
            from _ti_match m where m.fila = a.fila),
           (select string_agg(o.concat || coalesce(' [' || lower(r.resultado) || ']', ''), E'\n' order by o.concat)
            from _ti_match m join _ti_obras o on o.id = m.obra
            left join _ti_res r on r.obra = m.obra and r.resultado like 'CONFLICTO%'
            where m.fila = a.fila),
           case when a.tempo is null and a.marcador = 'vacío' then 'Sin Tempo ID en el archivo'
                when a.marcador like '¿%' then 'Solo se admiten el número o: ' || array_to_string(fn_marcadores_tempo(), ', ')
                when not exists (select 1 from _ti_match m where m.fila = a.fila) then coalesce(
                    (select 'El Tempo ID ya está en "' || tm.track_artist_concat || '"' from tracks_master tm
                     where tm.tempo_id = a.tempo),
                    (select 'Sugerencia para revisar: "' || o.concat || '" (' || round(p.parecido * 100) || ' % parecida)'
                     from _ti_parecido p join _ti_obras o on o.id = p.obra
                     where p.fila = a.fila and p.parecido >= 0.4
                     order by p.parecido desc, o.concat limit 1),
                    'No hay una obra cargada con ese título')
                else (select string_agg(distinct r.detalle, '; ') from _ti_match m join _ti_res r on r.obra = m.obra
                      where m.fila = a.fila and r.detalle is not null
                        and (r.tempo is null or r.tempo = coalesce(a.tempo, a.marcador))) end
    from _ti_archivo a
    order by a.fila;
end;
$function$;
REVOKE ALL ON FUNCTION public.fn_cargar_tempo_ids(jsonb) FROM PUBLIC;   -- solo la consola (ranking.sh)
