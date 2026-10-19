-- NUB-RD-93 — agregações das Edges do Command Center em SQL
-- (cc_stats_aggregate, cc_activity_aggregate, cc_rankings_aggregate).
-- Roda depois de fixture.sql e das migrations, na transação de run_dev.sh, e
-- antes de assert.sql. Falha → RAISE 'CCAF_FAIL agregados …'; sucesso grava a
-- contagem em ccaf_agg_pass, que assert.sql soma ao CCAF_ALL_PASS.
--
-- Os valores esperados reproduzem, à mão, a regra das Edges ANTES da mudança
-- (recorte em memória por resolveAttributedUserIds/keepAllowed), sobre as
-- fixtures do CCAF:
--   janela [2031-01-01T03Z, 2031-01-02T03Z) · anterior [2030-12-31T03Z, 2031-01-01T03Z)
--   U1 3 msgs (12:00, 12:10, 13:00 → 2 sessões) + 1 de sistema · U2 1 msg (+2 no anterior, 2 sessões)
--   U3 2 msgs (12:00, 12:40 → 2 sessões) · U6 1 · U7 1 · anônima 1
--   favoritos U4 e U5 na janela · preferências U5 e U6 atualizadas na janela
-- Recortes: A = U1,U2,U7 · B = U3 · X = U1,U3,U7 · Y = U2,U4 · sem atribuição ⊇ U5,U6.

DO $guard$
BEGIN
  IF EXISTS (SELECT 1 FROM public.chat_messages WHERE created_at >= '2030-12-31' AND created_at < '2031-01-03')
     OR EXISTS (SELECT 1 FROM public.user_favorites WHERE created_at >= '2030-12-31' AND created_at < '2031-01-03') THEN
    RAISE EXCEPTION 'CCAF_FAIL agregados guard: já há dados reais na janela de teste (2031-01-01)';
  END IF;
END
$guard$;

UPDATE public.user_profiles SET city = v.city
FROM (VALUES ('ccaf0000-0000-4000-d000-000000000001', 'Recife - PE'), ('ccaf0000-0000-4000-d000-000000000002', 'recife'),
             ('ccaf0000-0000-4000-d000-000000000007', 'Natal')) v(id, city)
WHERE user_profiles.id = v.id::uuid;

INSERT INTO public.chat_messages (user_id, sender, created_at)
SELECT nullif(v.u, '')::uuid, v.s, v.t::timestamptz FROM (VALUES
  ('ccaf0000-0000-4000-d000-000000000001', 'user',   '2031-01-01T12:00:00Z'),
  ('ccaf0000-0000-4000-d000-000000000001', 'user',   '2031-01-01T12:10:00Z'),
  ('ccaf0000-0000-4000-d000-000000000001', 'user',   '2031-01-01T13:00:00Z'),
  ('ccaf0000-0000-4000-d000-000000000001', 'system', '2031-01-01T12:01:00Z'),
  ('ccaf0000-0000-4000-d000-000000000002', 'user',   '2031-01-01T12:00:00Z'),
  ('ccaf0000-0000-4000-d000-000000000002', 'user',   '2030-12-31T12:00:00Z'),
  ('ccaf0000-0000-4000-d000-000000000002', 'user',   '2030-12-31T12:45:00Z'),
  ('ccaf0000-0000-4000-d000-000000000003', 'user',   '2031-01-01T12:00:00Z'),
  ('ccaf0000-0000-4000-d000-000000000003', 'user',   '2031-01-01T12:40:00Z'),
  ('ccaf0000-0000-4000-d000-000000000006', 'user',   '2031-01-01T12:05:00Z'),
  ('ccaf0000-0000-4000-d000-000000000007', 'user',   '2031-01-01T12:20:00Z'),
  ('',                                     'user',   '2031-01-01T12:30:00Z')
) v(u, s, t);

-- Favorito precisa de um alvo (user_favorites_target_check): a oportunidade do fixture.
INSERT INTO public.user_favorites (user_id, partner_opportunities_id, created_at)
SELECT v.u::uuid, (SELECT c.v FROM ccaf_ctx c WHERE c.k = 'partner')::uuid, '2031-01-01T10:00:00Z' FROM (VALUES
  ('ccaf0000-0000-4000-d000-000000000004'), ('ccaf0000-0000-4000-d000-000000000005')) v(u);

INSERT INTO public.user_preferences (user_id, updated_at, course_interest, program_preference, location_preference) VALUES
  ('ccaf0000-0000-4000-d000-000000000005', '2031-01-01T11:00:00Z', NULL, NULL, NULL),
  ('ccaf0000-0000-4000-d000-000000000006', '2031-01-01T11:00:00Z', NULL, NULL, NULL),
  ('ccaf0000-0000-4000-d000-000000000003', '2020-01-01T00:00:00Z', ARRAY['Medicina', 'Direito', 'Medicina'], 'sisu', 'Natal - RN');

CREATE TEMP TABLE ccaf_agg_results (n serial, label text, expected text, actual text);
CREATE TEMP TABLE ccaf_agg_pass (n int);

CREATE FUNCTION pg_temp.agg_ck(label text, expected text, actual text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO ccaf_agg_results (label, expected, actual) VALUES (label, expected, actual)
$$;

-- Resumo estável das contagens de cc_stats_aggregate (sem os históricos, que
-- dependem dos dados reais do DEV).
CREATE FUNCTION pg_temp.stats(p_campaign uuid DEFAULT NULL, p_channel uuid DEFAULT NULL, p_unattr boolean DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.cc_stats_aggregate('2031-01-01T03:00:00Z', '2031-01-02T03:00:00Z', '2030-12-31T03:00:00Z', false,
    p_filter_campaign_id => p_campaign, p_filter_channel_id => p_channel, p_filter_unattributed => p_unattr)
$$;
CREATE FUNCTION pg_temp.stats_line(j jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT format('msgs=%s/%s users=%s catalog=%s prev_users=%s prev_catalog=%s power=%s/%s fav=%s/%s',
    j->>'current_messages', j->>'previous_messages', j->>'message_users', j->>'catalog_users',
    j->>'previous_message_users', j->>'previous_catalog_users', j->>'power_users', j->>'previous_power_users',
    j->>'current_favorites', j->>'previous_favorites')
$$;
CREATE FUNCTION pg_temp.activity(p_mode text, p_zoom int DEFAULT NULL, p_campaign uuid DEFAULT NULL)
RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(format('%s=%s/%s', b->>'label', b->>'mensagens', b->>'usuarios'), ',' ORDER BY o)
  FROM jsonb_array_elements(public.cc_activity_aggregate(p_mode, '2031-01-01T03:00:00Z', '2031-01-02T03:00:00Z',
    'America/Sao_Paulo', p_zoom, p_filter_campaign_id => p_campaign)) WITH ORDINALITY a(b, o)
  WHERE p_zoom IS NOT NULL OR p_mode <> 'day' OR (b->>'mensagens')::int > 0
$$;

DO $$
DECLARE
  A  constant uuid := 'ccaf0000-0000-4000-a000-00000000000a';
  B  constant uuid := 'ccaf0000-0000-4000-a000-00000000000b';
  X  constant uuid := 'ccaf0000-0000-4000-b000-00000000000e';
  Y  constant uuid := 'ccaf0000-0000-4000-b000-00000000000f';
  U1 constant text := 'ccaf0000-0000-4000-d000-000000000001';
  U2 constant text := 'ccaf0000-0000-4000-d000-000000000002';
  U3 constant text := 'ccaf0000-0000-4000-d000-000000000003';
  U7 constant text := 'ccaf0000-0000-4000-d000-000000000007';
  j jsonb;
  v_state text;
  v_fail text;
BEGIN
  -- 0. Assinatura única e ACL.
  PERFORM pg_temp.agg_ck('uma assinatura por função', '1,1,1',
    (SELECT string_agg(c::text, ',' ORDER BY f) FROM (
       SELECT f, (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = f) c
       FROM unnest(ARRAY['cc_activity_aggregate', 'cc_rankings_aggregate', 'cc_stats_aggregate']) f) s));
  PERFORM pg_temp.agg_ck('anon sem EXECUTE / authenticated e service_role com', 'f,f,f t,t,t t,t,t',
    concat_ws(' ',
      concat_ws(',', has_function_privilege('anon', 'public.cc_stats_aggregate(timestamptz,timestamptz,timestamptz,boolean,uuid,uuid,boolean)', 'EXECUTE'),
                     has_function_privilege('anon', 'public.cc_activity_aggregate(text,timestamptz,timestamptz,text,integer,uuid,uuid,boolean)', 'EXECUTE'),
                     has_function_privilege('anon', 'public.cc_rankings_aggregate(text,timestamptz,timestamptz,uuid,uuid,boolean)', 'EXECUTE')),
      concat_ws(',', has_function_privilege('authenticated', 'public.cc_stats_aggregate(timestamptz,timestamptz,timestamptz,boolean,uuid,uuid,boolean)', 'EXECUTE'),
                     has_function_privilege('authenticated', 'public.cc_activity_aggregate(text,timestamptz,timestamptz,text,integer,uuid,uuid,boolean)', 'EXECUTE'),
                     has_function_privilege('authenticated', 'public.cc_rankings_aggregate(text,timestamptz,timestamptz,uuid,uuid,boolean)', 'EXECUTE')),
      concat_ws(',', has_function_privilege('service_role', 'public.cc_stats_aggregate(timestamptz,timestamptz,timestamptz,boolean,uuid,uuid,boolean)', 'EXECUTE'),
                     has_function_privilege('service_role', 'public.cc_activity_aggregate(text,timestamptz,timestamptz,text,integer,uuid,uuid,boolean)', 'EXECUTE'),
                     has_function_privilege('service_role', 'public.cc_rankings_aggregate(text,timestamptz,timestamptz,uuid,uuid,boolean)', 'EXECUTE'))));

  -- 1. cc_stats_aggregate por recorte.
  PERFORM pg_temp.agg_ck('stats sem filtro', 'msgs=9/2 users=5 catalog=2 prev_users=1 prev_catalog=0 power=2/1 fav=2/0',
    pg_temp.stats_line(pg_temp.stats()));
  PERFORM pg_temp.agg_ck('stats unattributed=false = sem filtro', pg_temp.stats()::text, pg_temp.stats(NULL, NULL, false)::text);
  j := pg_temp.stats(A);
  PERFORM pg_temp.agg_ck('stats campanha A (inclui link arquivado)', 'msgs=5/2 users=3 catalog=0 prev_users=1 prev_catalog=0 power=1/1 fav=0/0', pg_temp.stats_line(j));
  PERFORM pg_temp.agg_ck('stats campanha A cadastros', '3', j->>'total_registered');
  PERFORM pg_temp.agg_ck('stats campanha A recorrentes', jsonb_build_array(jsonb_build_object('user_id', U1, 'user_name', 'CCAF U1', 'access_count', 2))::text,
    (j->'power_users_list')::text);
  j := pg_temp.stats(B);
  PERFORM pg_temp.agg_ck('stats campanha B (U2 é só last-touch)', 'msgs=2/0 users=1 catalog=0 prev_users=0 prev_catalog=0 power=1/0 fav=0/0', pg_temp.stats_line(j));
  PERFORM pg_temp.agg_ck('stats campanha B cadastros', '1', j->>'total_registered');
  j := pg_temp.stats(NULL, X);
  PERFORM pg_temp.agg_ck('stats divulgador X', 'msgs=6/0 users=3 catalog=0 prev_users=0 prev_catalog=0 power=2/0 fav=0/0', pg_temp.stats_line(j));
  PERFORM pg_temp.agg_ck('stats divulgador X recorrentes (desempate por id)', U1 || ',' || U3,
    (SELECT string_agg(e->>'user_id', ',' ORDER BY o) FROM jsonb_array_elements(j->'power_users_list') WITH ORDINALITY a(e, o)));
  j := pg_temp.stats(NULL, Y);
  PERFORM pg_temp.agg_ck('stats divulgador Y (favorito de U4 = catálogo)', 'msgs=1/2 users=1 catalog=1 prev_users=1 prev_catalog=0 power=0/1 fav=1/0', pg_temp.stats_line(j));
  PERFORM pg_temp.agg_ck('stats divulgador Y cadastros', '2', j->>'total_registered');
  PERFORM pg_temp.agg_ck('stats B + Y vazio', 'msgs=0/0 users=0 catalog=0 prev_users=0 prev_catalog=0 power=0/0 fav=0/0 reg=0 list=[]',
    pg_temp.stats_line(pg_temp.stats(B, Y)) || ' reg=' || (pg_temp.stats(B, Y)->>'total_registered') || ' list=' || (pg_temp.stats(B, Y)->'power_users_list')::text);
  j := pg_temp.stats(NULL, NULL, true);
  PERFORM pg_temp.agg_ck('stats sem atribuição (anônima fora; U5 catálogo; U6 mensagem)', 'msgs=1/0 users=1 catalog=1 prev_users=0 prev_catalog=0 power=0/0 fav=1/0',
    pg_temp.stats_line(j));
  PERFORM pg_temp.agg_ck('stats sem atribuição cadastros = perfis sem first-touch (matches_first_touch_attribution)',
    (SELECT count(*)::text FROM public.user_profiles p WHERE public.matches_first_touch_attribution(p.id, NULL, NULL, true)),
    j->>'total_registered');
  PERFORM pg_temp.agg_ck('stats sem filtro: cadastros ficam com a Edge (Auth)', 'null', coalesce(pg_temp.stats()->>'total_registered', 'null'));
  PERFORM pg_temp.agg_ck('stats histórico do recorte A',
    (SELECT count(*)::text FROM public.chat_messages m WHERE m.sender = 'user'
       AND public.matches_first_touch_attribution(m.user_id, A, NULL, NULL)),
    public.cc_stats_aggregate('2031-01-01T03:00:00Z', '2031-01-02T03:00:00Z', '2030-12-31T03:00:00Z', true, A)->>'history_messages');

  -- 2. cc_activity_aggregate no fuso pedido (12:00Z = 09:00 BRT).
  PERFORM pg_temp.agg_ck('activity dia A (horas com mensagem)', '09h=4/3,10h=1/1', pg_temp.activity('day', NULL, A));
  PERFORM pg_temp.agg_ck('activity zoom 9h A', '09:00=3/2,09:15=1/1,09:30=0/0,09:45=0/0', pg_temp.activity('day', 9, A));
  PERFORM pg_temp.agg_ck('activity semana A', '01/01=5/3', pg_temp.activity('week', NULL, A));
  PERFORM pg_temp.agg_ck('activity semana sem filtro (anônima conta mensagem, não usuário)', '01/01=9/5', pg_temp.activity('week'));

  -- 3. cc_rankings_aggregate.
  PERFORM pg_temp.agg_ck('ranking users A (desempate por id)', format('%s:3:2:0,%s:1:1:0,%s:1:1:0', U1, U2, U7),
    (SELECT string_agg(concat_ws(':', e->>'id', e->>'messages', e->>'sessions', e->>'favorites'), ',' ORDER BY o)
     FROM jsonb_array_elements(public.cc_rankings_aggregate('users', '2031-01-01T03:00:00Z', '2031-01-02T03:00:00Z', A)) WITH ORDINALITY a(e, o)));
  PERFORM pg_temp.agg_ck('ranking locations A (grupos crus, ordem de 1ª aparência por id)',
    '{"total": 3, "groups": [{"count": 1, "value": "Recife - PE"}, {"count": 1, "value": "recife"}, {"count": 1, "value": "Natal"}]}',
    public.cc_rankings_aggregate('locations', p_filter_campaign_id => A)::text);
  PERFORM pg_temp.agg_ck('ranking courses B (cada item do array conta)',
    '{"total": 1, "groups": [{"count": 2, "value": "Medicina"}, {"count": 1, "value": "Direito"}]}',
    public.cc_rankings_aggregate('courses', p_filter_campaign_id => B)::text);
  PERFORM pg_temp.agg_ck('ranking preferences B', '{"total": 1, "groups": [{"count": 1, "value": "sisu"}]}',
    public.cc_rankings_aggregate('preferences', p_filter_campaign_id => B)::text);
  PERFORM pg_temp.agg_ck('ranking location_preferences B + Y vazio', '{"total": 0, "groups": []}',
    public.cc_rankings_aggregate('location_preferences', p_filter_campaign_id => B, p_filter_channel_id => Y)::text);

  -- 4. Entradas inválidas → 22023; não-backoffice → 42501; service_role passa.
  BEGIN
    PERFORM pg_temp.stats(A, NULL, true);
    PERFORM pg_temp.agg_ck('22023 filtro incompatível', '22023', 'sem erro');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    PERFORM pg_temp.agg_ck('22023 filtro incompatível', '22023', v_state);
  END;
  BEGIN
    PERFORM public.cc_activity_aggregate('week', NULL, NULL, 'Mars/Olympus');
    PERFORM pg_temp.agg_ck('22023 fuso inválido', '22023', 'sem erro');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    PERFORM pg_temp.agg_ck('22023 fuso inválido', '22023', v_state);
  END;

  PERFORM set_config('request.jwt.claims', '{"sub":"ccaf0000-0000-4000-f000-0000000000ee","role":"authenticated"}', true);
  PERFORM set_config('request.jwt.claim.sub', 'ccaf0000-0000-4000-f000-0000000000ee', true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  BEGIN
    PERFORM pg_temp.stats();
    PERFORM pg_temp.agg_ck('42501 stats', '42501', 'sem erro');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    PERFORM pg_temp.agg_ck('42501 stats', '42501', v_state);
  END;
  BEGIN
    PERFORM public.cc_activity_aggregate('week', NULL, NULL);
    PERFORM pg_temp.agg_ck('42501 activity', '42501', 'sem erro');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    PERFORM pg_temp.agg_ck('42501 activity', '42501', v_state);
  END;
  BEGIN
    PERFORM public.cc_rankings_aggregate('courses');
    PERFORM pg_temp.agg_ck('42501 rankings', '42501', 'sem erro');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    PERFORM pg_temp.agg_ck('42501 rankings', '42501', v_state);
  END;
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  PERFORM pg_temp.agg_ck('service_role (Edge) passa', 'msgs=5/2', split_part(pg_temp.stats_line(pg_temp.stats(A)), ' ', 1));

  -- Volta ao admin do fixture para assert.sql.
  PERFORM set_config('request.jwt.claims', '{"sub":"ccaf0000-0000-4000-f000-0000000000ad","role":"authenticated"}', true);
  PERFORM set_config('request.jwt.claim.sub', 'ccaf0000-0000-4000-f000-0000000000ad', true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

  SELECT string_agg(format('[%s] esperado=%s obtido=%s', label, expected, coalesce(actual, 'NULL')), ' | ' ORDER BY n)
    INTO v_fail FROM ccaf_agg_results WHERE actual IS DISTINCT FROM expected;
  IF v_fail IS NOT NULL THEN
    RAISE EXCEPTION 'CCAF_FAIL agregados (%/% falharam): %',
      (SELECT count(*) FROM ccaf_agg_results WHERE actual IS DISTINCT FROM expected), (SELECT count(*) FROM ccaf_agg_results), v_fail;
  END IF;
  INSERT INTO ccaf_agg_pass SELECT count(*) FROM ccaf_agg_results;
END $$;
