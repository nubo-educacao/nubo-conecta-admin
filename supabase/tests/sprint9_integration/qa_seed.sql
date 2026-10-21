-- Massa de QA para o Assurance humano da Sprint 9.0 no DEV (yfgciamhzjvarwgzosto).
-- Idempotente: apaga a rodada anterior (mesma identificação do qa_cleanup.sql)
-- e recria tudo com datas relativas a now(). Valores esperados por filtro estão
-- no README desta pasta. Remover com qa_cleanup.sql ao fim do assurance.
--
-- 12 alunos [QA-S9] (5e9a0000-0000-4000-a000-0000000000NN), 2 campanhas,
-- 2 divulgadores, 3 links:
--   L1 = Campanha A + Divulgador X : first-touch de U01..U04 (U01 tem last-touch L3)
--   L2 = Campanha A + Divulgador Y : U05, U06
--   L3 = Campanha B + Divulgador X : U07, U08
--   sem atribuição                 : U09..U12
-- Parceiros reaproveitados do DEV: "[QA SEED] Bolsa Integral QA-7" (P1) e "BIP Impulsiona".
DO $$ BEGIN
  IF (SELECT count(*) FROM public.user_profiles)>1000 OR NOT EXISTS(SELECT 1 FROM auth.users WHERE id='781fe878-3d24-4061-8496-ac0ef3b627a5' AND email='backoffice@qa-s9.invalid') OR NOT coalesce((SELECT array_agg(jobname ORDER BY jobname) IN (ARRAY['check-program-deadlines']::text[],ARRAY['check-program-deadlines','user-activity-days-daily']::text[]) FROM cron.job),false) THEN RAISE EXCEPTION 'QA_S9_ABORT: alvo não é o DEV'; END IF;
  IF to_regprocedure('public.matches_first_touch_attribution(uuid,uuid,uuid,boolean)') IS NULL THEN
    RAISE EXCEPTION 'QA_S9_ABORT: DEV sem as migrations da Sprint 9.0';
  END IF;
END $$;

-- (qa_seed.sh executa qa_cleanup.sql antes deste arquivo, na mesma transação)

CREATE TEMP TABLE qa_u (n int PRIMARY KEY, id uuid, nome text, idade int, cidade text, uf text,
  escolaridade text, raca text, escola text, renda numeric, cursos text[]) ON COMMIT DROP;
INSERT INTO qa_u VALUES
 (1,'5e9a0000-0000-4000-a000-000000000001','[QA-S9] Aluno 01 — Ana',17,'São Paulo','SP','Ensino Médio Completo','Parda','Escola pública',450,'{Medicina,Direito}'),
 (2,'5e9a0000-0000-4000-a000-000000000002','[QA-S9] Aluno 02 — Bruna',18,'São Paulo','SP','Ensino Médio Completo','Preta','Escola pública',900,'{Medicina}'),
 (3,'5e9a0000-0000-4000-a000-000000000003','[QA-S9] Aluno 03 — Caio',19,'Rio de Janeiro','RJ','Ensino Superior Incompleto','Branca','Escola particular com bolsa 100%',1200,'{"Engenharia Civil"}'),
 (4,'5e9a0000-0000-4000-a000-000000000004','[QA-S9] Aluno 04 — Davi',17,'Salvador','BA','Ensino Médio Completo','Parda','Escola pública',2500,'{Medicina}'),
 (5,'5e9a0000-0000-4000-a000-000000000005','[QA-S9] Aluno 05 — Elisa',16,'São Paulo','SP','Ensino Médio Incompleto','Prefiro não informar','Escola pública',NULL,'{Direito}'),
 (6,'5e9a0000-0000-4000-a000-000000000006','[QA-S9] Aluno 06 — Felipe',20,'Recife','PE',NULL,NULL,NULL,NULL,'{Psicologia}'),
 (7,'5e9a0000-0000-4000-a000-000000000007','[QA-S9] Aluno 07 — Gabi',21,'Belo Horizonte','MG','Ensino Superior Completo','Amarela','Escola particular sem bolsa',4000,'{"Engenharia Civil"}'),
 (8,'5e9a0000-0000-4000-a000-000000000008','[QA-S9] Aluno 08 — Heitor',18,'Campinas','SP','Ensino Médio Completo','Parda','Escola pública',700,'{Administração}'),
 (9,'5e9a0000-0000-4000-a000-000000000009','[QA-S9] Aluno 09 — Iara',17,'Manaus','AM','Ensino Médio Completo','Indígena','Escola pública',300,'{Enfermagem}'),
 (10,'5e9a0000-0000-4000-a000-000000000010','[QA-S9] Aluno 10 — João',24,'Curitiba','PR','Pós-Graduação','Branca','Escola particular sem bolsa',3500,'{Direito}'),
 (11,'5e9a0000-0000-4000-a000-000000000011','[QA-S9] Aluno 11 — Kátia',15,'Fortaleza','CE','Ensino Fundamental',NULL,NULL,NULL,'{Pedagogia}'),
 (12,'5e9a0000-0000-4000-a000-000000000012','[QA-S9] Aluno 12 — Lucas',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL);

-- Contas: campos de token como '' para o GoTrue listar sem erro de NULL.
INSERT INTO auth.users (id, instance_id, aud, role, email, phone, email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, recovery_token, email_change_token_new, email_change)
SELECT id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       format('qa-s9-aluno-%s@qa-s9.invalid', lpad(n::text, 2, '0')), format('5511900009%s', lpad(n::text, 3, '0')),
       now() - interval '20 days', now() - make_interval(days => 20 - n), now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name', nome), '', '', '', ''
  FROM qa_u;

INSERT INTO public.user_profiles (id, full_name, age, city, state, education, race, school_type, onboarding_completed, created_at)
SELECT id, nome, idade, cidade, uf, escolaridade, raca, escola, true, now() - make_interval(days => 20 - n) FROM qa_u
ON CONFLICT (id) DO UPDATE SET full_name = EXCLUDED.full_name, age = EXCLUDED.age, city = EXCLUDED.city,
  state = EXCLUDED.state, education = EXCLUDED.education, race = EXCLUDED.race, school_type = EXCLUDED.school_type,
  onboarding_completed = true, created_at = EXCLUDED.created_at;

INSERT INTO public.user_income (user_id, per_capita_income, family_count) SELECT id, renda, 3 FROM qa_u WHERE renda IS NOT NULL;

-- Preferências (U12 não tem). updated_at no período só para quem deve contar como
-- "só catálogo" (U09); U10/U11 com atualização antiga. Match v1: U05 erro, U10 pronto sem resultado.
INSERT INTO public.user_preferences (user_id, course_interest, program_preference, university_preference,
  workflow_data, match_status, last_match_at, created_at, updated_at)
SELECT id, cursos, 'indiferente', 'indiferente',
       CASE WHEN n IN (2, 9) THEN jsonb_build_object('last_course_ids', jsonb_build_array('qa-s9-curso-v0')) ELSE '{}'::jsonb END,
       CASE n WHEN 5 THEN 'error' WHEN 10 THEN 'ready' END,
       CASE WHEN n IN (5, 10) THEN now() - interval '3 days' END,
       now() - interval '200 days',
       CASE WHEN n = 9 THEN now() - interval '2 days' ELSE now() - interval '200 days' END
  FROM qa_u WHERE n <> 12;

-- Match v1 com resultado: U01/U07 MEC, U03 só parceiro.
INSERT INTO public.user_opportunity_matches (profile_id, unified_opportunity_id, match_score, generated_at)
SELECT id, CASE WHEN n = 3 THEN 'partner_33333333-3333-4333-8333-333333333331'
                ELSE 'mec_5e9a0000-0000-4000-f000-0000000000' || lpad(n::text, 2, '0') END, 0.9, now() - interval '3 days'
  FROM qa_u WHERE n IN (1, 3, 7);

-- Campanhas, divulgadores e links
INSERT INTO public.campaigns (id, slug, name, objective, active) VALUES
 ('5e9a0000-0000-4000-c000-000000000001', 'qa-s9-campanha-a', '[QA-S9] Campanha A — Vestibular', 'QA Sprint 9.0', true),
 ('5e9a0000-0000-4000-c000-000000000002', 'qa-s9-campanha-b', '[QA-S9] Campanha B — Bolsas', 'QA Sprint 9.0', true);
INSERT INTO public.channels (id, slug, name, type, active) VALUES
 ('5e9a0000-0000-4000-d000-000000000001', 'qa-s9-divulgador-x', '[QA-S9] Divulgador X', 'influencer', true),
 ('5e9a0000-0000-4000-d000-000000000002', 'qa-s9-divulgador-y', '[QA-S9] Divulgador Y', 'influencer', true);
INSERT INTO public.channel_links (id, campaign_id, channel_id, platform_id, code, nickname, destination_path) VALUES
 ('5e9a0000-0000-4000-e000-000000000001', '5e9a0000-0000-4000-c000-000000000001', '5e9a0000-0000-4000-d000-000000000001', 'instagram', 'qa-s9-l1', '[QA-S9] L1 A+X', '/'),
 ('5e9a0000-0000-4000-e000-000000000002', '5e9a0000-0000-4000-c000-000000000001', '5e9a0000-0000-4000-d000-000000000002', 'tiktok',    'qa-s9-l2', '[QA-S9] L2 A+Y', '/'),
 ('5e9a0000-0000-4000-e000-000000000003', '5e9a0000-0000-4000-c000-000000000002', '5e9a0000-0000-4000-d000-000000000001', 'whatsapp',  'qa-s9-l3', '[QA-S9] L3 B+X', '/');

INSERT INTO public.user_attribution (user_id, first_touch_link_id, first_touch_at, last_touch_link_id, last_touch_at)
SELECT id, l.link, now() - make_interval(days => 20 - n),
       CASE WHEN n = 1 THEN '5e9a0000-0000-4000-e000-000000000003'::uuid ELSE l.link END,
       now() - make_interval(days => 20 - n)
  FROM qa_u JOIN (VALUES
    (1,'5e9a0000-0000-4000-e000-000000000001'::uuid),(2,'5e9a0000-0000-4000-e000-000000000001'),
    (3,'5e9a0000-0000-4000-e000-000000000001'),(4,'5e9a0000-0000-4000-e000-000000000001'),
    (5,'5e9a0000-0000-4000-e000-000000000002'),(6,'5e9a0000-0000-4000-e000-000000000002'),
    (7,'5e9a0000-0000-4000-e000-000000000003'),(8,'5e9a0000-0000-4000-e000-000000000003')) l(un, link) ON l.un = qa_u.n;

-- Mensagens: cada sessão = 2 mensagens do usuário (5 min) + 1 resposta da Cloudinha.
-- Sessões (dias atrás, hora UTC): U01 3, U02 2, U07 2, U03/U04/U05/U06/U08 1 → 24 mensagens de usuário.
CREATE TEMP TABLE qa_sess (n int, d int, h int) ON COMMIT DROP;
INSERT INTO qa_sess VALUES (1,1,13),(1,3,18),(1,5,23),(2,2,12),(2,4,22),(3,2,17),(4,3,14),(5,4,19),(6,5,13),(7,1,23),(7,6,11),(8,6,16);
INSERT INTO public.chat_messages (user_id, sender, content, created_at, workflow, session_id)
SELECT u.id, x.sender, x.content, date_trunc('day', now()) - make_interval(days => s.d) + make_interval(hours => s.h, mins => x.m),
       NULL, format('qa-s9-%s-%s-%s', s.n, s.d, s.h)
  FROM qa_sess s JOIN qa_u u ON u.n = s.n
 CROSS JOIN (VALUES ('user', '[QA-S9] Quero bolsa para o meu curso', 0), ('cloudinha', '[QA-S9] Posso te ajudar!', 2),
                    ('user', '[QA-S9] Obrigado', 5)) x(sender, content, m);
-- Match v0 só tentativa (U04): interação no match_workflow, sem last_course_ids.
INSERT INTO public.chat_messages (user_id, sender, content, created_at, workflow, session_id)
SELECT id, 'cloudinha', '[QA-S9] Vamos encontrar cursos para você', date_trunc('day', now()) - interval '3 days' + interval '14 hours 3 minutes',
       'match_workflow', 'qa-s9-4-3-14' FROM qa_u WHERE n = 4;

-- Favoritos no período: U03 (já tem mensagem), U09 e U10 (só catálogo).
INSERT INTO public.user_favorites (user_id, partner_opportunities_id, created_at)
SELECT id, CASE WHEN n = 10 THEN '8cb2f939-1875-497e-a43a-83371ae4f0c2'::uuid ELSE '33333333-3333-4333-8333-333333333331'::uuid END,
       now() - interval '2 days'
  FROM qa_u WHERE n IN (3, 9, 10);

-- Cliques em card de parceiro (source=card). Dois anônimos: só contam sem filtro.
INSERT INTO public.engagement_events (event_id, event_type, entity_type, entity_id, unified_opportunity_id, user_id, anonymous_id, source, event_count, occurred_at)
SELECT format('card_click:%s:%s:%s', coalesce(u.id::text, c.anon), c.ent, to_char(t, 'YYYY-MM-DD"T"HH24:MI')),
       'card_click', 'partner_opportunity', c.ent, 'partner_' || c.ent::text, u.id, c.anon, 'card', 1, t
  FROM (VALUES (1, NULL::text, '33333333-3333-4333-8333-333333333331'::uuid, 1),
               (2, NULL, '33333333-3333-4333-8333-333333333331', 2),
               (3, NULL, '33333333-3333-4333-8333-333333333331', 2),
               (7, NULL, '8cb2f939-1875-497e-a43a-83371ae4f0c2', 1),
               (9, NULL, '8cb2f939-1875-497e-a43a-83371ae4f0c2', 2),
               (NULL, 'qa-s9-anon-1', '33333333-3333-4333-8333-333333333331', 3),
               (NULL, 'qa-s9-anon-2', '33333333-3333-4333-8333-333333333331', 4)) c(un, anon, ent, d)
  LEFT JOIN qa_u u ON u.n = c.un
 CROSS JOIN LATERAL (SELECT date_trunc('day', now()) - make_interval(days => c.d) + interval '15 hours' AS t) tt;

-- Candidaturas. U05 declara renda só em salários mínimos (campo renda_calculada do P1).
INSERT INTO public.student_applications (user_id, partner_id, status, answers, phase_id, created_at, updated_at)
SELECT u.id, a.partner, a.status, a.answers, a.phase, now() - make_interval(days => a.d), now() - make_interval(days => a.d)
  FROM (VALUES (1, '33333333-3333-4333-8333-333333333331'::uuid, 'submitted', '{}'::jsonb, '33333333-3333-4333-8333-333333333341'::uuid, 4),
               (5, '33333333-3333-4333-8333-333333333331', 'started', '{"renda_calculada": "De 1 a 2 salários mínimos"}', NULL, 3),
               (7, '33333333-3333-4333-8333-333333333331', 'submitted', '{}', '33333333-3333-4333-8333-333333333342', 2),
               (2, '8cb2f939-1875-497e-a43a-83371ae4f0c2', 'submitted', '{}', NULL, 3),
               (9, '8cb2f939-1875-497e-a43a-83371ae4f0c2', 'started', '{}', NULL, 1)) a(un, partner, status, answers, phase, d)
  JOIN qa_u u ON u.n = a.un;

-- Fixture do cron (#64): início em +2 dias cai na janela mec_period_start.
INSERT INTO public.important_dates (id, title, description, start_date, type, controls_opportunity_dates)
VALUES ('5e9a0000-0000-4000-b000-000000000001', '[QA-S9] Abertura de inscrições (fixture cron)',
        'Fixture do assurance da Sprint 9.0 — remover com qa_cleanup.sql', now() + interval '2 days', 'general', true);
