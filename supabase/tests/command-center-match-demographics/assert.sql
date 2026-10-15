-- Complemento TP-1 (card f245da71, plano 29c645bd rev3 §7).
-- Fixtures + asserções de vw_user_match_evidence, vw_user_demographics_resolved
-- e get_command_center_demographics. Rodar SÓ via run_dev.sh: o script inteiro
-- vive numa transação que termina em RAISE EXCEPTION proposital, então nenhuma
-- fixture, DDL ou alteração sobrevive. Fixtures são sintéticas (UUIDs 7c1c…),
-- nunca cópia de dado real.

DO $guard$
BEGIN
  -- PROD tem milhares de perfis; DEV tem dezenas. Recusa antes de qualquer escrita.
  IF (SELECT count(*) FROM public.user_profiles) > 1000 THEN
    RAISE EXCEPTION 'TP1C_GUARD: alvo parece PROD (>1000 perfis); abortando';
  END IF;
END
$guard$;

CREATE TEMP TABLE tp1c_log (n serial, msg text) ON COMMIT DROP;
CREATE TEMP TABLE tp1c_ctx (k text PRIMARY KEY, v text) ON COMMIT DROP;
CREATE TEMP TABLE tp1c_snap (k text PRIMARY KEY, j jsonb) ON COMMIT DROP;

CREATE FUNCTION pg_temp.ok(cond boolean, msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF cond IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'TP1C_FAIL: %', msg;
  END IF;
  INSERT INTO tp1c_log(msg) VALUES (msg);
END
$$;

CREATE FUNCTION pg_temp.pid(n int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('7c1c0000-0000-4000-8000-' || lpad(to_hex(n), 12, '0'))::uuid
$$;

CREATE FUNCTION pg_temp.slice(j jsonb, dim text, lbl text) RETURNS bigint LANGUAGE sql AS $$
  SELECT coalesce((SELECT (e->>'value')::bigint FROM jsonb_array_elements(j->dim) e WHERE e->>'label' = lbl), 0)
$$;

-- ── Fingerprint das fontes (prova de não-mutação pelas views/RPC) ─────────────
CREATE FUNCTION pg_temp.fingerprint() RETURNS text LANGUAGE sql AS $$
  SELECT md5(concat_ws('|',
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t.id), '')) FROM public.user_profiles t),
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t.id), '')) FROM public.user_preferences t),
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t.id), '')) FROM public.user_income t),
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t.id), '')) FROM public.user_opportunity_matches t),
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t.id), '')) FROM public.student_applications t),
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t.id), '')) FROM public.partner_forms t),
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t.id), '')) FROM public.chat_messages t)
  ))
$$;

DO $admin$
DECLARE
  v_admin uuid;
BEGIN
  SELECT user_id INTO v_admin FROM public.user_permissions
   WHERE permission = 'Controle de usuários' ORDER BY user_id LIMIT 1;
  PERFORM pg_temp.ok(v_admin IS NOT NULL, 'fixture: existe admin de backoffice no DEV');
  INSERT INTO tp1c_ctx VALUES ('admin', v_admin::text);
  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
  INSERT INTO tp1c_snap VALUES ('j0', public.get_command_center_demographics()::jsonb);
END
$admin$;

-- ── Contrato estrutural (falha na RED: views e chaves novas ainda não existem) ─
DO $contract$
DECLARE
  j jsonb := (SELECT j FROM tp1c_snap WHERE k = 'j0');
BEGIN
  PERFORM pg_temp.ok(to_regclass('public.vw_user_match_evidence') IS NOT NULL, 'view vw_user_match_evidence existe');
  PERFORM pg_temp.ok(to_regclass('public.vw_user_demographics_resolved') IS NOT NULL, 'view vw_user_demographics_resolved existe');
  PERFORM pg_temp.ok(j->'match_health' ?& ARRAY['with_match','without_match','total'], 'chaves atuais de match_health preservadas');
  PERFORM pg_temp.ok(j->'match_health' ?& ARRAY['attempted_no_result','never','with_current_result','with_current_mec_result'], 'chaves aditivas de match_health presentes');
  PERFORM pg_temp.ok(j ?& ARRAY['education','income','race','school_type','provenance'], 'dimensões atuais + provenance presentes');
END
$contract$;

-- ── Fixtures ────────────────────────────────────────────────────────────────
DO $fixtures$
DECLARE
  p1 uuid; p2 uuid; p3 uuid;
  n int;
BEGIN
  SELECT id INTO p1 FROM public.partner_opportunities ORDER BY id LIMIT 1;
  SELECT id INTO p2 FROM public.partner_opportunities ORDER BY id OFFSET 1 LIMIT 1;
  SELECT id INTO p3 FROM public.partner_opportunities ORDER BY id OFFSET 2 LIMIT 1;
  PERFORM pg_temp.ok(p1 IS NOT NULL AND p2 IS NOT NULL AND p3 IS NOT NULL, 'fixture: 3 parceiros disponíveis');

  -- Formulários próprios do teste (prefixo tp1c_): nunca colidem com campos reais.
  INSERT INTO public.partner_forms (id, partner_id, field_name, question_text, mapping_source) VALUES
    (pg_temp.pid(1001), p1, 'tp1c_edu',     'Escolaridade',                              'user_profiles.education'),
    (pg_temp.pid(1002), p1, 'tp1c_race',    'Autodeclaração',                            'user_profiles.race'),
    (pg_temp.pid(1003), p1, 'tp1c_school',  'Você estuda/estudou em que tipo de escola?', NULL),
    (pg_temp.pid(1004), p1, 'tp1c_renda',   'Renda per capita',                          'user_income.per_capita_income'),
    (pg_temp.pid(1005), p1, 'tp1c_ano',     'Ano escolar/acadêmico',                     'user_profiles.education_year'),
    (pg_temp.pid(1006), p2, 'tp1c_edu2',    'Qual sua escolaridade?',                    'user_profiles.education'),
    (pg_temp.pid(1007), p2, 'tp1c_renda2',  'Renda per capita',                          'user_income.per_capita_income'),
    (pg_temp.pid(1008), p3, 'tp1c_iso_edu', 'Escolaridade',                              'user_profiles.education');

  -- auth.users para todos os perfis (FK de chat_messages, user_income e
  -- parent_user_id). is_anonymous evita o claim de lead do trigger.
  INSERT INTO auth.users (id, is_anonymous)
  SELECT pg_temp.pid(i), true FROM generate_series(1, 12) i
  UNION ALL SELECT pg_temp.pid(i), true FROM generate_series(33, 48) i;

  -- Perfis: M (Match) 1–8, 10–12; D (demografia) 33–48. 9 = órfão de
  -- preferências; 49 = órfão de candidatura. Nenhum dos dois tem perfil.
  INSERT INTO public.user_profiles (id, parent_user_id, education, race, school_type)
  SELECT pg_temp.pid(i), NULL, NULL, NULL, NULL
    FROM unnest(ARRAY[1,2,3,4,5,6,7,8,11,12, 34,35,36,37,39,40,41,42,44,45,46,47,48]) i;
  INSERT INTO public.user_profiles (id, parent_user_id) VALUES (pg_temp.pid(10), pg_temp.pid(8));       -- dependente
  INSERT INTO public.user_profiles (id, education) VALUES (pg_temp.pid(33), 'Ensino Médio Completo');   -- D01
  UPDATE public.user_profiles SET school_type = '' WHERE id = pg_temp.pid(36);                         -- D04 (vazio = ausente)
  INSERT INTO public.user_profiles (id, race) VALUES (pg_temp.pid(38), 'Prefiro não informar');        -- D05b
  INSERT INTO public.user_profiles (id, education) VALUES (pg_temp.pid(43), 'Pós-Gradução');           -- D10

  -- ── Match ──
  INSERT INTO public.user_preferences (user_id, workflow_data, match_status, last_match_at, family_income_per_capita, quota_types) VALUES
    (pg_temp.pid(1),  '{"last_course_ids":["v0-a","v0-b"]}', 'reviewing', NULL, NULL, NULL),            -- M01 só v0 resultado
    (pg_temp.pid(3),  NULL, 'ready', '2026-08-01T10:00:00Z', NULL, NULL),                                 -- M03 v1 MEC
    (pg_temp.pid(5),  NULL, 'error', '2026-08-02T10:00:00Z', NULL, NULL),                                 -- M05 v1 erro s/ resultado
    (pg_temp.pid(6),  NULL, 'error', '2026-08-03T10:00:00Z', NULL, NULL),                                 -- M06 v1 erro c/ resultado anterior
    (pg_temp.pid(7),  '{"last_course_ids":["v0-c"]}', 'ready', '2026-08-04T10:00:00Z', NULL, NULL),      -- M07 v0+v1
    (pg_temp.pid(8),  NULL, 'idle', NULL, NULL, NULL),                                                    -- M08 nunca
    (pg_temp.pid(9),  '{"last_course_ids":["orfao"]}', 'reviewing', NULL, NULL, NULL),                   -- órfão
    (pg_temp.pid(10), '{"last_course_ids":["dep"]}', 'reviewing', NULL, NULL, NULL),                     -- M10 dependente
    (pg_temp.pid(11), '{"last_course_ids":"nao-e-array"}', 'idle', NULL, NULL, NULL),                    -- M11 formato inválido
    (pg_temp.pid(12), '{"last_course_ids":[]}', 'idle', NULL, NULL, NULL),                               -- M12 array vazio
    (pg_temp.pid(42), NULL, 'idle', NULL, NULL, ARRAY['PPI','BAIXA_RENDA','ESCOLA_PUBLICA']),            -- D09 só cotas
    (pg_temp.pid(47), NULL, 'idle', NULL, 300, NULL);                                                    -- D14 renda onboarding v0

  INSERT INTO public.chat_messages (user_id, workflow, sender, created_at) VALUES
    (pg_temp.pid(2), 'match_workflow', 'user', '2026-01-20T12:00:00Z'),
    (pg_temp.pid(2), 'match_workflow', 'user', '2026-02-05T12:00:00Z'),
    (pg_temp.pid(7), 'match_workflow', 'user', '2026-01-25T12:00:00Z'),
    (pg_temp.pid(8), 'onboarding',     'user', '2026-01-25T12:00:00Z');                                  -- outro workflow não conta

  INSERT INTO public.user_opportunity_matches (profile_id, unified_opportunity_id, generated_at) VALUES
    (pg_temp.pid(3), 'mec_tp1c_1',     '2026-08-01T10:00:00Z'),
    (pg_temp.pid(4), 'partner_tp1c_1', '2026-08-05T10:00:00Z'),                                         -- M04 sem preferências
    (pg_temp.pid(6), 'partner_tp1c_2', '2026-07-01T10:00:00Z'),
    (pg_temp.pid(7), 'mec_tp1c_2',     '2026-08-04T10:00:00Z'),
    (pg_temp.pid(7), 'partner_tp1c_3', '2026-08-04T10:00:00Z');

  -- ── Demografia ──
  INSERT INTO public.user_income (user_id, per_capita_income) VALUES (pg_temp.pid(41), 1500);           -- D08

  INSERT INTO public.student_applications (id, user_id, partner_id, status, answers, created_at, updated_at) VALUES
    (pg_temp.pid(2001), pg_temp.pid(33), p1, 'SUBMITTED',  '{"tp1c_edu":"Ensino Superior Completo"}', '2026-09-01', '2026-09-01'),
    (pg_temp.pid(2002), pg_temp.pid(34), p1, 'DRAFT',      '{"tp1c_edu":"Ensino Médio Incompleto"}',  '2026-09-10', '2026-09-10'),
    (pg_temp.pid(2003), pg_temp.pid(35), p1, 'SUBMITTED',  '{"tp1c_edu":"Ensino Superior Completo"}', '2026-09-01', '2026-09-01'),
    (pg_temp.pid(2004), pg_temp.pid(35), p2, 'redirected', '{"tp1c_edu2":"Ensino Fundamental"}',      '2026-10-01', '2026-10-01'),
    (pg_temp.pid(2005), pg_temp.pid(36), p1, 'DRAFT',      jsonb_build_object(pg_temp.pid(1003)::text, 'Escola pública'), '2026-09-02', '2026-09-02'),
    (pg_temp.pid(2006), pg_temp.pid(37), p1, 'DRAFT',      '{"tp1c_race":"Prefiro não informar"}',    '2026-09-03', '2026-09-03'),
    (pg_temp.pid(2007), pg_temp.pid(38), p1, 'SUBMITTED',  '{"tp1c_race":"Parda"}',                   '2026-09-03', '2026-09-03'),
    (pg_temp.pid(2008), pg_temp.pid(39), p1, 'DRAFT',      jsonb_build_object('tp1c_renda', '{"family_count":2,"social_benefits":0,"alimony":0,"member_incomes":[1625],"per_capita_income":812.5}'), '2026-09-04', '2026-09-04'),
    (pg_temp.pid(2009), pg_temp.pid(40), p1, 'redirected', '{"tp1c_renda":"Até 1 salário mínimo"}',   '2026-09-05', '2026-09-05'),
    (pg_temp.pid(2010), pg_temp.pid(41), p1, 'redirected', '{"tp1c_renda":"De 1 a 2 salários mínimos"}', '2026-09-05', '2026-09-05'),
    (pg_temp.pid(2011), pg_temp.pid(44), p1, 'DRAFT',      '{"tp1c_ano":"3º ano EM"}',                '2026-09-06', '2026-09-06'),
    (pg_temp.pid(2012), pg_temp.pid(45), p1, 'DRAFT',      '{"tp1c_iso_edu":"Ensino Superior Completo"}', '2026-09-06', '2026-09-06'),
    (pg_temp.pid(2013), pg_temp.pid(46), p1, 'DRAFT',      '{"tp1c_edu":"Doutorado em Marte","tp1c_renda":"{\"per_capita_income\": \"abc\"","tp1c_school":123}', '2026-09-07', '2026-09-07'),
    (pg_temp.pid(2014), pg_temp.pid(46), p2, 'DRAFT',      jsonb_build_object('tp1c_renda2', '{"per_capita_income":"abc"}'), '2026-09-08', '2026-09-08'),
    (pg_temp.pid(2015), pg_temp.pid(48), p1, 'DRAFT',      '[]',                                      '2026-09-09', '2026-09-09'),
    (pg_temp.pid(2016), pg_temp.pid(49), p1, 'DRAFT',      '{"tp1c_edu":"Ensino Médio Completo"}',    '2026-09-09', '2026-09-09');

  SELECT count(*) INTO n FROM public.user_profiles WHERE id::text LIKE '7c1c0000-%';
  PERFORM pg_temp.ok(n = 27, format('fixture: 27 perfis sintéticos (obtido %s)', n));
END
$fixtures$;

-- ── Match: uma linha por perfil e buckets mutuamente exclusivos ─────────────
DO $match$
DECLARE
  r record;
  n_rows bigint; n_distinct bigint; n_profiles bigint;
BEGIN
  SELECT count(*), count(DISTINCT profile_id) INTO n_rows, n_distinct FROM public.vw_user_match_evidence;
  SELECT count(*) INTO n_profiles FROM public.user_profiles;
  PERFORM pg_temp.ok(n_rows = n_profiles AND n_distinct = n_profiles, 'match: uma linha por perfil, denominador = user_profiles');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.vw_user_match_evidence WHERE bucket NOT IN ('concluded','attempted_no_result','never') OR bucket IS NULL), 'match: bucket sempre em {concluded, attempted_no_result, never}');

  SELECT * INTO r FROM public.vw_user_match_evidence WHERE profile_id = pg_temp.pid(1);
  PERFORM pg_temp.ok(r.bucket = 'concluded' AND r.v0_result AND NOT r.v0_attempt AND NOT r.v1_has_result AND r.v0_first_interaction_at IS NULL, 'M01 só v0 resultado → concluded, sem data inventada');
  SELECT * INTO r FROM public.vw_user_match_evidence WHERE profile_id = pg_temp.pid(2);
  PERFORM pg_temp.ok(r.bucket = 'attempted_no_result' AND r.v0_attempt AND NOT r.v0_result
                     AND r.v0_first_interaction_at = '2026-01-20T12:00:00Z' AND r.v0_last_interaction_at = '2026-02-05T12:00:00Z',
                     'M02 só v0 conversa → attempted_no_result, datas = janela de interação');
  SELECT * INTO r FROM public.vw_user_match_evidence WHERE profile_id = pg_temp.pid(3);
  PERFORM pg_temp.ok(r.bucket = 'concluded' AND r.v1_has_result AND r.v1_has_mec_result AND NOT r.v1_partner_only AND r.v1_attempt, 'M03 só v1 MEC → concluded, MEC');
  SELECT * INTO r FROM public.vw_user_match_evidence WHERE profile_id = pg_temp.pid(4);
  PERFORM pg_temp.ok(r.bucket = 'concluded' AND r.v1_partner_only AND NOT r.v1_attempt AND r.v1_last_status IS NULL AND r.v1_last_match_at IS NULL,
                     'M04 só parceiro sem preferências → concluded (D2), sem tentativa fabricada');
  SELECT * INTO r FROM public.vw_user_match_evidence WHERE profile_id = pg_temp.pid(5);
  PERFORM pg_temp.ok(r.bucket = 'attempted_no_result' AND r.v1_attempt AND r.v1_last_status = 'error' AND NOT r.v1_has_result, 'M05 v1 erro sem resultado → attempted_no_result');
  SELECT * INTO r FROM public.vw_user_match_evidence WHERE profile_id = pg_temp.pid(6);
  PERFORM pg_temp.ok(r.bucket = 'concluded' AND r.v1_last_status = 'error' AND r.v1_has_result, 'M06 v1 erro com resultado anterior → concluded');
  SELECT * INTO r FROM public.vw_user_match_evidence WHERE profile_id = pg_temp.pid(7);
  PERFORM pg_temp.ok(r.bucket = 'concluded' AND r.v0_result AND r.v0_attempt AND r.v1_attempt AND r.v1_has_mec_result AND NOT r.v1_partner_only
                     AND r.evidence_sources @> ARRAY['v0_chat_interaction','v0_result','v1_attempt','v1_mec_result','v1_partner_result'],
                     'M07 v0+v1 → concluded uma vez, todas as evidências listadas');
  SELECT * INTO r FROM public.vw_user_match_evidence WHERE profile_id = pg_temp.pid(8);
  PERFORM pg_temp.ok(r.bucket = 'never' AND NOT r.v0_attempt AND r.evidence_sources = ARRAY[]::text[], 'M08 nunca (chat de outro workflow não conta)');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.vw_user_match_evidence WHERE profile_id = pg_temp.pid(9)), 'órfão de preferências fora do denominador');
  SELECT * INTO r FROM public.vw_user_match_evidence WHERE profile_id = pg_temp.pid(10);
  PERFORM pg_temp.ok(r.bucket = 'concluded' AND r.is_dependent, 'M10 dependente mantido no denominador');
  SELECT * INTO r FROM public.vw_user_match_evidence WHERE profile_id = pg_temp.pid(11);
  PERFORM pg_temp.ok(r.bucket = 'never' AND NOT r.v0_result, 'M11 last_course_ids não-array não quebra e não conta');
  SELECT * INTO r FROM public.vw_user_match_evidence WHERE profile_id = pg_temp.pid(12);
  PERFORM pg_temp.ok(r.bucket = 'never', 'M12 last_course_ids vazio não conta');
END
$match$;

-- ── Demografia: precedência, proveniência, conflitos, renda ─────────────────
DO $demo$
DECLARE
  r record;
  n_rows bigint; n_distinct bigint; n_profiles bigint;
BEGIN
  SELECT count(*), count(DISTINCT profile_id) INTO n_rows, n_distinct FROM public.vw_user_demographics_resolved;
  SELECT count(*) INTO n_profiles FROM public.user_profiles;
  PERFORM pg_temp.ok(n_rows = n_profiles AND n_distinct = n_profiles, 'demografia: uma linha por perfil');

  SELECT * INTO r FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(33);
  PERFORM pg_temp.ok(r.education = 'Ensino Médio Completo' AND r.education_source = 'profile' AND r.education_conflict, 'D01 perfil vence form divergente, conflito sinalizado');
  SELECT * INTO r FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(34);
  PERFORM pg_temp.ok(r.education = 'Ensino Médio Incompleto' AND r.education_source = 'partner_form' AND r.education_source_status = 'DRAFT'
                     AND r.education_source_date = '2026-09-10'::timestamptz AND NOT r.education_conflict, 'D02 perfil nulo + form DRAFT recupera (D6) com proveniência');
  SELECT * INTO r FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(35);
  PERFORM pg_temp.ok(r.education = 'Ensino Fundamental' AND r.education_source_status = 'redirected' AND r.education_conflict,
                     'D03 dois forms divergentes → mais recente (não MAX lexical) + conflito');
  SELECT * INTO r FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(36);
  PERFORM pg_temp.ok(r.school_type = 'Escola pública' AND r.school_type_source = 'partner_form', 'D04 answers por partner_forms.id; perfil vazio = ausente');
  SELECT * INTO r FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(37);
  PERFORM pg_temp.ok(r.race = 'Prefiro não informar' AND r.race_declined AND r.race_source = 'partner_form', 'D05 recusa via form preservada como resposta');
  SELECT * INTO r FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(38);
  PERFORM pg_temp.ok(r.race = 'Prefiro não informar' AND r.race_source = 'profile' AND r.race_conflict, 'D05b recusa no perfil vence form, conflito sinalizado');
  SELECT * INTO r FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(39);
  PERFORM pg_temp.ok(r.income_brl = 812.5 AND r.income_kind = 'brl' AND r.income_source = 'partner_form' AND r.income_band_sm IS NULL, 'D06 renda JSON da calculadora → BRL');
  SELECT * INTO r FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(40);
  PERFORM pg_temp.ok(r.income_brl IS NULL AND r.income_band_sm = 'Até 1 salário mínimo' AND r.income_kind = 'sm_band' AND r.income_source_status = 'redirected',
                     'D07 renda em SM → faixa própria, sem conversão (D3)');
  SELECT * INTO r FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(41);
  PERFORM pg_temp.ok(r.income_brl = 1500 AND r.income_source = 'profile' AND r.income_band_sm IS NULL AND NOT r.income_conflict, 'D08 renda exata do perfil vence faixa SM');
  SELECT * INTO r FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(42);
  PERFORM pg_temp.ok(r.race IS NULL AND r.income_brl IS NULL AND r.income_band_sm IS NULL AND r.school_type IS NULL AND r.race_source IS NULL,
                     'D09 cotas sem declaração não viram raça/renda/escola');
  SELECT * INTO r FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(43);
  PERFORM pg_temp.ok(r.education = 'Pós-Graduação' AND r.education_source = 'profile', 'D10 rótulo normalizado na view (D5)');
  PERFORM pg_temp.ok((SELECT education FROM public.user_profiles WHERE id = pg_temp.pid(43)) = 'Pós-Gradução', 'D10 dado gravado intocado');
  SELECT * INTO r FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(44);
  PERFORM pg_temp.ok(r.education IS NULL, 'D11 education_year ignorado');
  SELECT * INTO r FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(45);
  PERFORM pg_temp.ok(r.education IS NULL, 'D12 campo de outro parceiro não casa (isolamento por partner_id)');
  SELECT * INTO r FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(46);
  PERFORM pg_temp.ok(r.education IS NULL AND r.income_brl IS NULL AND r.income_band_sm IS NULL AND r.school_type IS NULL,
                     'D13 vocabulário/JSON inválidos e valor não-texto ignorados sem erro');
  SELECT * INTO r FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(47);
  PERFORM pg_temp.ok(r.income_brl = 300 AND r.income_source = 'onboarding_v0', 'D14 renda do onboarding v0');
  SELECT * INTO r FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(48);
  PERFORM pg_temp.ok(r.education IS NULL AND r.income_kind IS NULL, 'D15 answers não-objeto não quebra');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(49)), 'D16 candidatura órfã fora');
  PERFORM pg_temp.ok((SELECT count(DISTINCT rule_version) FROM public.vw_user_demographics_resolved) = 1, 'rule_version única e presente');
END
$demo$;

-- ── RPC: contrato, deltas, somas, idempotência ──────────────────────────────
DO $rpc$
DECLARE
  j0 jsonb := (SELECT j FROM tp1c_snap WHERE k = 'j0');
  j1 jsonb;
  j2 jsonb;
  mh jsonb;
  dim text;
  total bigint;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', (SELECT v FROM tp1c_ctx WHERE k = 'admin'), true);
  j1 := public.get_command_center_demographics()::jsonb;
  j2 := public.get_command_center_demographics()::jsonb;
  PERFORM pg_temp.ok(j1 = j2, 'RPC idempotente (2 chamadas = mesmo JSON)');

  mh := j1->'match_health';
  total := (mh->>'total')::bigint;
  PERFORM pg_temp.ok(jsonb_typeof(mh->'with_match') = 'number' AND jsonb_typeof(mh->'without_match') = 'number' AND jsonb_typeof(mh->'total') = 'number', 'match_health tipado como número');
  PERFORM pg_temp.ok(total = (SELECT count(*) FROM public.user_profiles), 'total = perfis');
  PERFORM pg_temp.ok((mh->>'with_match')::bigint + (mh->>'without_match')::bigint = total, 'with_match + without_match = total');
  PERFORM pg_temp.ok((mh->>'with_match')::bigint + (mh->>'attempted_no_result')::bigint + (mh->>'never')::bigint = total, 'concluded + attempted + never = total');
  PERFORM pg_temp.ok((mh->>'without_match')::bigint = (mh->>'attempted_no_result')::bigint + (mh->>'never')::bigint, 'without_match = attempted + never');

  PERFORM pg_temp.ok(total - (j0->'match_health'->>'total')::bigint = 27, 'delta total = 27 perfis de fixture');
  PERFORM pg_temp.ok((mh->>'with_match')::bigint - (j0->'match_health'->>'with_match')::bigint = 6, 'delta with_match = 6 (M01,M03,M04,M06,M07,M10)');
  PERFORM pg_temp.ok((mh->>'attempted_no_result')::bigint - (j0->'match_health'->>'attempted_no_result')::bigint = 2, 'delta attempted_no_result = 2 (M02,M05)');
  PERFORM pg_temp.ok((mh->>'never')::bigint - (j0->'match_health'->>'never')::bigint = 19, 'delta never = 19');
  PERFORM pg_temp.ok((mh->>'with_current_result')::bigint - (j0->'match_health'->>'with_current_result')::bigint = 4, 'delta with_current_result = 4');
  PERFORM pg_temp.ok((mh->>'with_current_mec_result')::bigint - (j0->'match_health'->>'with_current_mec_result')::bigint = 2, 'delta with_current_mec_result = 2');

  FOREACH dim IN ARRAY ARRAY['education','income','race','school_type'] LOOP
    PERFORM pg_temp.ok(jsonb_typeof(j1->dim) = 'array'
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j1->dim) e WHERE jsonb_typeof(e->'label') <> 'string' OR jsonb_typeof(e->'value') <> 'number'),
      format('%s: slices {label:string, value:number}', dim));
    PERFORM pg_temp.ok((SELECT sum((e->>'value')::bigint) FROM jsonb_array_elements(j1->dim) e) = total, format('%s: soma dos grupos = total', dim));
  END LOOP;

  PERFORM pg_temp.ok(pg_temp.slice(j1, 'income', 'Faixa declarada em salários mínimos') - pg_temp.slice(j0, 'income', 'Faixa declarada em salários mínimos') = 1, 'income: delta bucket SM = 1 (D07)');
  PERFORM pg_temp.ok(pg_temp.slice(j1, 'income', 'R$ 500 a R$ 1.000') - pg_temp.slice(j0, 'income', 'R$ 500 a R$ 1.000') = 1, 'income: D06 na faixa R$ 500–1.000');
  PERFORM pg_temp.ok(pg_temp.slice(j1, 'income', 'Até R$ 500') - pg_temp.slice(j0, 'income', 'Até R$ 500') = 1, 'income: D14 na faixa até R$ 500');
  PERFORM pg_temp.ok((SELECT e->>'label' FROM jsonb_array_elements(j1->'income') WITH ORDINALITY x(e, o) ORDER BY o DESC LIMIT 1) = 'Não respondeu', 'income: Não respondeu por último');
  PERFORM pg_temp.ok(pg_temp.slice(j1, 'race', 'Prefiro não informar') - pg_temp.slice(j0, 'race', 'Prefiro não informar') = 2, 'race: recusa é resposta (D05, D05b)');
  PERFORM pg_temp.ok(pg_temp.slice(j1, 'education', 'Pós-Gradução') = 0, 'education: rótulo com erro não aparece');
  PERFORM pg_temp.ok(pg_temp.slice(j1, 'education', 'Pós-Graduação') - pg_temp.slice(j0, 'education', 'Pós-Graduação') = 1, 'education: rótulo normalizado (D10)');

  PERFORM pg_temp.ok((j1->'provenance'->'education'->>'partner_form')::bigint - (j0->'provenance'->'education'->>'partner_form')::bigint = 2, 'provenance: education via form = 2 (D02,D03)');
  PERFORM pg_temp.ok((j1->'provenance'->'income'->>'sm_band')::bigint - (j0->'provenance'->'income'->>'sm_band')::bigint = 1, 'provenance: income sm_band = 1');
  PERFORM pg_temp.ok((j1->'provenance'->'income'->>'onboarding_v0')::bigint - (j0->'provenance'->'income'->>'onboarding_v0')::bigint = 1, 'provenance: income onboarding_v0 = 1');
  PERFORM pg_temp.ok((j1->'provenance'->'race'->>'conflicts')::bigint - (j0->'provenance'->'race'->>'conflicts')::bigint = 1, 'provenance: conflitos de raça = 1');
  PERFORM pg_temp.ok(j1->'provenance'->>'rule_version' IS NOT NULL, 'provenance: rule_version exposta');
END
$rpc$;

-- ── Segurança: gate admin, views sem acesso direto ──────────────────────────
DO $acl$
DECLARE
  v_admin text := (SELECT v FROM tp1c_ctx WHERE k = 'admin');
  j jsonb;
BEGIN
  PERFORM pg_temp.ok(
    (SELECT count(*) FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
      WHERE s.nspname = 'public' AND c.relname IN ('vw_user_match_evidence','vw_user_demographics_resolved')
        AND c.reloptions @> ARRAY['security_invoker=true']) = 2, 'views com security_invoker=true');
  PERFORM pg_temp.ok(NOT has_table_privilege('anon', 'public.vw_user_match_evidence', 'SELECT')
                 AND NOT has_table_privilege('authenticated', 'public.vw_user_match_evidence', 'SELECT')
                 AND NOT has_table_privilege('anon', 'public.vw_user_demographics_resolved', 'SELECT')
                 AND NOT has_table_privilege('authenticated', 'public.vw_user_demographics_resolved', 'SELECT'),
                 'anon/authenticated sem SELECT nas views');
  PERFORM pg_temp.ok(NOT has_function_privilege('anon', 'public.get_command_center_demographics()', 'EXECUTE'), 'anon sem EXECUTE na RPC');
  PERFORM pg_temp.ok((SELECT count(*) FROM pg_proc WHERE proname = 'get_command_center_demographics' AND pronamespace = 'public'::regnamespace) = 1, 'RPC sem overload');
  PERFORM pg_temp.ok((SELECT prosecdef AND proconfig @> ARRAY['search_path=public'] AND pg_get_function_result(oid) = 'json' AND pronargs = 0
                        FROM pg_proc WHERE proname = 'get_command_center_demographics' AND pronamespace = 'public'::regnamespace),
                     'RPC: SECURITY DEFINER, search_path fixo, () → json');

  -- Acesso real como authenticated + admin (caminho do PostgREST): RPC funciona
  -- mesmo sem SELECT nas views, porque é SECURITY DEFINER.
  PERFORM set_config('request.jwt.claim.sub', v_admin, true);
  SET LOCAL ROLE authenticated;
  j := public.get_command_center_demographics()::jsonb;
  RESET ROLE;
  PERFORM pg_temp.ok(j ? 'match_health', 'admin autenticado lê a RPC');

  BEGIN
    PERFORM set_config('request.jwt.claim.sub', pg_temp.pid(8)::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM public.get_command_center_demographics();
    RAISE EXCEPTION 'TP1C_FAIL: usuário comum acessou a RPC';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  RESET ROLE;
  PERFORM pg_temp.ok(true, 'usuário comum → 42501 na RPC');

  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.get_command_center_demographics();
    RAISE EXCEPTION 'TP1C_FAIL: anon acessou a RPC';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  RESET ROLE;
  PERFORM pg_temp.ok(true, 'anon → 42501 na RPC');

  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_admin, true);
    SET LOCAL ROLE authenticated;
    PERFORM 1 FROM public.vw_user_match_evidence LIMIT 1;
    RAISE EXCEPTION 'TP1C_FAIL: authenticated leu vw_user_match_evidence direto';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  RESET ROLE;
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM 1 FROM public.vw_user_demographics_resolved LIMIT 1;
    RAISE EXCEPTION 'TP1C_FAIL: anon leu vw_user_demographics_resolved direto';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  RESET ROLE;
  PERFORM pg_temp.ok(true, 'leitura direta das views negada (admin autenticado e anon)');
END
$acl$;

-- ── Não-mutação: views e RPC não escrevem nas fontes ────────────────────────
DO $nomut$
DECLARE
  fp_mid text := pg_temp.fingerprint();
BEGIN
  PERFORM set_config('request.jwt.claim.sub', (SELECT v FROM tp1c_ctx WHERE k = 'admin'), true);
  PERFORM public.get_command_center_demographics();
  PERFORM count(*) FROM public.vw_user_match_evidence;
  PERFORM count(*) FROM public.vw_user_demographics_resolved;
  PERFORM pg_temp.ok(pg_temp.fingerprint() = fp_mid, 'fontes idênticas antes/depois de ler views e RPC');
END
$nomut$;
