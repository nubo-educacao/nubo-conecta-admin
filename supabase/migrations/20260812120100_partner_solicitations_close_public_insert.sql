-- TP-5 5b (correção, parte 2) — card 7410a5bc
--
-- Fecha a porta que tornava o rate limit contornável.
--
-- `Allow public insert to partner_solicitations` tem WITH CHECK true e não
-- restringe role: qualquer um com a anon key — que está no bundle do front —
-- podia inserir linhas direto, sem passar por validação, deduplicação ou
-- throttle. Com ela de pé, o limite da migration anterior seria apenas uma
-- sugestão: bastaria não usar a RPC.
--
-- Com esta migration, submit_partner_solicitation() passa a ser o único caminho
-- de escrita para quem não é admin nem service_role.
--
-- ⚠️ QUEBRA INTENCIONAL: o nubo-hub-app (legado) inseria direto do browser,
--    via services/supabase/partner-solicitations.ts. Se aquele formulário ainda
--    estiver no ar em algum lugar, ele para de funcionar aqui — e é esse o
--    objetivo. O formulário vivo passa a ser o do nubo-conecta-app.
--    Último commit do legado: 06/05/2026. Última solicitação recebida:
--    20/05/2026. Aplicação autorizada explicitamente.
--
-- Reversível numa linha, se necessário:
--   CREATE POLICY "Allow public insert to partner_solicitations"
--     ON public.partner_solicitations FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS "Allow public insert to partner_solicitations"
  ON public.partner_solicitations;

-- As outras duas policies permanecem intactas e não são recriadas aqui:
--   "Admins can view all solicitations"  (SELECT, permission = 'Dashboard')
--   "Allow full access to service_role"  (ALL)

DO $acl$
BEGIN
  -- INSERT direto na tabela deixa de ser alcançável por anon/authenticated.
  -- A RPC é SECURITY DEFINER e escreve como owner, então segue funcionando.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE INSERT ON TABLE public.partner_solicitations FROM anon';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'REVOKE INSERT ON TABLE public.partner_solicitations FROM authenticated';
  END IF;
END
$acl$;
