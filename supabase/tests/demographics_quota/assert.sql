-- Asserções NUB-RD-92. Roda depois de fixture.sql, baseline.sql e da migration
-- 20261019170042, na mesma transação. Falha = RAISE 'NUBRD92_FAIL: …'; o
-- run_dev.sh fecha com RAISE 'NUBRD92_ALL_PASS …'. Nada persiste.

CREATE FUNCTION pg_temp.ok(cond boolean, msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF cond IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'NUBRD92_FAIL: %', msg;
  END IF;
  INSERT INTO nubrd92_log(msg) VALUES (msg);
END
$$;

CREATE FUNCTION pg_temp.eq(expected text, actual text, msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF actual IS DISTINCT FROM expected THEN
    RAISE EXCEPTION 'NUBRD92_FAIL: % — esperado [%], obtido [%]', msg, expected, actual;
  END IF;
  INSERT INTO nubrd92_log(msg) VALUES (msg);
END
$$;

CREATE FUNCTION pg_temp.demo(p_campaign uuid DEFAULT NULL, p_channel uuid DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.get_command_center_demographics(p_filter_campaign_id => p_campaign, p_filter_channel_id => p_channel)::jsonb
$$;

CREATE FUNCTION pg_temp.slices(j jsonb, dim text) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg((s->>'label') || '=' || (s->>'value'), ',' ORDER BY o), '')
  FROM jsonb_array_elements(j->dim) WITH ORDINALITY AS a(s, o)
$$;

CREATE FUNCTION pg_temp.dim_sum(j jsonb, dim text) RETURNS bigint LANGUAGE sql AS $$
  SELECT coalesce(sum((s->>'value')::bigint), 0) FROM jsonb_array_elements(j->dim) s
$$;

-- ── Estrutura: view só com append, normalização, assinatura única ───────────
DO $struct$
DECLARE
  v_cols text[];
BEGIN
  SELECT array_agg(attname::text ORDER BY attnum) INTO v_cols
    FROM pg_attribute WHERE attrelid = 'public.vw_user_demographics_resolved'::regclass AND attnum > 0 AND NOT attisdropped;
  PERFORM pg_temp.eq('profile_id,rule_version', array_to_string(v_cols[1:2], ','), 'view: colunas iniciais preservadas');
  PERFORM pg_temp.eq('income_conflict', v_cols[array_length(v_cols, 1) - 5], 'view: income_conflict continua antes das novas');
  PERFORM pg_temp.eq('race_quota_label,school_type_quota_label,quota_source_date,school_type_quota_conflict,quota_has_unmapped',
    array_to_string(v_cols[array_length(v_cols, 1) - 4:], ','), 'view: 5 colunas de cota acrescentadas ao final');
  PERFORM pg_temp.eq('tp1c-2026-10-15.v1+nub-rd-92',
    (SELECT string_agg(DISTINCT rule_version, ',') FROM public.vw_user_demographics_resolved), 'view: rule_version única e nova');
  PERFORM pg_temp.ok((SELECT reloptions @> ARRAY['security_invoker=true'] FROM pg_class WHERE oid = 'public.vw_user_demographics_resolved'::regclass),
    'view: security_invoker mantido');

  PERFORM pg_temp.eq('escola_publica|pretos_e_pardos|pretos_e_pardos|indigenas|bolsa_integral|100%||',
    concat_ws('|', public.normalize_quota_token('  Escola Pública '), public.normalize_quota_token('PRETOS E PARDOS'),
      public.normalize_quota_token('Pretos-e-Pardos'), public.normalize_quota_token('INDÍGENAS'),
      public.normalize_quota_token('bolsa integral'), public.normalize_quota_token('100%'),
      coalesce(public.normalize_quota_token('   '), ''), coalesce(public.normalize_quota_token(NULL), '')),
    'normalize_quota_token: caixa, acento, espaço, hífen; vazio → NULL');
  PERFORM pg_temp.eq('i', (SELECT provolatile::text FROM pg_proc WHERE oid = 'public.normalize_quota_token(text)'::regprocedure),
    'normalize_quota_token IMMUTABLE');

  PERFORM pg_temp.eq('1', (SELECT count(*)::text FROM pg_proc WHERE proname = 'get_command_center_demographics' AND pronamespace = 'public'::regnamespace),
    'RPC: uma assinatura, sem overload');
  PERFORM pg_temp.ok((SELECT prosecdef AND proconfig @> ARRAY['search_path=public'] AND pg_get_function_result(oid) = 'json'
                        FROM pg_proc WHERE oid = 'public.get_command_center_demographics(uuid,uuid,boolean)'::regprocedure),
    'RPC: (uuid,uuid,boolean) → json, SECURITY DEFINER, search_path=public');
END
$struct$;

-- ── View: inferência por perfil ─────────────────────────────────────────────
DO $view$
DECLARE
  v text;
BEGIN
  SELECT string_agg(format('%s:%s/%s/%s/%s', right(profile_id::text, 2),
           coalesce(race_quota_label, '-'), coalesce(school_type_quota_label, '-'),
           school_type_quota_conflict, quota_has_unmapped), ' ' ORDER BY profile_id) INTO v
    FROM public.vw_user_demographics_resolved WHERE profile_id::text LIKE '9b920000-%';
  PERFORM pg_temp.eq(
    '01:PPI (por cota)/-/f/f 02:-/-/f/f 03:-/-/f/f '
    || '04:Indígena (por cota)/-/f/f 05:Pretos e pardos (por cota)/-/f/f '
    || '06:-/Escola pública (por cota)/f/f 07:-/Escola pública (por cota)/f/f '
    || '08:-/Privada com bolsa integral (por cota)/f/f 09:-/Privada com bolsa integral (por cota)/f/f '
    || '0a:-/-/t/f 0b:-/-/f/t 0c:-/-/f/f 0d:-/-/f/f '
    || '0e:Indígena (por cota)/-/f/f 0f:-/-/f/f 11:-/-/f/f 12:Pretos e pardos (por cota)/-/f/f',
    v, 'view: grafias D4, exclusões, N3, autodeclaração/recusa vencem, conflito de escola');

  PERFORM pg_temp.ok((SELECT race = 'Prefiro não informar' AND race_declined AND race_quota_label IS NULL
                        FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(3)), 'view: recusa bloqueia a inferência');
  PERFORM pg_temp.ok((SELECT race IS NULL AND school_type IS NULL AND race_source IS NULL
                        FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(1)), 'view: race/school_type intocados pela cota');
  PERFORM pg_temp.ok((SELECT v.quota_source_date = p.updated_at
                        FROM public.vw_user_demographics_resolved v JOIN public.user_preferences p ON p.user_id = v.profile_id
                       WHERE v.profile_id = pg_temp.pid(1)), 'view: quota_source_date = user_preferences.updated_at');
  PERFORM pg_temp.ok((SELECT quota_source_date IS NULL FROM public.vw_user_demographics_resolved WHERE profile_id = pg_temp.pid(11)),
    'view: sem inferência, sem quota_source_date');
END
$view$;

-- ── RPC sobre a seed (campanha Q isola dos dados reais) ─────────────────────
DO $rpc$
DECLARE
  Q constant uuid := '9b920000-0000-4000-a000-00000000000a';
  Y constant uuid := '9b920000-0000-4000-b000-00000000000f';
  E constant uuid := '9b920000-0000-4000-a000-00000000000e';
  j jsonb := pg_temp.demo(Q);
  dim text;
BEGIN
  PERFORM pg_temp.eq('17', j->'match_health'->>'total', 'seed: 17 perfis na campanha Q');
  PERFORM pg_temp.eq('Parda=1,Prefiro não informar=1,Preta=1,Indígena (por cota)=2,Pretos e pardos (por cota)=2,PPI (por cota)=1,Não respondeu=9',
    pg_temp.slices(j, 'race'), 'race: itens (por cota) próprios, nunca somados a autodeclarados');
  PERFORM pg_temp.eq('Escola particular sem bolsa=1,Escola pública (por cota)=2,Privada com bolsa integral (por cota)=2,Não respondeu=12',
    pg_temp.slices(j, 'school_type'), 'school_type: grafias normalizadas e conflito fora');
  PERFORM pg_temp.eq('self_declared,self_declared,self_declared,quota_inferred,quota_inferred,quota_inferred,unanswered',
    (SELECT string_agg(s->>'source', ',' ORDER BY o) FROM jsonb_array_elements(j->'race') WITH ORDINALITY a(s, o)), 'race: source por item');
  FOREACH dim IN ARRAY ARRAY['education', 'income', 'race', 'school_type'] LOOP
    PERFORM pg_temp.eq('17', pg_temp.dim_sum(j, dim)::text, format('%s: soma = total', dim));
  END LOOP;

  PERFORM pg_temp.eq('{"profile": 3, "unanswered": 14, "conflicts": 0, "declined": 1, "partner_form": 0, "quota_inferred": 5, "quota_unmapped": 1}'::jsonb::text,
    (j->'provenance'->'race')::text, 'provenance.race com quota_inferred/quota_unmapped');
  PERFORM pg_temp.eq('{"profile": 1, "conflicts": 0, "unanswered": 16, "partner_form": 0, "quota_conflict": 1, "quota_inferred": 4, "quota_unmapped": 1}'::jsonb::text,
    (j->'provenance'->'school_type')::text, 'provenance.school_type com quota_inferred/quota_unmapped/quota_conflict');

  PERFORM pg_temp.eq('{"declined": 1, "uncovered": 10, "covered_pct": 41.2, "total_users": 17, "self_declared": 2, "uncovered_pct": 58.8, "quota_inferred": 5, "self_declared_pct": 11.8, "quota_inferred_pct": 29.4}'::jsonb::text,
    (j->'coverage'->'race')::text, 'coverage.race: perfil único, recusa em uncovered e declined à parte');
  PERFORM pg_temp.eq('{"uncovered": 12, "covered_pct": 29.4, "total_users": 17, "self_declared": 1, "uncovered_pct": 70.6, "quota_inferred": 4, "self_declared_pct": 5.9, "quota_inferred_pct": 23.5}'::jsonb::text,
    (j->'coverage'->'school_type')::text, 'coverage.school_type');
  FOREACH dim IN ARRAY ARRAY['race', 'school_type'] LOOP
    PERFORM pg_temp.ok((j->'coverage'->dim->>'self_declared')::int + (j->'coverage'->dim->>'quota_inferred')::int
                       + (j->'coverage'->dim->>'uncovered')::int = (j->'coverage'->dim->>'total_users')::int,
      format('coverage.%s: self + quota + uncovered = total_users (100%%)', dim));
  END LOOP;

  -- Recorte first-touch também nas linhas inferidas.
  j := pg_temp.demo(Q, Y);
  PERFORM pg_temp.eq('2|PPI (por cota)=1,Não respondeu=1|Escola pública (por cota)=1,Não respondeu=1|1|1',
    concat_ws('|', j->'match_health'->>'total', pg_temp.slices(j, 'race'), pg_temp.slices(j, 'school_type'),
      j->'coverage'->'race'->>'quota_inferred', j->'coverage'->'school_type'->>'quota_inferred'),
    'first-touch (Q + Y) aplicado às linhas inferidas por cota');

  j := pg_temp.demo(E);
  PERFORM pg_temp.eq('0|null|null|null', concat_ws('|', j->'coverage'->'race'->>'total_users',
      coalesce(j->'coverage'->'race'->>'covered_pct', 'null'), coalesce(j->'coverage'->'race'->>'self_declared_pct', 'null'),
      coalesce(j->'coverage'->'school_type'->>'covered_pct', 'null')),
    'total_users = 0 → percentuais NULL');
END
$rpc$;

-- ── Shape antigo preservado (dados reais do DEV + seed, sem filtro) ─────────
DO $compat$
DECLARE
  o jsonb;
  n jsonb := pg_temp.demo();
  scope text;
  dim text;
  v_old_unanswered bigint;
BEGIN
  FOREACH scope IN ARRAY ARRAY['all', 'q'] LOOP
    o := (SELECT j FROM nubrd92_snap WHERE k = 'old_' || scope);
    IF scope = 'q' THEN n := pg_temp.demo('9b920000-0000-4000-a000-00000000000a'); END IF;

    PERFORM pg_temp.ok(n ?& ARRAY(SELECT jsonb_object_keys(o)), format('[%s] chaves de topo antigas presentes', scope));
    PERFORM pg_temp.ok(n->'match_health' = o->'match_health' AND n->'education' = o->'education' AND n->'income' = o->'income',
      format('[%s] match_health, education e income idênticos', scope));
    PERFORM pg_temp.ok(n->'provenance'->'education' = o->'provenance'->'education'
                   AND n->'provenance'->'income' = o->'provenance'->'income'
                   AND (n->'provenance'->'race') - 'quota_inferred' - 'quota_unmapped' = o->'provenance'->'race'
                   AND (n->'provenance'->'school_type') - 'quota_inferred' - 'quota_unmapped' - 'quota_conflict' = o->'provenance'->'school_type',
      format('[%s] provenance antiga intacta (só chaves novas)', scope));

    FOREACH dim IN ARRAY ARRAY['race', 'school_type'] LOOP
      PERFORM pg_temp.ok(
        (SELECT coalesce(jsonb_agg(jsonb_build_object('label', s->>'label', 'value', (s->>'value')::bigint) ORDER BY s->>'label'), '[]')
           FROM jsonb_array_elements(n->dim) s WHERE s->>'source' = 'self_declared')
        = (SELECT coalesce(jsonb_agg(s ORDER BY s->>'label'), '[]') FROM jsonb_array_elements(o->dim) s WHERE s->>'label' <> 'Não respondeu'),
        format('[%s] %s: itens autodeclarados idênticos aos de antes', scope, dim));
      SELECT coalesce(sum((s->>'value')::bigint), 0) INTO v_old_unanswered
        FROM jsonb_array_elements(o->dim) s WHERE s->>'label' = 'Não respondeu';
      PERFORM pg_temp.ok(v_old_unanswered = (SELECT coalesce(sum((s->>'value')::bigint), 0) FROM jsonb_array_elements(n->dim) s
                                              WHERE s->>'source' IN ('quota_inferred', 'unanswered')),
        format('[%s] %s: Não respondeu antigo = por cota + Não respondeu novo', scope, dim));
      PERFORM pg_temp.ok((n->'coverage'->dim->>'self_declared')::int + (n->'coverage'->dim->>'quota_inferred')::int
                         + (n->'coverage'->dim->>'uncovered')::int = (n->'match_health'->>'total')::int,
        format('[%s] %s: cobertura soma o total', scope, dim));
    END LOOP;
  END LOOP;
END
$compat$;

-- ── ACL: admin lê, não-admin/anon 42501, view e normalização fechadas ───────
DO $acl$
DECLARE
  v_state text;
BEGIN
  PERFORM pg_temp.ok(NOT has_function_privilege('anon', 'public.get_command_center_demographics(uuid,uuid,boolean)', 'EXECUTE')
                 AND has_function_privilege('authenticated', 'public.get_command_center_demographics(uuid,uuid,boolean)', 'EXECUTE'),
    'RPC: EXECUTE só para authenticated (anon sem)');
  PERFORM pg_temp.ok(NOT has_table_privilege('anon', 'public.vw_user_demographics_resolved', 'SELECT')
                 AND NOT has_table_privilege('authenticated', 'public.vw_user_demographics_resolved', 'SELECT')
                 AND NOT has_table_privilege('service_role', 'public.vw_user_demographics_resolved', 'SELECT'),
    'view: sem grant para anon/authenticated/service_role');
  PERFORM pg_temp.ok(NOT has_function_privilege('anon', 'public.normalize_quota_token(text)', 'EXECUTE')
                 AND NOT has_function_privilege('authenticated', 'public.normalize_quota_token(text)', 'EXECUTE'),
    'normalize_quota_token: sem EXECUTE para anon/authenticated');

  SET LOCAL ROLE authenticated;
  v_state := (pg_temp.demo() ? 'coverage')::text;
  RESET ROLE;
  PERFORM pg_temp.eq('true', v_state, 'admin autenticado lê a RPC (com coverage)');

  BEGIN
    PERFORM set_config('request.jwt.claim.sub', pg_temp.pid(1)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', pg_temp.pid(1), 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM pg_temp.demo();
    v_state := 'sem erro';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  RESET ROLE;
  PERFORM pg_temp.eq('42501', v_state, 'authenticated não-admin → 42501 na RPC');

  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM 1 FROM public.vw_user_demographics_resolved LIMIT 1;
    v_state := 'sem erro';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  RESET ROLE;
  PERFORM pg_temp.eq('42501', v_state, 'authenticated → 42501 lendo a view direto');

  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.normalize_quota_token('ppi');
    v_state := 'sem erro';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  RESET ROLE;
  PERFORM pg_temp.eq('42501', v_state, 'anon → 42501 em normalize_quota_token');

  PERFORM set_config('request.jwt.claim.sub', '9b920000-0000-4000-f000-0000000000ad', true);
  PERFORM set_config('request.jwt.claims', '{"sub":"9b920000-0000-4000-f000-0000000000ad","role":"authenticated"}', true);
END
$acl$;

-- ── Sem escrita em perfis/preferências/atribuição ───────────────────────────
DO $nomut$
BEGIN
  PERFORM pg_temp.demo();
  PERFORM count(*) FROM public.vw_user_demographics_resolved;
  PERFORM pg_temp.eq((SELECT j #>> '{}' FROM nubrd92_snap WHERE k = 'fp'), pg_temp.fingerprint(),
    'user_profiles, user_preferences e user_attribution idênticos após migration + leituras');
END
$nomut$;
