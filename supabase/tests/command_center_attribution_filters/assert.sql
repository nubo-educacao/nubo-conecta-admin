-- Asserções dos filtros first-touch do Command Center. Roda depois de
-- fixture.sql, baseline.sql e da migration 20261016140000, na mesma transação.
-- Termina SEMPRE com RAISE EXCEPTION: 'CCAF_ALL_PASS' ou 'CCAF_FAIL'. A exceção
-- desfaz migration e fixtures — nada fica no banco.

CREATE TEMP TABLE ccaf_results (n serial, label text, expected text, actual text);

CREATE FUNCTION pg_temp.ck(label text, expected text, actual text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO ccaf_results (label, expected, actual) VALUES (label, expected, actual)
$$;

-- Cliques na janela das fixtures (uma única oportunidade): '' quando vazio.
CREATE FUNCTION pg_temp.clicks(p_campaign uuid DEFAULT NULL, p_channel uuid DEFAULT NULL, p_unattr boolean DEFAULT NULL)
RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(r.clicks::text, ',' ORDER BY r.clicks DESC), '')
  FROM public.get_command_center_opportunity_interest(
    p_from => '2031-01-01T00:00:00Z', p_to => '2031-01-02T00:00:00Z', p_limit => 10,
    p_filter_campaign_id => p_campaign, p_filter_channel_id => p_channel, p_filter_unattributed => p_unattr) r
$$;

CREATE FUNCTION pg_temp.demo(p_campaign uuid DEFAULT NULL, p_channel uuid DEFAULT NULL, p_unattr boolean DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.get_command_center_demographics(
    p_filter_campaign_id => p_campaign, p_filter_channel_id => p_channel, p_filter_unattributed => p_unattr)::jsonb
$$;

-- "total=N sums=N,N,N,N match=N" — cada dimensão tem de somar o total.
CREATE FUNCTION pg_temp.demo_shape(j jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT format('total=%s sums=%s match=%s',
    j->'match_health'->>'total',
    (SELECT string_agg(coalesce((SELECT sum((s->>'value')::bigint) FROM jsonb_array_elements(j->d) s), 0)::text, ',' ORDER BY d)
       FROM unnest(ARRAY['education', 'income', 'race', 'school_type']) d),
    (j->'match_health'->>'with_match')::int + (j->'match_health'->>'without_match')::int)
$$;

CREATE FUNCTION pg_temp.slices(j jsonb, dim text) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg((s->>'label') || '=' || (s->>'value'), ',' ORDER BY o), '')
  FROM jsonb_array_elements(j->dim) WITH ORDINALITY AS a(s, o)
$$;

CREATE FUNCTION pg_temp.shape_of(n bigint) RETURNS text LANGUAGE sql AS $$
  SELECT format('total=%s sums=%s,%s,%s,%s match=%s', n, n, n, n, n, n)
$$;

DO $$
DECLARE
  A  constant uuid := 'ccaf0000-0000-4000-a000-00000000000a';
  B  constant uuid := 'ccaf0000-0000-4000-a000-00000000000b';
  X  constant uuid := 'ccaf0000-0000-4000-b000-00000000000e';
  Y  constant uuid := 'ccaf0000-0000-4000-b000-00000000000f';
  r  record;
  v_state text;
  v_unattr bigint;
  v_j jsonb;
BEGIN
  -- 0. Assinaturas antigas não existem mais; uma única assinatura por função.
  PERFORM pg_temp.ck('assinatura antiga interest removida', 'true',
    (to_regprocedure('public.get_command_center_opportunity_interest(timestamptz,timestamptz,integer)') IS NULL)::text);
  PERFORM pg_temp.ck('assinatura antiga demographics removida', 'true',
    (to_regprocedure('public.get_command_center_demographics()') IS NULL)::text);
  PERFORM pg_temp.ck('uma assinatura por função', '1,1',
    (SELECT string_agg(c::text, ',' ORDER BY f) FROM (
       SELECT f, (SELECT count(*) FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
                  WHERE ns.nspname = 'public' AND p.proname = f) c
       FROM unnest(ARRAY['get_command_center_demographics', 'get_command_center_opportunity_interest']) f) s));

  -- 1. Filtro nulo preserva o baseline (dados reais + fixtures), byte a byte.
  FOR r IN SELECT * FROM ccaf_baseline WHERE f IS NOT NULL LOOP
    PERFORM pg_temp.ck('baseline ' || r.k, r.v, pg_temp.interest_text(r.f, r.t, r.l));
  END LOOP;
  PERFORM pg_temp.ck('baseline demographics', (SELECT v FROM ccaf_baseline WHERE k = 'demographics'),
    public.get_command_center_demographics()::text);
  PERFORM pg_temp.ck('baseline demographics (NULLs explícitos)', (SELECT v FROM ccaf_baseline WHERE k = 'demographics'),
    public.get_command_center_demographics(NULL::uuid, NULL::uuid, NULL::boolean)::text);
  PERFORM pg_temp.ck('interest sem filtro (fixtures, inclui anônimo)', '16', pg_temp.clicks());
  PERFORM pg_temp.ck('interest unattributed=false ignora', '16', pg_temp.clicks(NULL, NULL, false));

  -- 2. Interesse por first-touch (anônimos fora com filtro ativo).
  PERFORM pg_temp.ck('interest campanha A (inclui link arquivado)', '8', pg_temp.clicks(A));
  PERFORM pg_temp.ck('interest campanha B (U2 é só last-touch)',   '2', pg_temp.clicks(B));
  PERFORM pg_temp.ck('interest divulgador X',                      '6', pg_temp.clicks(NULL, X));
  PERFORM pg_temp.ck('interest divulgador Y',                      '4', pg_temp.clicks(NULL, Y));
  PERFORM pg_temp.ck('interest A + X',                             '4', pg_temp.clicks(A, X));
  PERFORM pg_temp.ck('interest B + Y (sem link) vazio',            '',  pg_temp.clicks(B, Y));
  PERFORM pg_temp.ck('interest sem atribuição (só U6 logado)',     '1', pg_temp.clicks(NULL, NULL, true));

  -- 3. Demografia por first-touch: recorte nas duas views, somas = total.
  v_j := pg_temp.demo(A);
  PERFORM pg_temp.ck('demo A shape',      pg_temp.shape_of(3), pg_temp.demo_shape(v_j));
  PERFORM pg_temp.ck('demo A with_match', '1', v_j->'match_health'->>'with_match');
  PERFORM pg_temp.ck('demo A education',
    'Ensino Médio Completo=1,Ensino Superior Completo=1,Não respondeu=1', pg_temp.slices(v_j, 'education'));
  PERFORM pg_temp.ck('demo A race',       'Parda=1,Não respondeu=2', pg_temp.slices(v_j, 'race'));
  v_j := pg_temp.demo(B);
  PERFORM pg_temp.ck('demo B shape',      pg_temp.shape_of(1), pg_temp.demo_shape(v_j));
  PERFORM pg_temp.ck('demo B attempted',  '1', v_j->'match_health'->>'attempted_no_result');
  PERFORM pg_temp.ck('demo X shape',      pg_temp.shape_of(3), pg_temp.demo_shape(pg_temp.demo(NULL, X)));
  PERFORM pg_temp.ck('demo Y shape',      pg_temp.shape_of(2), pg_temp.demo_shape(pg_temp.demo(NULL, Y)));
  PERFORM pg_temp.ck('demo A + Y shape',  pg_temp.shape_of(1), pg_temp.demo_shape(pg_temp.demo(A, Y)));
  v_j := pg_temp.demo(B, Y);
  PERFORM pg_temp.ck('demo B + Y vazio',  'total=0 sums=0,0,0,0 match=0', pg_temp.demo_shape(v_j));
  PERFORM pg_temp.ck('demo B + Y education []', '[]', (v_j->'education')::text);

  SELECT count(*) INTO v_unattr FROM public.user_profiles p
  WHERE NOT EXISTS (SELECT 1 FROM public.user_attribution ua WHERE ua.user_id = p.id AND ua.first_touch_link_id IS NOT NULL);
  PERFORM pg_temp.ck('demo sem atribuição shape (= perfis sem first-touch)',
    pg_temp.shape_of(v_unattr), pg_temp.demo_shape(pg_temp.demo(NULL, NULL, true)));
  PERFORM pg_temp.ck('demo unattributed=false = baseline', (SELECT v FROM ccaf_baseline WHERE k = 'demographics'),
    public.get_command_center_demographics(NULL::uuid, NULL::uuid, false)::text);

  -- 4. Combinação incompatível → 22023 nas duas RPCs.
  BEGIN
    PERFORM pg_temp.clicks(A, NULL, true);
    PERFORM pg_temp.ck('22023 interest', '22023', 'sem erro');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    PERFORM pg_temp.ck('22023 interest', '22023', v_state);
  END;
  BEGIN
    PERFORM pg_temp.demo(NULL, X, true);
    PERFORM pg_temp.ck('22023 demographics', '22023', 'sem erro');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    PERFORM pg_temp.ck('22023 demographics', '22023', v_state);
  END;

  -- 5. ACL e atributos preservados.
  PERFORM pg_temp.ck('anon sem EXECUTE', 'f,f',
    concat_ws(',',
      has_function_privilege('anon', 'public.get_command_center_opportunity_interest(timestamptz,timestamptz,integer,uuid,uuid,boolean)', 'EXECUTE'),
      has_function_privilege('anon', 'public.get_command_center_demographics(uuid,uuid,boolean)', 'EXECUTE')));
  PERFORM pg_temp.ck('authenticated com EXECUTE', 't,t',
    concat_ws(',',
      has_function_privilege('authenticated', 'public.get_command_center_opportunity_interest(timestamptz,timestamptz,integer,uuid,uuid,boolean)', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.get_command_center_demographics(uuid,uuid,boolean)', 'EXECUTE')));
  PERFORM pg_temp.ck('SECURITY DEFINER + search_path=public', 'true {search_path=public},true {search_path=public}',
    (SELECT string_agg(p.prosecdef::text || ' ' || coalesce(p.proconfig::text, 'NULL'), ',' ORDER BY p.proname)
     FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
     WHERE ns.nspname = 'public' AND p.proname IN ('get_command_center_demographics', 'get_command_center_opportunity_interest')));

  -- 6. Guard: quem não é backoffice recebe 42501 nas duas, com ou sem filtro.
  PERFORM set_config('request.jwt.claims', '{"sub":"ccaf0000-0000-4000-f000-0000000000ee","role":"authenticated"}', true);
  PERFORM set_config('request.jwt.claim.sub', 'ccaf0000-0000-4000-f000-0000000000ee', true);
  BEGIN
    PERFORM pg_temp.clicks(A);
    PERFORM pg_temp.ck('42501 interest', '42501', 'sem erro');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    PERFORM pg_temp.ck('42501 interest', '42501', v_state);
  END;
  BEGIN
    PERFORM pg_temp.demo();
    PERFORM pg_temp.ck('42501 demographics', '42501', 'sem erro');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    PERFORM pg_temp.ck('42501 demographics', '42501', v_state);
  END;
END $$;

DO $$
DECLARE
  v_fail text;
  v_total int;
BEGIN
  SELECT count(*) INTO v_total FROM ccaf_results;
  SELECT string_agg(format('[%s] esperado=%s obtido=%s', label, expected, coalesce(actual, 'NULL')), ' | ' ORDER BY n)
    INTO v_fail
  FROM ccaf_results WHERE actual IS DISTINCT FROM expected;

  IF v_fail IS NOT NULL THEN
    RAISE EXCEPTION 'CCAF_FAIL (%/% falharam): %',
      (SELECT count(*) FROM ccaf_results WHERE actual IS DISTINCT FROM expected), v_total, v_fail;
  END IF;
  -- Sucesso também aborta: é o que garante o rollback no ambiente compartilhado.
  RAISE EXCEPTION 'CCAF_ALL_PASS (% verificações + % de agregados NUB-RD-93; transação desfeita)', v_total,
    (SELECT n FROM ccaf_agg_pass);
END $$;
