-- =====================================================================
-- 01. Roles y extensiones. Se corre como superusuario, una sola vez.
--
-- Roles (los mismos nombres que usaba Supabase, así las políticas no cambian):
--   app_owner      dueño de tablas y funciones. Las funciones SECURITY DEFINER
--                  (auditoría, rol de app, histórico) corren con este rol.
--   authenticator  único rol con login: el que usa la API. Por cada pedido cambia
--                  a authenticated / service_role según quién llame.
--   authenticated  usuario logueado. Le aplican RLS y políticas.
--   service_role   procesos internos (tarea de YouTube, importaciones). Saltea RLS.
--   anon           sin login. No tiene permisos sobre datos.
--   admin, auditor, usuario_estandar: roles que existían en Supabase (permisos heredados).
-- La contraseña de authenticator la define el instalador (ver README).
-- =====================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_owner')        THEN CREATE ROLE app_owner NOLOGIN BYPASSRLS; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator')    THEN CREATE ROLE authenticator LOGIN NOINHERIT; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')             THEN CREATE ROLE anon NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated')    THEN CREATE ROLE authenticated NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role')     THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'admin')            THEN CREATE ROLE admin NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'auditor')          THEN CREATE ROLE auditor NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'usuario_estandar') THEN CREATE ROLE usuario_estandar NOLOGIN; END IF;
END $$;

GRANT anon, authenticated, service_role TO authenticator;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- app_owner crea los objetos de la aplicación
GRANT CREATE, USAGE ON SCHEMA public TO app_owner;
CREATE SCHEMA IF NOT EXISTS auth AUTHORIZATION app_owner;
CREATE SCHEMA IF NOT EXISTS storage AUTHORIZATION app_owner;
