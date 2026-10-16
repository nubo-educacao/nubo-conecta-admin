-- Fixtures do teste de filtros first-touch do Command Center.
-- Roda DENTRO da transação montada por run_dev.sh e nunca é commitado.
-- UUIDs ccaf…; perfis com nome 'CCAF …'; cliques em 2031 (janela sem dado real).
--
--   campanhas: A, B          divulgadores: X, Y
--   links: L1(A,X) L2(A,Y) L3(B,X) L4(sem campanha,Y) L5(A,X, ARQUIVADO)
--
--   U1 first L1                     → A, X   education EMC, race Parda, Match MEC
--   U2 first L2, last L3            → A, Y   (NÃO conta em B: last-touch)
--   U3 first L3                     → B, X   education EMC, conversa match_workflow
--   U4 first L4                     → Y
--   U5 linha sem first-touch        → sem atribuição
--   U6 sem linha                    → sem atribuição
--   U7 first L5 (link arquivado)    → A, X   (arquivado continua contando)
--
--   Cliques card_click/card em 2031-01-01 na 1ª partner_opportunity com instituição:
--   U1 3 · U2 4 · U3 2 · U6 1 · U7 1 · anônimo 5   (total sem filtro = 16)

DO $guard$
BEGIN
  -- PROD tem milhares de perfis; DEV tem dezenas. Recusa antes de qualquer escrita.
  IF (SELECT count(*) FROM public.user_profiles) > 1000 THEN
    RAISE EXCEPTION 'CCAF_FAIL guard: alvo parece PROD (>1000 perfis); abortando';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.partner_opportunities po JOIN public.institutions i ON i.id = po.institution_id) THEN
    RAISE EXCEPTION 'CCAF_FAIL guard: nenhuma partner_opportunity com instituição no ambiente';
  END IF;
  IF EXISTS (SELECT 1 FROM public.engagement_events WHERE occurred_at >= '2031-01-01' AND occurred_at < '2031-01-02') THEN
    RAISE EXCEPTION 'CCAF_FAIL guard: já há eventos reais na janela de teste (2031-01-01)';
  END IF;
END
$guard$;

CREATE TEMP TABLE ccaf_ctx (k text PRIMARY KEY, v text);
INSERT INTO ccaf_ctx VALUES ('partner',
  (SELECT po.id::text FROM public.partner_opportunities po JOIN public.institutions i ON i.id = po.institution_id
   ORDER BY po.created_at, po.id LIMIT 1));

INSERT INTO public.campaigns (id, slug, name) VALUES
  ('ccaf0000-0000-4000-a000-00000000000a', 'ccaf-a', 'CCAF Campanha A'),
  ('ccaf0000-0000-4000-a000-00000000000b', 'ccaf-b', 'CCAF Campanha B');

INSERT INTO public.channels (id, slug, name, type) VALUES
  ('ccaf0000-0000-4000-b000-00000000000e', 'ccaf-x', 'CCAF Divulgador X', 'crm'),
  ('ccaf0000-0000-4000-b000-00000000000f', 'ccaf-y', 'CCAF Divulgador Y', 'influencer');

INSERT INTO public.channel_links (id, campaign_id, channel_id, code, archived_at) VALUES
  ('ccaf0000-0000-4000-c000-000000000001', 'ccaf0000-0000-4000-a000-00000000000a', 'ccaf0000-0000-4000-b000-00000000000e', 'ccaf-l1', NULL),
  ('ccaf0000-0000-4000-c000-000000000002', 'ccaf0000-0000-4000-a000-00000000000a', 'ccaf0000-0000-4000-b000-00000000000f', 'ccaf-l2', NULL),
  ('ccaf0000-0000-4000-c000-000000000003', 'ccaf0000-0000-4000-a000-00000000000b', 'ccaf0000-0000-4000-b000-00000000000e', 'ccaf-l3', NULL),
  ('ccaf0000-0000-4000-c000-000000000004', NULL,                                   'ccaf0000-0000-4000-b000-00000000000f', 'ccaf-l4', NULL),
  ('ccaf0000-0000-4000-c000-000000000005', 'ccaf0000-0000-4000-a000-00000000000a', 'ccaf0000-0000-4000-b000-00000000000e', 'ccaf-l5', now());

INSERT INTO auth.users (id, is_anonymous)
SELECT ('ccaf0000-0000-4000-d000-00000000000' || n)::uuid, true FROM generate_series(1, 7) n;

INSERT INTO public.user_profiles (id, full_name, education, race) VALUES
  ('ccaf0000-0000-4000-d000-000000000001', 'CCAF U1', 'Ensino Médio Completo', 'Parda'),
  ('ccaf0000-0000-4000-d000-000000000002', 'CCAF U2', 'Ensino Superior Completo', NULL),
  ('ccaf0000-0000-4000-d000-000000000003', 'CCAF U3', 'Ensino Médio Completo', 'Parda'),
  ('ccaf0000-0000-4000-d000-000000000004', 'CCAF U4', NULL, NULL),
  ('ccaf0000-0000-4000-d000-000000000005', 'CCAF U5', NULL, NULL),
  ('ccaf0000-0000-4000-d000-000000000006', 'CCAF U6', NULL, NULL),
  ('ccaf0000-0000-4000-d000-000000000007', 'CCAF U7', NULL, NULL);

INSERT INTO public.user_attribution (user_id, first_touch_link_id, last_touch_link_id, first_touch_at, last_touch_at) VALUES
  ('ccaf0000-0000-4000-d000-000000000001', 'ccaf0000-0000-4000-c000-000000000001', 'ccaf0000-0000-4000-c000-000000000001', now(), now()),
  ('ccaf0000-0000-4000-d000-000000000002', 'ccaf0000-0000-4000-c000-000000000002', 'ccaf0000-0000-4000-c000-000000000003', now(), now()),
  ('ccaf0000-0000-4000-d000-000000000003', 'ccaf0000-0000-4000-c000-000000000003', 'ccaf0000-0000-4000-c000-000000000003', now(), now()),
  ('ccaf0000-0000-4000-d000-000000000004', 'ccaf0000-0000-4000-c000-000000000004', 'ccaf0000-0000-4000-c000-000000000004', now(), now()),
  ('ccaf0000-0000-4000-d000-000000000005', NULL,                                   'ccaf0000-0000-4000-c000-000000000001', NULL,  now()),
  ('ccaf0000-0000-4000-d000-000000000007', 'ccaf0000-0000-4000-c000-000000000005', 'ccaf0000-0000-4000-c000-000000000005', now(), now());

-- Match: U1 com resultado MEC no motor atual; U3 só conversou no match_workflow.
INSERT INTO public.user_opportunity_matches (profile_id, unified_opportunity_id, generated_at) VALUES
  ('ccaf0000-0000-4000-d000-000000000001', 'mec_ccaf_1', '2026-08-01T10:00:00Z');
INSERT INTO public.chat_messages (user_id, workflow, sender, created_at) VALUES
  ('ccaf0000-0000-4000-d000-000000000003', 'match_workflow', 'user', '2026-01-20T12:00:00Z');

INSERT INTO public.engagement_events (event_id, event_type, occurred_at, user_id, anonymous_id, entity_type, entity_id, source, event_count)
SELECT 'ccaf-' || v.k, 'card_click', '2031-01-01T12:00:00Z', v.u::uuid, v.a, 'partner_opportunity',
       (SELECT c.v FROM ccaf_ctx c WHERE c.k = 'partner')::uuid, 'card', v.n
FROM (VALUES
  ('1', 'ccaf0000-0000-4000-d000-000000000001', NULL,        3),
  ('2', 'ccaf0000-0000-4000-d000-000000000002', NULL,        4),
  ('3', 'ccaf0000-0000-4000-d000-000000000003', NULL,        2),
  ('6', 'ccaf0000-0000-4000-d000-000000000006', NULL,        1),
  ('7', 'ccaf0000-0000-4000-d000-000000000007', NULL,        1),
  ('anon', NULL,                                'ccaf-anon', 5)
) AS v(k, u, a, n);

-- Admin de teste para o guard is_backoffice_admin() (auth.uid() lê o JWT).
INSERT INTO auth.users (id) VALUES ('ccaf0000-0000-4000-f000-0000000000ad');
INSERT INTO public.user_permissions (user_id, permission) VALUES
  ('ccaf0000-0000-4000-f000-0000000000ad', 'Controle de usuários');

SELECT set_config('request.jwt.claims', '{"sub":"ccaf0000-0000-4000-f000-0000000000ad","role":"authenticated"}', true);
SELECT set_config('request.jwt.claim.sub', 'ccaf0000-0000-4000-f000-0000000000ad', true);
