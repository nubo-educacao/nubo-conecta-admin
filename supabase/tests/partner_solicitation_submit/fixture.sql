-- Réplica das policies REAIS de partner_solicitations em produção, conferidas
-- via pg_policy em 12/08/2026. O ponto do fixture é reproduzir o RLS: sem ele
-- o teste não pega o bug que motivou a RPC (dedupe cego para visitante anônimo).
CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT nullif(current_setting('test.uid', true), '')::uuid $$;

CREATE TABLE public.user_permissions (user_id uuid, permission text);
GRANT SELECT ON public.user_permissions TO anon, authenticated;

CREATE TABLE public.partner_solicitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  institution_name text NOT NULL,
  contact_name text NOT NULL,
  whatsapp text,
  email text,
  how_did_you_know text NOT NULL,
  goals text
);
ALTER TABLE public.partner_solicitations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can view all solicitations" ON public.partner_solicitations FOR SELECT
  USING (EXISTS (SELECT 1 FROM user_permissions WHERE user_id = auth.uid() AND permission='Dashboard'));
CREATE POLICY "Allow full access to service_role" ON public.partner_solicitations FOR ALL
  TO service_role USING (true) WITH CHECK (true);
-- A policy que a migration 20260812120100 remove:
CREATE POLICY "Allow public insert to partner_solicitations" ON public.partner_solicitations
  FOR INSERT WITH CHECK (true);

GRANT SELECT, INSERT ON public.partner_solicitations TO anon, authenticated;
