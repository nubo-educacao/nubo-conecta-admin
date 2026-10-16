-- Asserções da integração da Sprint 9.0 no DEV. Roda dentro da transação montada
-- por run_dev.sh, depois das migrations; nunca persiste (o bundle termina em RAISE).
-- Fixtures usam UUIDs 7f9000… e existem só nesta transação.

CREATE TEMP TABLE s9_log (n serial, msg text) ON COMMIT DROP;
GRANT ALL ON s9_log TO PUBLIC;
GRANT ALL ON SEQUENCE s9_log_n_seq TO PUBLIC;

CREATE OR REPLACE FUNCTION pg_temp.s9_as(p_user uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_user::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
END $$;

-- Fixtures: comum, admin (Controle de usuários), Parceiros, membro de uma instituição.
INSERT INTO auth.users (id) VALUES
  ('7f900000-0000-4000-a000-000000000001'),
  ('7f900000-0000-4000-a000-000000000002'),
  ('7f900000-0000-4000-a000-000000000003'),
  ('7f900000-0000-4000-a000-000000000004');
INSERT INTO public.user_permissions (user_id, permission) VALUES
  ('7f900000-0000-4000-a000-000000000002', 'Controle de usuários'),
  ('7f900000-0000-4000-a000-000000000003', 'Parceiros');
INSERT INTO public.institutions (id, name, is_partner) VALUES
  ('7f900000-0000-4000-b000-000000000001', '[S9-INT] instituição A', true),
  ('7f900000-0000-4000-b000-000000000002', '[S9-INT] instituição B', true);
-- partners_users.partner_id -> partner_institutions(institution_id) = id da instituição
INSERT INTO public.partner_institutions (institution_id) VALUES
  ('7f900000-0000-4000-b000-000000000001'),
  ('7f900000-0000-4000-b000-000000000002');
INSERT INTO public.partners_users (user_id, partner_id) VALUES
  ('7f900000-0000-4000-a000-000000000004', '7f900000-0000-4000-b000-000000000001');

DO $$
DECLARE
  v_sig text;
  v_n bigint;
  v_ok boolean;
  v_denied boolean;
BEGIN
  -- 1. Estrutura reconciliada
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='user_profiles' AND column_name='phone'
                    AND data_type='text' AND is_nullable='YES' AND column_default IS NULL) THEN
    RAISE EXCEPTION 'S9_FAIL: user_profiles.phone ausente ou com contrato diferente de produção';
  END IF;
  INSERT INTO s9_log(msg) VALUES ('phone text nullable sem default');

  -- 2. Nenhuma função da entrega executável por anon/PUBLIC (exceto as públicas por desenho)
  FOREACH v_sig IN ARRAY ARRAY[
    'public.get_admin_funnel_users()',
    'public.get_partner_applications_by_institution(uuid)',
    'public.get_partner_redirect_users(uuid)',
    'public.get_tp2_partner_funnel(uuid,integer)',
    'public.get_partner_institution_redirect_users(uuid)',
    'public.get_mec_engagement_dashboard(text,integer)',
    'public.get_command_center_opportunity_interest(timestamptz,timestamptz,integer)',
    'public.get_command_center_demographics()',
    'public.cron_check_deadlines()',
    'public.cron_deadlines_secret_status(text)'
  ] LOOP
    IF to_regprocedure(v_sig) IS NULL THEN
      RAISE EXCEPTION 'S9_FAIL: função ausente %', v_sig;
    END IF;
    IF has_function_privilege('anon', v_sig, 'EXECUTE') THEN
      RAISE EXCEPTION 'S9_FAIL: anon executa %', v_sig;
    END IF;
  END LOOP;
  INSERT INTO s9_log(msg) VALUES ('anon sem EXECUTE nas RPCs da entrega');

  FOR v_sig IN SELECT p.oid::regprocedure::text FROM pg_proc p
                WHERE p.pronamespace='public'::regnamespace
                  AND p.proname IN ('get_students_paginated','get_student_stats','get_student_applications_with_details')
  LOOP
    IF has_function_privilege('anon', v_sig, 'EXECUTE') THEN
      RAISE EXCEPTION 'S9_FAIL: anon executa %', v_sig;
    END IF;
  END LOOP;
  SELECT count(*) INTO v_n FROM pg_proc WHERE pronamespace='public'::regnamespace
     AND proname IN ('get_students_paginated','get_student_stats','get_student_applications_with_details');
  IF v_n <> 3 THEN RAISE EXCEPTION 'S9_FAIL: overload nas RPCs de filtros (% assinaturas)', v_n; END IF;
  INSERT INTO s9_log(msg) VALUES ('filtros: 1 assinatura por RPC, anon sem EXECUTE');

  -- Busca do app continua pública (main 20261009150000/180000)
  IF NOT has_function_privilege('anon', 'public.search_opportunities_v2(text,double precision,double precision)', 'EXECUTE') THEN
    RAISE EXCEPTION 'S9_FAIL: search_opportunities_v2 deixou de ser pública';
  END IF;
  INSERT INTO s9_log(msg) VALUES ('search_opportunities_v2 pública');
END $$;

-- 3. Guards internos, papel a papel (authenticated + JWT)
SET LOCAL ROLE authenticated;
DO $$
DECLARE
  v_n bigint;
  v_err text;
BEGIN
  -- usuário comum: negado nas duas
  PERFORM pg_temp.s9_as('7f900000-0000-4000-a000-000000000001');
  BEGIN PERFORM * FROM public.get_admin_funnel_users(); RAISE EXCEPTION 'S9_FAIL: comum leu funnel users';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM * FROM public.get_partner_applications_by_institution('7f900000-0000-4000-b000-000000000001');
    RAISE EXCEPTION 'S9_FAIL: comum leu candidaturas da instituição';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM * FROM public.get_partner_applications_by_institution(NULL);
    RAISE EXCEPTION 'S9_FAIL: comum leu todas as candidaturas';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  INSERT INTO s9_log(msg) VALUES ('comum: 42501 em funnel users e candidaturas');

  -- admin: lê tudo
  PERFORM pg_temp.s9_as('7f900000-0000-4000-a000-000000000002');
  PERFORM * FROM public.get_admin_funnel_users();
  PERFORM * FROM public.get_partner_applications_by_institution(NULL);
  PERFORM * FROM public.get_students_paginated(1, 5, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'full_name', 'asc', NULL, NULL, NULL);
  INSERT INTO s9_log(msg) VALUES ('admin: funnel users, candidaturas (todas) e Estudantes sem 42703');

  -- permissão Parceiros: lê funnel users (export do /b2b-dashboard) e todas as candidaturas
  PERFORM pg_temp.s9_as('7f900000-0000-4000-a000-000000000003');
  PERFORM * FROM public.get_admin_funnel_users();
  PERFORM * FROM public.get_partner_applications_by_institution(NULL);
  INSERT INTO s9_log(msg) VALUES ('Parceiros: funnel users e candidaturas');

  -- membro do portal: só a própria instituição
  PERFORM pg_temp.s9_as('7f900000-0000-4000-a000-000000000004');
  PERFORM * FROM public.get_partner_applications_by_institution('7f900000-0000-4000-b000-000000000001');
  BEGIN PERFORM * FROM public.get_partner_applications_by_institution('7f900000-0000-4000-b000-000000000002');
    RAISE EXCEPTION 'S9_FAIL: parceiro leu outra instituição';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM * FROM public.get_partner_applications_by_institution(NULL);
    RAISE EXCEPTION 'S9_FAIL: parceiro leu todas as candidaturas';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM * FROM public.get_admin_funnel_users(); RAISE EXCEPTION 'S9_FAIL: parceiro leu funnel users';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  -- portal continua com o funil e os redirects da própria instituição (TP-2)
  PERFORM * FROM public.get_tp2_partner_funnel('7f900000-0000-4000-b000-000000000001', NULL);
  PERFORM * FROM public.get_partner_institution_redirect_users('7f900000-0000-4000-b000-000000000001');
  INSERT INTO s9_log(msg) VALUES ('portal: própria instituição ok; outra/NULL/funnel users 42501; funil TP-2 ok');
END $$;
RESET ROLE;

-- anon: sem EXECUTE (erro de privilégio antes do corpo)
SET LOCAL ROLE anon;
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', '{"role":"anon"}', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  BEGIN PERFORM * FROM public.get_partner_applications_by_institution(NULL);
    RAISE EXCEPTION 'S9_FAIL: anon leu candidaturas';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM * FROM public.get_admin_funnel_users(); RAISE EXCEPTION 'S9_FAIL: anon leu funnel users';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  INSERT INTO s9_log(msg) VALUES ('anon: 42501 em funnel users e candidaturas');
END $$;
RESET ROLE;
