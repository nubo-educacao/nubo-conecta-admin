-- 20260723190000_repair_dev_partners_users_fk_drift.sql
--
-- Repara drift entre dev e prod: a migration 20260708150000 marcou
-- 20260617120100/20260617120300 como já aplicadas em schema_migrations
-- (INSERT ... ON CONFLICT DO NOTHING) sem de fato rodar seus ALTER TABLE
-- no banco dev, então partners_users.partner_id ficou apontando para a
-- tabela legada "partners" em vez de partner_institutions(institution_id)
-- (estado correto, confirmado no prod). Isso quebrava a vinculação de
-- usuários de parceiro no preview com erro de FK constraint.
--
-- Idempotente: usa DO blocks para só alterar se o estado atual divergir
-- do esperado, então é seguro rodar em qualquer ambiente (inclusive prod,
-- que já está correto).

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'partners_users_partner_id_fkey'
      AND confrelid = 'public.partners'::regclass
  ) THEN
    ALTER TABLE "public"."partners_users"
      DROP CONSTRAINT "partners_users_partner_id_fkey";

    ALTER TABLE "public"."partners_users"
      ADD CONSTRAINT "partners_users_partner_id_fkey"
      FOREIGN KEY ("partner_id") REFERENCES "public"."partner_institutions"("institution_id") ON DELETE CASCADE;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'partners_users_user_id_fkey'
  ) THEN
    ALTER TABLE "public"."partners_users"
      ADD CONSTRAINT "partners_users_user_id_fkey"
      FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;
  END IF;
END $$;
