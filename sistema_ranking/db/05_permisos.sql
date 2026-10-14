-- =====================================================================
-- 05. Permisos. Se corre como superusuario después de 01-04.
--
-- Igual que Supabase salvo dos correcciones de seguridad:
--   1. anon (sin login) NO tiene permisos. En Supabase tenía todos los permisos
--      sobre las vistas vw_* y bo_export_counter, y como su clave está en el HTML,
--      cualquiera podía leer (y modificar vía vistas) sin usuario.
--   2. Las vistas respetan RLS (security_invoker, ver 03).
-- =====================================================================
GRANT USAGE ON SCHEMA public, auth, storage TO authenticated, service_role;
GRANT USAGE ON SCHEMA public TO admin, auditor, usuario_estandar;

-- authenticated: como en Supabase (RLS y políticas limitan lo que ve y toca)
GRANT ALL ON public.app_users, public.audit_logs, public.bo_export_counter, public.csv_uploads,
             public.territory_bo_report, public.territory_control, public.territory_tempo_report,
             public.territory_tracks, public.tracks_master,
             public.vw_territory_control_full, public.vw_territory_control_full_all,
             public.vw_territory_full, public.vw_territory_full_all,
             public.vw_territory_tracks_active, public.vw_tracks_master_active
      TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;
GRANT SELECT, INSERT ON storage.objects TO authenticated;
GRANT SELECT ON storage.buckets TO authenticated;

-- service_role: todo (saltea RLS por el atributo BYPASSRLS)
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT ALL ON storage.objects, storage.buckets TO service_role;
GRANT SELECT ON auth.users TO service_role;   -- lo necesita vw_notification_emails

-- Roles heredados de Supabase (mismos permisos que allá)
GRANT ALL ON public.audit_logs, public.territory_tracks, public.tracks_master TO admin;
GRANT SELECT ON public.audit_logs, public.territory_tracks, public.tracks_master,
                public.vw_territory_tracks_active, public.vw_tracks_master_active TO auditor;
GRANT SELECT, INSERT, UPDATE ON public.territory_tracks, public.tracks_master TO usuario_estandar;
GRANT SELECT ON public.vw_territory_tracks_active, public.vw_tracks_master_active TO usuario_estandar;

-- anon: nada
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;

-- Login: solo la API puede verificar contraseñas; nadie lee auth.users directo
REVOKE ALL ON auth.users FROM PUBLIC, authenticated, anon;
REVOKE EXECUTE ON FUNCTION auth.login(text, text), auth.set_password(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION auth.login(text, text) TO authenticator;
GRANT USAGE ON SCHEMA auth TO authenticator;
REVOKE EXECUTE ON FUNCTION auth.usuario_activo(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION auth.usuario_activo(uuid) TO authenticated, service_role;
