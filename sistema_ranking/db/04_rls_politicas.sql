-- GENERADO por generar_esquema.py desde esquema_supabase.csv. No editar a mano.

ALTER TABLE public.app_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY; ALTER TABLE public.audit_logs FORCE ROW LEVEL SECURITY;
ALTER TABLE public.bo_export_counter ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.csv_uploads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.resultado_tempo_historico ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staging_tempo_historico ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.territory_bo_report ENABLE ROW LEVEL SECURITY; ALTER TABLE public.territory_bo_report FORCE ROW LEVEL SECURITY;
ALTER TABLE public.territory_control ENABLE ROW LEVEL SECURITY; ALTER TABLE public.territory_control FORCE ROW LEVEL SECURITY;
ALTER TABLE public.territory_tempo_report ENABLE ROW LEVEL SECURITY; ALTER TABLE public.territory_tempo_report FORCE ROW LEVEL SECURITY;
ALTER TABLE public.territory_tracks ENABLE ROW LEVEL SECURITY; ALTER TABLE public.territory_tracks FORCE ROW LEVEL SECURITY;
ALTER TABLE public.tracks_master ENABLE ROW LEVEL SECURITY; ALTER TABLE public.tracks_master FORCE ROW LEVEL SECURITY;

CREATE POLICY app_users_self_read ON public.app_users AS PERMISSIVE FOR SELECT TO authenticated USING ((user_id = auth.uid()));
CREATE POLICY audit_logs_insert ON public.audit_logs AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY audit_logs_select ON public.audit_logs AS PERMISSIVE FOR SELECT TO authenticated USING ((fn_app_role() = ANY (ARRAY['admin'::text, 'auditor'::text])));
CREATE POLICY bo_export_counter_rw ON public.bo_export_counter AS PERMISSIVE FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY csv_uploads_insert ON public.csv_uploads AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY csv_uploads_select ON public.csv_uploads AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY territory_bo_report_delete ON public.territory_bo_report AS PERMISSIVE FOR DELETE TO authenticated USING ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text])));
CREATE POLICY territory_bo_report_insert ON public.territory_bo_report AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text])));
CREATE POLICY territory_bo_report_select ON public.territory_bo_report AS PERMISSIVE FOR SELECT TO authenticated USING (((deleted_at IS NULL) OR (fn_app_role() = 'admin'::text)));
CREATE POLICY territory_bo_report_update ON public.territory_bo_report AS PERMISSIVE FOR UPDATE TO authenticated USING ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text]))) WITH CHECK ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text])));
CREATE POLICY territory_control_insert ON public.territory_control AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text])));
CREATE POLICY territory_control_select ON public.territory_control AS PERMISSIVE FOR SELECT TO authenticated USING (((deleted_at IS NULL) OR (fn_app_role() = 'admin'::text)));
CREATE POLICY territory_control_update ON public.territory_control AS PERMISSIVE FOR UPDATE TO authenticated USING ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text]))) WITH CHECK ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text])));
CREATE POLICY territory_tempo_report_delete ON public.territory_tempo_report AS PERMISSIVE FOR DELETE TO authenticated USING ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text])));
CREATE POLICY territory_tempo_report_insert ON public.territory_tempo_report AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text])));
CREATE POLICY territory_tempo_report_select ON public.territory_tempo_report AS PERMISSIVE FOR SELECT TO authenticated USING (((deleted_at IS NULL) OR (fn_app_role() = 'admin'::text)));
CREATE POLICY territory_tempo_report_update ON public.territory_tempo_report AS PERMISSIVE FOR UPDATE TO authenticated USING ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text]))) WITH CHECK ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text])));
CREATE POLICY territory_delete ON public.territory_tracks AS PERMISSIVE FOR DELETE TO authenticated USING ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text])));
CREATE POLICY territory_insert ON public.territory_tracks AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text])));
CREATE POLICY territory_select ON public.territory_tracks AS PERMISSIVE FOR SELECT TO authenticated USING (((deleted_at IS NULL) OR (fn_app_role() = 'admin'::text)));
CREATE POLICY territory_update ON public.territory_tracks AS PERMISSIVE FOR UPDATE TO authenticated USING ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text]))) WITH CHECK ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text])));
CREATE POLICY tracks_master_delete ON public.tracks_master AS PERMISSIVE FOR DELETE TO authenticated USING ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text])));
CREATE POLICY tracks_master_insert ON public.tracks_master AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text])));
CREATE POLICY tracks_master_select ON public.tracks_master AS PERMISSIVE FOR SELECT TO authenticated USING (((deleted_at IS NULL) OR (fn_app_role() = 'admin'::text)));
CREATE POLICY tracks_master_update ON public.tracks_master AS PERMISSIVE FOR UPDATE TO authenticated USING ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text]))) WITH CHECK ((fn_app_role() = ANY (ARRAY['admin'::text, 'usuario_estandar'::text])));

-- Archivos (storage.objects): mismas políticas que el bucket de Supabase
CREATE POLICY csv_uploads_storage_insert ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((bucket_id = 'csv-uploads'::text));
CREATE POLICY csv_uploads_storage_select ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated USING ((bucket_id = 'csv-uploads'::text));
