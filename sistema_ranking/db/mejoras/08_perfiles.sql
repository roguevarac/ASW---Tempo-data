-- =====================================================================
-- Mejora propia (no viene de Supabase): dos perfiles de uso (pedido del usuario, 27/10/2026).
--   * Usuario estándar: carga, edición de Tempo ID y estados, descargas.
--   * Administrador: lo mismo y, además, el Panel de control (panel.acceso).
-- El front ya no ofrece el rol "auditor" (solo lectura) ni "Ver eliminados". Los usuarios que tenían ese rol pasan a
-- usuario estándar. Los roles internos de app_users se mantienen (admin / usuario_estandar) por compatibilidad.
-- Idempotente: se aplica en cada arranque (db/mejoras.sh).
-- =====================================================================
SET search_path = public;

UPDATE public.app_users SET app_role = 'usuario_estandar' WHERE app_role = 'auditor';
