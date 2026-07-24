-- 20260724170000_create_partner_postgres_role_dev.sql
--
-- O login do Portal do Parceiro falhava no dev com "role \"partner\" does not
-- exist" (erro 22023) para QUALQUER usuário com auth.users.role = 'partner'
-- (setado por set_partner_role_and_link). PostgREST faz SET ROLE "partner" a
-- partir do claim do JWT — se o role não existe como objeto do Postgres, a
-- request inteira falha antes mesmo de rodar RLS/RPC.
--
-- Confirmado via pg_roles/pg_auth_members que esse role EXISTE em prod
-- (NOLOGIN, membro de authenticated; postgres e authenticator são membros
-- dele) mas nunca foi criado no dev — descompasso de infraestrutura, não de
-- schema de tabela. Reproduz exatamente essa estrutura no dev.
--
-- Idempotente: seguro rodar em qualquer ambiente, inclusive prod (onde já
-- existe e os IF NOT EXISTS não farão nada).

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'partner') THEN
    CREATE ROLE partner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_auth_members am
    JOIN pg_roles r ON r.oid = am.roleid
    JOIN pg_roles m ON m.oid = am.member
    WHERE r.rolname = 'authenticated' AND m.rolname = 'partner'
  ) THEN
    GRANT authenticated TO partner;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_auth_members am
    JOIN pg_roles r ON r.oid = am.roleid
    JOIN pg_roles m ON m.oid = am.member
    WHERE r.rolname = 'partner' AND m.rolname = 'authenticator'
  ) THEN
    GRANT partner TO authenticator;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_auth_members am
    JOIN pg_roles r ON r.oid = am.roleid
    JOIN pg_roles m ON m.oid = am.member
    WHERE r.rolname = 'partner' AND m.rolname = 'postgres'
  ) THEN
    GRANT partner TO postgres;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
