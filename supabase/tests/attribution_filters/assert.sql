-- Asserções dos filtros first-touch (TP-7 / NHB-123b). Roda depois de
-- fixture.sql, baseline.sql e da migration, na mesma transação.
-- Termina SEMPRE com RAISE EXCEPTION: 'TP7_ALL_PASS' ou 'TP7_FAIL'. A exceção
-- desfaz migration e fixtures — nada fica no banco.

CREATE TEMP TABLE tp7_results (label text, expected text, actual text);

CREATE FUNCTION pg_temp.names(j json) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(replace(x->>'full_name', 'TP7FX ', ''), ',' ORDER BY ord), '')
  FROM json_array_elements(j->'data') WITH ORDINALITY AS a(x, ord)
$$;

CREATE FUNCTION pg_temp.ids(j json) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(x->>'id', ',' ORDER BY ord), '')
  FROM json_array_elements(j->'data') WITH ORDINALITY AS a(x, ord)
$$;

CREATE FUNCTION pg_temp.students(
  p_campaign uuid DEFAULT NULL, p_channel uuid DEFAULT NULL, p_unattr boolean DEFAULT NULL,
  p_page int DEFAULT 0, p_size int DEFAULT 50, p_income_min numeric DEFAULT NULL
) RETURNS json LANGUAGE sql AS $$
  SELECT public.get_students_paginated(
    p_page => p_page, p_page_size => p_size, p_filter_name => 'TP7FX',
    p_filter_income_min => p_income_min,
    p_sort_by => 'full_name', p_sort_order => 'asc',
    p_filter_campaign_id => p_campaign, p_filter_channel_id => p_channel, p_filter_unattributed => p_unattr)
$$;

CREATE FUNCTION pg_temp.stats_total(
  p_campaign uuid DEFAULT NULL, p_channel uuid DEFAULT NULL, p_unattr boolean DEFAULT NULL, p_income_min numeric DEFAULT NULL
) RETURNS text LANGUAGE sql AS $$
  SELECT public.get_student_stats(
    filter_full_name => 'TP7FX', filter_income_min => p_income_min,
    p_filter_campaign_id => p_campaign, p_filter_channel_id => p_channel, p_filter_unattributed => p_unattr)->>'total_students'
$$;

CREATE FUNCTION pg_temp.apps(p_campaign uuid DEFAULT NULL, p_channel uuid DEFAULT NULL, p_unattr boolean DEFAULT NULL)
RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(replace(r.full_name, 'TP7FX ', ''), ',' ORDER BY r.created_at), '')
  FROM public.get_student_applications_with_details(
    p_filter_campaign_id => p_campaign, p_filter_channel_id => p_channel, p_filter_unattributed => p_unattr) r
  WHERE r.full_name LIKE 'TP7FX %'
$$;

CREATE FUNCTION pg_temp.ck(label text, expected text, actual text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO tp7_results VALUES (label, expected, actual)
$$;

DO $$
DECLARE
  A  constant uuid := '7f000000-0000-4000-a000-00000000000a';
  B  constant uuid := '7f000000-0000-4000-a000-00000000000b';
  X  constant uuid := '7f000000-0000-4000-b000-00000000000e';
  Y  constant uuid := '7f000000-0000-4000-b000-00000000000f';
  r  record;
  v_state text;
BEGIN
  -- 1. Filtro nulo preserva o baseline (dados reais + fixtures).
  FOR r IN SELECT * FROM tp7_baseline WHERE sb IS NOT NULL LOOP
    PERFORM pg_temp.ck('baseline ' || r.k, r.v,
      pg_temp.ids(public.get_students_paginated(
        r.pg, 50, NULL, NULL, NULL, NULL, NULL, NULL, NULL, r.sb, r.so, NULL, NULL, NULL)));
  END LOOP;
  PERFORM pg_temp.ck('baseline students_count', (SELECT v FROM tp7_baseline WHERE k = 'students_count'),
    public.get_students_paginated(0, 1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'created_at', 'desc', NULL, NULL, NULL)->>'count');
  PERFORM pg_temp.ck('baseline stats_all', (SELECT v FROM tp7_baseline WHERE k = 'stats_all'),
    public.get_student_stats(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)::text);
  PERFORM pg_temp.ck('baseline stats_state_pe', (SELECT v FROM tp7_baseline WHERE k = 'stats_state_pe'),
    public.get_student_stats(NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'PE', NULL, NULL)::text);
  PERFORM pg_temp.ck('baseline applications_all', (SELECT v FROM tp7_baseline WHERE k = 'applications_all'),
    (SELECT coalesce(string_agg(r2.id::text, ',' ORDER BY r2.id), '') FROM public.get_student_applications_with_details(NULL) r2));

  -- 2. Recortes first-touch (nomes em ordem full_name asc).
  PERFORM pg_temp.ck('sem filtro (fixtures)',       'U1,U2,U3,U4,U5,U6,U7', pg_temp.names(pg_temp.students()));
  PERFORM pg_temp.ck('campanha A',                  'U1,U2,U7', pg_temp.names(pg_temp.students(A)));
  PERFORM pg_temp.ck('campanha B (U2 é só last)',   'U3',       pg_temp.names(pg_temp.students(B)));
  PERFORM pg_temp.ck('divulgador X',                'U1,U3,U7', pg_temp.names(pg_temp.students(NULL, X)));
  PERFORM pg_temp.ck('divulgador Y',                'U2,U4',    pg_temp.names(pg_temp.students(NULL, Y)));
  PERFORM pg_temp.ck('A + X',                       'U1,U7',    pg_temp.names(pg_temp.students(A, X)));
  PERFORM pg_temp.ck('A + Y',                       'U2',       pg_temp.names(pg_temp.students(A, Y)));
  PERFORM pg_temp.ck('B + Y (sem link) vazio',      '',         pg_temp.names(pg_temp.students(B, Y)));
  PERFORM pg_temp.ck('B + Y count 0',               '0',        pg_temp.students(B, Y)->>'count');
  PERFORM pg_temp.ck('sem atribuição',              'U5,U6',    pg_temp.names(pg_temp.students(NULL, NULL, true)));
  PERFORM pg_temp.ck('unattributed=false ignora',   'U1,U2,U3,U4,U5,U6,U7', pg_temp.names(pg_temp.students(NULL, NULL, false)));
  PERFORM pg_temp.ck('A + renda>=400 (user_income)', 'U7',      pg_temp.names(pg_temp.students(A, NULL, NULL, 0, 50, 400)));

  -- 3. Contagem e paginação coerentes, sem multiplicar pessoas.
  PERFORM pg_temp.ck('A count',                     '3',        pg_temp.students(A)->>'count');
  PERFORM pg_temp.ck('A página 0 (2/pág)',          'U1,U2',    pg_temp.names(pg_temp.students(A, NULL, NULL, 0, 2)));
  PERFORM pg_temp.ck('A página 1 (2/pág)',          'U7',       pg_temp.names(pg_temp.students(A, NULL, NULL, 1, 2)));
  PERFORM pg_temp.ck('A count na página 1',         '3',        pg_temp.students(A, NULL, NULL, 1, 2)->>'count');
  PERFORM pg_temp.ck('sem duplicatas (todas)',      '7',
    (SELECT count(DISTINCT el->>'id')::text FROM json_array_elements(pg_temp.students()->'data') el));

  -- 4. Stats = lista para o mesmo recorte.
  PERFORM pg_temp.ck('stats A = lista A',           pg_temp.students(A)->>'count',             pg_temp.stats_total(A));
  PERFORM pg_temp.ck('stats X = lista X',           pg_temp.students(NULL, X)->>'count',       pg_temp.stats_total(NULL, X));
  PERFORM pg_temp.ck('stats sem atrib = lista',     pg_temp.students(NULL, NULL, true)->>'count', pg_temp.stats_total(NULL, NULL, true));
  PERFORM pg_temp.ck('stats renda = lista renda',   pg_temp.students(NULL, NULL, NULL, 0, 50, 400)->>'count', pg_temp.stats_total(NULL, NULL, NULL, 400));

  -- 5. Inscrições pelo first-touch do aluno (uma linha por inscrição).
  PERFORM pg_temp.ck('inscrições A',                'U1,U1',    pg_temp.apps(A));
  PERFORM pg_temp.ck('inscrições B',                'U3',       pg_temp.apps(B));
  PERFORM pg_temp.ck('inscrições sem atribuição',   'U6',       pg_temp.apps(NULL, NULL, true));
  PERFORM pg_temp.ck('inscrições sem filtro',       'U1,U1,U3,U6', pg_temp.apps());

  -- 6. Combinação incompatível → 22023 nas três RPCs.
  BEGIN
    PERFORM pg_temp.students(A, NULL, true);
    PERFORM pg_temp.ck('22023 students', '22023', 'sem erro');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    PERFORM pg_temp.ck('22023 students', '22023', v_state);
  END;
  BEGIN
    PERFORM pg_temp.stats_total(NULL, X, true);
    PERFORM pg_temp.ck('22023 stats', '22023', 'sem erro');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    PERFORM pg_temp.ck('22023 stats', '22023', v_state);
  END;
  BEGIN
    PERFORM pg_temp.apps(A, NULL, true);
    PERFORM pg_temp.ck('22023 applications', '22023', 'sem erro');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    PERFORM pg_temp.ck('22023 applications', '22023', v_state);
  END;

  -- 7. Guard: quem não é backoffice recebe 42501 nas três.
  PERFORM set_config('request.jwt.claims', '{"sub":"7f000000-0000-4000-f000-0000000000ee","role":"authenticated"}', true);
  PERFORM set_config('request.jwt.claim.sub', '7f000000-0000-4000-f000-0000000000ee', true);
  BEGIN
    PERFORM pg_temp.students();
    PERFORM pg_temp.ck('42501 students', '42501', 'sem erro');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    PERFORM pg_temp.ck('42501 students', '42501', v_state);
  END;
  BEGIN
    PERFORM pg_temp.stats_total();
    PERFORM pg_temp.ck('42501 stats', '42501', 'sem erro');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    PERFORM pg_temp.ck('42501 stats', '42501', v_state);
  END;
  BEGIN
    PERFORM pg_temp.apps();
    PERFORM pg_temp.ck('42501 applications', '42501', 'sem erro');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    PERFORM pg_temp.ck('42501 applications', '42501', v_state);
  END;

  -- 8. ACL e ausência de overload (PostgREST não pode ver dois candidatos).
  PERFORM pg_temp.ck('overloads', '1,1,1',
    (SELECT string_agg(n::text, ',' ORDER BY f) FROM (
       SELECT f, (SELECT count(*) FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
                  WHERE ns.nspname = 'public' AND p.proname = f) n
       FROM unnest(ARRAY['get_student_applications_with_details','get_student_stats','get_students_paginated']) f) s));
  PERFORM pg_temp.ck('anon sem EXECUTE', 'f,f,f,f,f',
    concat_ws(',',
      has_function_privilege('anon', 'public.get_students_paginated(integer,integer,text,text,text,boolean,numeric,numeric,text[],text,text,text,integer,integer,uuid,uuid,boolean)', 'EXECUTE'),
      has_function_privilege('anon', 'public.get_student_stats(text,text,text,boolean,numeric,numeric,text[],text,integer,integer,uuid,uuid,boolean)', 'EXECUTE'),
      has_function_privilege('anon', 'public.get_student_applications_with_details(uuid,uuid,uuid,boolean)', 'EXECUTE'),
      has_function_privilege('anon', 'public.matches_first_touch_attribution(uuid,uuid,uuid,boolean)', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.matches_first_touch_attribution(uuid,uuid,uuid,boolean)', 'EXECUTE')));
  PERFORM pg_temp.ck('authenticated com EXECUTE', 't,t,t',
    concat_ws(',',
      has_function_privilege('authenticated', 'public.get_students_paginated(integer,integer,text,text,text,boolean,numeric,numeric,text[],text,text,text,integer,integer,uuid,uuid,boolean)', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.get_student_stats(text,text,text,boolean,numeric,numeric,text[],text,integer,integer,uuid,uuid,boolean)', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.get_student_applications_with_details(uuid,uuid,uuid,boolean)', 'EXECUTE')));
END $$;

DO $$
DECLARE
  v_fail text;
  v_total int;
BEGIN
  SELECT count(*) INTO v_total FROM tp7_results;
  SELECT string_agg(format('[%s] esperado=%s obtido=%s', label, expected, coalesce(actual, 'NULL')), ' | ')
    INTO v_fail
  FROM tp7_results WHERE actual IS DISTINCT FROM expected;

  IF v_fail IS NOT NULL THEN
    RAISE EXCEPTION 'TP7_FAIL (%/% falharam): %',
      (SELECT count(*) FROM tp7_results WHERE actual IS DISTINCT FROM expected), v_total, v_fail;
  END IF;
  -- Sucesso também aborta: é o que garante o rollback no ambiente compartilhado.
  RAISE EXCEPTION 'TP7_ALL_PASS (% verificações; transação desfeita)', v_total;
END $$;
