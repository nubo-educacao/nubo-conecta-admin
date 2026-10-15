-- Fixtures do teste de filtros first-touch (TP-7 / NHB-123b).
-- Roda DENTRO da transação montada por run-dev.sh e nunca é commitado.
-- Todos os perfis têm nome 'TP7FX …' para isolar as asserções dos dados reais.
--
--   campanhas: A, B          divulgadores: X, Y
--   links: L1(A,X) L2(A,Y) L3(B,X) L4(sem campanha,Y)
--
--   U1 first L1 = last L1                 → A, X
--   U2 first L2, last L3                  → A, Y   (NÃO conta em B: last-touch)
--   U3 first L3                           → B, X
--   U4 first L4                           → Y
--   U5 linha em user_attribution sem first-touch (só last L1) → sem atribuição
--   U6 sem linha em user_attribution      → sem atribuição
--   U7 first L1, renda só em user_income  → A, X
--
--   Inscrições: U1 ×2, U3 ×1, U6 ×1

-- Drift conhecido (15/10/2026): PROD tem user_profiles.phone e o DEV não — a
-- get_students_paginated atual já falha no DEV com 42703 por isso. Espelha o
-- shape de PROD só dentro desta transação; não é correção do DEV.
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS phone text;

INSERT INTO public.campaigns (id, slug, name) VALUES
  ('7f000000-0000-4000-a000-00000000000a', 'tp7fx-a', 'TP7FX Campanha A'),
  ('7f000000-0000-4000-a000-00000000000b', 'tp7fx-b', 'TP7FX Campanha B');

INSERT INTO public.channels (id, slug, name, type) VALUES
  ('7f000000-0000-4000-b000-00000000000e', 'tp7fx-x', 'TP7FX Divulgador X', 'crm'),
  ('7f000000-0000-4000-b000-00000000000f', 'tp7fx-y', 'TP7FX Divulgador Y', 'influencer');

INSERT INTO public.channel_links (id, campaign_id, channel_id, code) VALUES
  ('7f000000-0000-4000-c000-000000000001', '7f000000-0000-4000-a000-00000000000a', '7f000000-0000-4000-b000-00000000000e', 'tp7fx-l1'),
  ('7f000000-0000-4000-c000-000000000002', '7f000000-0000-4000-a000-00000000000a', '7f000000-0000-4000-b000-00000000000f', 'tp7fx-l2'),
  ('7f000000-0000-4000-c000-000000000003', '7f000000-0000-4000-a000-00000000000b', '7f000000-0000-4000-b000-00000000000e', 'tp7fx-l3'),
  ('7f000000-0000-4000-c000-000000000004', NULL,                                   '7f000000-0000-4000-b000-00000000000f', 'tp7fx-l4');

INSERT INTO public.user_profiles (id, full_name, age, city, state, created_at) VALUES
  ('7f000000-0000-4000-d000-000000000001', 'TP7FX U1', 18, 'Recife',    'PE', '2026-10-01T10:00:00Z'),
  ('7f000000-0000-4000-d000-000000000002', 'TP7FX U2', 19, 'Recife',    'PE', '2026-10-02T10:00:00Z'),
  ('7f000000-0000-4000-d000-000000000003', 'TP7FX U3', 20, 'Salvador',  'BA', '2026-10-03T10:00:00Z'),
  ('7f000000-0000-4000-d000-000000000004', 'TP7FX U4', 21, 'Salvador',  'BA', '2026-10-04T10:00:00Z'),
  ('7f000000-0000-4000-d000-000000000005', 'TP7FX U5', 22, 'Natal',     'RN', '2026-10-05T10:00:00Z'),
  ('7f000000-0000-4000-d000-000000000006', 'TP7FX U6', 23, 'Natal',     'RN', '2026-10-06T10:00:00Z'),
  ('7f000000-0000-4000-d000-000000000007', 'TP7FX U7', 24, 'Fortaleza', 'CE', '2026-10-07T10:00:00Z');

INSERT INTO public.user_attribution (user_id, first_touch_link_id, last_touch_link_id, first_touch_at, last_touch_at) VALUES
  ('7f000000-0000-4000-d000-000000000001', '7f000000-0000-4000-c000-000000000001', '7f000000-0000-4000-c000-000000000001', now(), now()),
  ('7f000000-0000-4000-d000-000000000002', '7f000000-0000-4000-c000-000000000002', '7f000000-0000-4000-c000-000000000003', now(), now()),
  ('7f000000-0000-4000-d000-000000000003', '7f000000-0000-4000-c000-000000000003', '7f000000-0000-4000-c000-000000000003', now(), now()),
  ('7f000000-0000-4000-d000-000000000004', '7f000000-0000-4000-c000-000000000004', '7f000000-0000-4000-c000-000000000004', now(), now()),
  ('7f000000-0000-4000-d000-000000000005', NULL,                                   '7f000000-0000-4000-c000-000000000001', NULL,  now()),
  ('7f000000-0000-4000-d000-000000000007', '7f000000-0000-4000-c000-000000000001', '7f000000-0000-4000-c000-000000000001', now(), now());

-- Renda só em user_income (a lista usa COALESCE(user_income, user_preferences)).
-- user_income tem FK para auth.users.
INSERT INTO auth.users (id) VALUES ('7f000000-0000-4000-d000-000000000007');
INSERT INTO public.user_income (user_id, per_capita_income) VALUES
  ('7f000000-0000-4000-d000-000000000007', 500);

INSERT INTO public.student_applications (id, user_id, partner_id, status, created_at) VALUES
  ('7f000000-0000-4000-e000-000000000001', '7f000000-0000-4000-d000-000000000001', (SELECT id FROM public.partner_opportunities ORDER BY created_at LIMIT 1), 'DRAFT',     '2026-10-10T10:00:00Z'),
  ('7f000000-0000-4000-e000-000000000002', '7f000000-0000-4000-d000-000000000001', (SELECT id FROM public.partner_opportunities ORDER BY created_at LIMIT 1), 'SUBMITTED', '2026-10-11T10:00:00Z'),
  ('7f000000-0000-4000-e000-000000000003', '7f000000-0000-4000-d000-000000000003', (SELECT id FROM public.partner_opportunities ORDER BY created_at LIMIT 1), 'DRAFT',     '2026-10-12T10:00:00Z'),
  ('7f000000-0000-4000-e000-000000000006', '7f000000-0000-4000-d000-000000000006', (SELECT id FROM public.partner_opportunities ORDER BY created_at LIMIT 1), 'SUBMITTED', '2026-10-13T10:00:00Z');

-- Admin de teste para o guard is_backoffice_admin() (auth.uid() lê o JWT).
INSERT INTO auth.users (id) VALUES ('7f000000-0000-4000-f000-0000000000ad');
INSERT INTO public.user_permissions (user_id, permission) VALUES
  ('7f000000-0000-4000-f000-0000000000ad', 'Controle de usuários');

SELECT set_config('request.jwt.claims', '{"sub":"7f000000-0000-4000-f000-0000000000ad","role":"authenticated"}', true);
SELECT set_config('request.jwt.claim.sub', '7f000000-0000-4000-f000-0000000000ad', true);
