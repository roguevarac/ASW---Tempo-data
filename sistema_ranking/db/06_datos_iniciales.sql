-- 06. Fila única del contador de cargas de BO (si no viene en la migración de datos).
INSERT INTO public.bo_export_counter (id, counter) VALUES (true, 0) ON CONFLICT (id) DO NOTHING;
