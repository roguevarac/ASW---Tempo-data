-- =====================================================================
-- 02. Reemplazo propio de Supabase Auth y Storage. Se corre con SET ROLE app_owner.
--
-- auth.uid() funciona igual que en Supabase: la API, en cada pedido, guarda el
-- usuario del token en request.jwt.claims. Así las funciones, valores por defecto
-- (created_by, changed_by) y políticas que usan auth.uid() no cambian.
-- =====================================================================
SET search_path = public;

-- ---------- Usuarios ----------
CREATE TABLE auth.users (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email              text NOT NULL,
    encrypted_password text,                   -- bcrypt (compatible con los hash de Supabase); NULL = sin contraseña, no entra
    created_at         timestamptz NOT NULL DEFAULT now(),
    last_sign_in_at    timestamptz,
    banned_until       timestamptz
);
CREATE UNIQUE INDEX uq_auth_users_email ON auth.users (lower(email));
COMMENT ON TABLE auth.users IS 'Usuarios del sistema. Contraseñas con bcrypt (crypt/gen_salt de pgcrypto).';

CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
    SELECT nullif(coalesce(
        current_setting('request.jwt.claim.sub', true),
        nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'), '')::uuid
$$;
CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
    SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'
$$;
CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;

-- Verifica email y contraseña. Devuelve el id o NULL. Solo la ejecuta la API.
CREATE FUNCTION auth.login(p_email text, p_password text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
    SELECT u.id INTO v_id
    FROM auth.users u
    WHERE lower(u.email) = lower(trim(p_email))
      AND (u.banned_until IS NULL OR u.banned_until < now())
      AND u.encrypted_password = crypt(p_password, u.encrypted_password);
    IF v_id IS NOT NULL THEN
        UPDATE auth.users SET last_sign_in_at = now() WHERE id = v_id;
    END IF;
    RETURN v_id;
END $$;

-- La API lo consulta en cada pedido: un usuario bloqueado o borrado pierde la sesión en el acto.
CREATE FUNCTION auth.usuario_activo(p_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_id AND (u.banned_until IS NULL OR u.banned_until < now()))
$$;

-- Alta o cambio de contraseña (uso administrativo, desde la consola).
CREATE FUNCTION auth.set_password(p_email text, p_password text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
    IF length(coalesce(p_password, '')) < 10 THEN
        RAISE EXCEPTION 'La contraseña debe tener al menos 10 caracteres';
    END IF;
    INSERT INTO auth.users (email, encrypted_password)
    VALUES (lower(trim(p_email)), crypt(p_password, gen_salt('bf', 10)))
    ON CONFLICT (lower(email)) DO UPDATE SET encrypted_password = excluded.encrypted_password
    RETURNING id INTO v_id;
    RETURN v_id;
END $$;

-- ---------- Archivos ----------
-- El contenido va en disco (carpeta de la API); acá queda el registro, con RLS,
-- así las políticas del bucket se aplican igual que en Supabase.
CREATE TABLE storage.buckets (
    id                 text PRIMARY KEY,
    name               text NOT NULL,
    public             boolean NOT NULL DEFAULT false,
    file_size_limit    bigint,
    allowed_mime_types text[],
    created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE storage.objects (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    bucket_id  text NOT NULL REFERENCES storage.buckets(id),
    name       text NOT NULL,
    owner      uuid DEFAULT auth.uid(),
    metadata   jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_storage_objects UNIQUE (bucket_id, name)
);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

INSERT INTO storage.buckets (id, name, public) VALUES ('csv-uploads', 'csv-uploads', false);
