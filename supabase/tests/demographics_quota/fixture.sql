-- Seed da suíte NUB-RD-92 (demografia inferida por cota). Roda DENTRO da
-- transação montada por run_dev.sh e nunca é commitada. UUIDs 9b92…, e-mails
-- nub-rd-92-N@qa-s9.invalid. Mesmos perfis de src/test/demographics-quota-sql.test.ts.
--
--   Q  campanha da suíte: todo perfil da seed tem first-touch nela, então
--      get_command_center_demographics(p_filter_campaign_id => Q) isola a seed
--      dos dados reais do DEV.
--   LQX (Q, X) → todos, menos 1 e 6     LQY (Q, Y) → perfis 1 e 6
--   E  campanha sem ninguém (total_users = 0)
--
--   n  autodeclaração                 quota_types
--   1  —                              PPI
--   2  raça Preta                     PPI
--   3  raça "Prefiro não informar"    PPI
--   4  —                              PPI, PRETOS E PARDOS, INDIGENAS
--   5  —                              ppi, PRETOS E PARDOS
--   6  —                              ESCOLA_PUBLICA
--   7  —                              escola pública
--   8  —                              ESCOLA_PRIVADA_BOLSA_INTEGRAL
--   9  —                              bolsa integral
--  10  —                              ESCOLA_PUBLICA, ESCOLA_PRIVADA_BOLSA_INTEGRAL
--  11  —                              QUILOMBOLAS, QUILOMBOLA, ppiq, BAIXA_RENDA,
--                                     AMPLA_CONCORRENCIA, PCD, PDC, 100%
--  12  escola particular sem bolsa    ESCOLA_PUBLICA
--  13  raça Parda                     (sem preferências)
--  14  —                              Indígena
--  15  —                              (sem preferências)
--  17  —                              {} (vazio)
--  18  —                              '  Pretos-e-Pardos ', NULL, ''

DO $guard$
BEGIN
  IF (SELECT count(*) FROM cron.job) <> 1 THEN
    RAISE EXCEPTION 'NUBRD92_ABORT: alvo não é o DEV (cron.job <> 1)';
  END IF;
  IF (SELECT count(*) FROM public.user_profiles) > 1000 THEN
    RAISE EXCEPTION 'NUBRD92_ABORT: alvo parece PROD (>1000 perfis)';
  END IF;
  IF EXISTS (SELECT 1 FROM auth.users WHERE email LIKE 'nub-rd-92-%@qa-s9.invalid') THEN
    RAISE EXCEPTION 'NUBRD92_ABORT: seed nub-rd-92 já existe no DEV (resíduo persistido?)';
  END IF;
END
$guard$;

CREATE TEMP TABLE nubrd92_log (n serial, msg text) ON COMMIT DROP;
CREATE TEMP TABLE nubrd92_snap (k text PRIMARY KEY, j jsonb) ON COMMIT DROP;

CREATE FUNCTION pg_temp.pid(n int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('9b920000-0000-4000-8000-' || lpad(to_hex(n), 12, '0'))::uuid
$$;

INSERT INTO public.campaigns (id, slug, name) VALUES
  ('9b920000-0000-4000-a000-00000000000a', 'nub-rd-92-q', 'NUB-RD-92 Campanha Q'),
  ('9b920000-0000-4000-a000-00000000000e', 'nub-rd-92-e', 'NUB-RD-92 Campanha vazia');
INSERT INTO public.channels (id, slug, name, type) VALUES
  ('9b920000-0000-4000-b000-00000000000e', 'nub-rd-92-x', 'NUB-RD-92 Divulgador X', 'crm'),
  ('9b920000-0000-4000-b000-00000000000f', 'nub-rd-92-y', 'NUB-RD-92 Divulgador Y', 'influencer');
INSERT INTO public.channel_links (id, campaign_id, channel_id, code) VALUES
  ('9b920000-0000-4000-c000-000000000001', '9b920000-0000-4000-a000-00000000000a', '9b920000-0000-4000-b000-00000000000e', 'nub-rd-92-lqx'),
  ('9b920000-0000-4000-c000-000000000002', '9b920000-0000-4000-a000-00000000000a', '9b920000-0000-4000-b000-00000000000f', 'nub-rd-92-lqy'),
  ('9b920000-0000-4000-c000-000000000003', '9b920000-0000-4000-a000-00000000000e', '9b920000-0000-4000-b000-00000000000e', 'nub-rd-92-le');

INSERT INTO auth.users (id, email, is_anonymous)
SELECT pg_temp.pid(n), format('nub-rd-92-%s@qa-s9.invalid', n), true
  FROM generate_series(1, 18) n WHERE n <> 16;

INSERT INTO public.user_profiles (id, full_name, race, school_type)
SELECT pg_temp.pid(n), format('NUB-RD-92 %s', n),
       CASE n WHEN 2 THEN 'Preta' WHEN 3 THEN 'Prefiro não informar' WHEN 13 THEN 'Parda' END,
       CASE n WHEN 12 THEN 'Escola particular sem bolsa' END
  FROM generate_series(1, 18) n WHERE n <> 16;

INSERT INTO public.user_preferences (user_id, quota_types, updated_at) VALUES
  (pg_temp.pid(1),  ARRAY['PPI'], '2026-10-02T10:00:00Z'),
  (pg_temp.pid(2),  ARRAY['PPI'], DEFAULT),
  (pg_temp.pid(3),  ARRAY['PPI'], DEFAULT),
  (pg_temp.pid(4),  ARRAY['PPI','PRETOS E PARDOS','INDIGENAS'], DEFAULT),
  (pg_temp.pid(5),  ARRAY['ppi','PRETOS E PARDOS'], DEFAULT),
  (pg_temp.pid(6),  ARRAY['ESCOLA_PUBLICA'], DEFAULT),
  (pg_temp.pid(7),  ARRAY['escola pública'], DEFAULT),
  (pg_temp.pid(8),  ARRAY['ESCOLA_PRIVADA_BOLSA_INTEGRAL'], DEFAULT),
  (pg_temp.pid(9),  ARRAY['bolsa integral'], DEFAULT),
  (pg_temp.pid(10), ARRAY['ESCOLA_PUBLICA','ESCOLA_PRIVADA_BOLSA_INTEGRAL'], DEFAULT),
  (pg_temp.pid(11), ARRAY['QUILOMBOLAS','QUILOMBOLA','ppiq','BAIXA_RENDA','AMPLA_CONCORRENCIA','PCD','PDC','100%'], DEFAULT),
  (pg_temp.pid(12), ARRAY['ESCOLA_PUBLICA'], DEFAULT),
  (pg_temp.pid(14), ARRAY['Indígena'], DEFAULT),
  (pg_temp.pid(17), ARRAY[]::text[], DEFAULT),
  (pg_temp.pid(18), ARRAY['  Pretos-e-Pardos ', NULL, ''], DEFAULT);

INSERT INTO public.user_attribution (user_id, first_touch_link_id, last_touch_link_id, first_touch_at, last_touch_at)
SELECT pg_temp.pid(n),
       CASE WHEN n IN (1, 6) THEN '9b920000-0000-4000-c000-000000000002'::uuid ELSE '9b920000-0000-4000-c000-000000000001'::uuid END,
       CASE WHEN n IN (1, 6) THEN '9b920000-0000-4000-c000-000000000002'::uuid ELSE '9b920000-0000-4000-c000-000000000001'::uuid END,
       now(), now()
  FROM generate_series(1, 18) n WHERE n <> 16;

-- Admin de teste para o guard is_backoffice_admin() (auth.uid() lê o JWT).
INSERT INTO auth.users (id, email, is_anonymous) VALUES
  ('9b920000-0000-4000-f000-0000000000ad', 'nub-rd-92-admin@qa-s9.invalid', false);
INSERT INTO public.user_permissions (user_id, permission) VALUES
  ('9b920000-0000-4000-f000-0000000000ad', 'Controle de usuários');

SELECT set_config('request.jwt.claims', '{"sub":"9b920000-0000-4000-f000-0000000000ad","role":"authenticated"}', true);
SELECT set_config('request.jwt.claim.sub', '9b920000-0000-4000-f000-0000000000ad', true);
