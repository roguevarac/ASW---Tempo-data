-- =====================================================================
-- Mejora propia (no viene de Supabase): datos para la pestaña "Historial de cargas" (solo lectura).
-- Resume lo que hay cargado en la base, para mostrarlo junto a los archivos de donde salió.
-- Idempotente: se aplica en cada arranque (db/mejoras.sh).
-- =====================================================================
SET search_path = public;

-- Semanas de chart cargadas, por plataforma y país, con cuántas canciones tiene cada una.
CREATE OR REPLACE FUNCTION public.fn_historial_charts()
 RETURNS TABLE(platform text, pais_code pais_code_enum, snapshot_date date, canciones bigint)
 LANGUAGE sql
 STABLE
AS $function$
    select tt.platform, tt.pais_code, tt.snapshot_date, count(*)
    from territory_tracks tt
    where tt.deleted_at is null
    group by tt.platform, tt.pais_code, tt.snapshot_date
    order by tt.platform, tt.pais_code, tt.snapshot_date desc;
$function$;

-- Obras con datos de cada reporte por país (bo = Reporte BackOffice, tempo = Reporte Tempo Control), y la última vez
-- que cambiaron. tempo_ids: obras de la tabla principal con Tempo ID (sin país).
CREATE OR REPLACE FUNCTION public.fn_historial_reportes()
 RETURNS TABLE(tipo text, pais_code pais_code_enum, obras bigint, actualizado timestamp with time zone)
 LANGUAGE sql
 STABLE
AS $function$
    select 'bo', br.pais_code, count(*), max(br.updated_at)
    from territory_bo_report br where br.deleted_at is null group by br.pais_code
    union all
    select 'tempo', tr.pais_code, count(*), max(tr.updated_at)
    from territory_tempo_report tr where tr.deleted_at is null group by tr.pais_code
    union all
    select 'tempo_ids', null, count(*), max(tm.updated_at)
    from tracks_master tm where tm.deleted_at is null and tm.tempo_id is not null
    order by 1, 2;
$function$;

-- Email de cada usuario, para mostrar quién hizo cada carga (auth.users no se lee directo).
CREATE OR REPLACE FUNCTION public.fn_nombres_usuarios()
 RETURNS TABLE(id text, email text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    select u.id::text, u.email::text from auth.users u order by u.email;
$function$;
REVOKE EXECUTE ON FUNCTION public.fn_nombres_usuarios() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_nombres_usuarios() TO authenticated, service_role;
