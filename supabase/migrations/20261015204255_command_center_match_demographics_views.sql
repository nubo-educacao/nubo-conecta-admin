-- Complemento TP-1 — card f245da71 / plano 29c645bd rev3 (decisões D1–D6).
--
-- O Command Center contava "com Match" só por user_opportunity_matches (motor
-- v1) e lia demografia só do perfil atual. Esta migration corrige o READ PATH,
-- sem backfill (D4): duas views resolvem evidências e proveniência, e a RPC
-- passa a ler delas. Nenhuma tabela-fonte é escrita.
--
--   vw_user_match_evidence         uma linha por user_profiles.id; v0 ∪ v1.
--   vw_user_demographics_resolved  uma linha por user_profiles.id; valor por
--                                  campo com source/status/data/conflito.
--
-- Regras que não podem regredir:
--   * "Concluiu Match" = resultado v0 (last_course_ids não vazio) OU resultado
--     v1, incluindo elegibilidade de parceiro sem tentativa registrada (D1, D2).
--   * v0 não tem data de Match. As datas de chat_messages são de INTERAÇÃO e
--     levam esse nome; nunca viram generated_at/last_match_at.
--   * IDs v0 não resolvem no catálogo atual: são evidência, não resultado.
--   * Perfil atual válido vence formulário. Entre formulários vence o mais
--     recente (updated_at, created_at, id) — nunca MAX lexical.
--   * Respostas DRAFT/redirected valem como declaração (D6); o status vai na
--     proveniência.
--   * Renda em salários mínimos fica como faixa declarada; não é convertida em
--     reais (D3). Renda exata sempre vence a faixa.
--   * quota_types, eligibility_results e texto de chat NÃO são fonte de raça,
--     renda ou tipo de escola.
--   * "Prefiro não informar" é resposta, não lacuna.
--   * Normalização de rótulo de escolaridade só na view (D5).
--
-- ⚠️ As views expõem dado pessoal sensível (raça, renda) por linha. Nascem com
-- security_invoker e sem grant para nenhum papel de API; o único caminho de
-- leitura é a RPC SECURITY DEFINER com is_backoffice_admin(), que devolve só
-- agregados.
--
-- Reversão: reaplicar 20260811160000_command_center_health_demographics.sql e
-- rodar supabase/tests/command-center-match-demographics/rollback_drop_views.sql.

-- ── Evidências de Match ─────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.vw_user_match_evidence
WITH (security_invoker = true) AS
WITH v0_chat AS (
  -- Mesma regra do admin legado: "Match iniciado" = conversa no match_workflow.
  SELECT cm.user_id,
         min(cm.created_at) AS first_at,
         max(cm.created_at) AS last_at
    FROM public.chat_messages cm
   WHERE cm.workflow = 'match_workflow'
     AND cm.user_id IS NOT NULL
   GROUP BY cm.user_id
),
v1_results AS (
  -- user_opportunity_matches mistura dois produtores: motor MEC (mec_*) e
  -- elegibilidade de parceiro (partner_*). Os dois contam (D2), mas seguem
  -- distinguíveis.
  SELECT m.profile_id,
         bool_or(m.unified_opportunity_id LIKE 'mec\_%')     AS has_mec,
         bool_or(m.unified_opportunity_id LIKE 'partner\_%') AS has_partner,
         max(m.generated_at)                                 AS last_generated_at
    FROM public.user_opportunity_matches m
   GROUP BY m.profile_id
),
flags AS (
  SELECT
    p.id                                                    AS profile_id,
    (p.parent_user_id IS NOT NULL)                          AS is_dependent,
    (c.user_id IS NOT NULL)                                 AS v0_attempt,
    -- CASE e não AND: jsonb_array_length em não-array lança erro, e AND não
    -- garante ordem de avaliação.
    CASE WHEN jsonb_typeof(pref.workflow_data -> 'last_course_ids') = 'array'
         THEN jsonb_array_length(pref.workflow_data -> 'last_course_ids') > 0
         ELSE false
    END                                                     AS v0_result,
    c.first_at                                              AS v0_first_interaction_at,
    c.last_at                                               AS v0_last_interaction_at,
    coalesce(pref.last_match_at IS NOT NULL
             OR pref.match_status IN ('ready', 'error'), false) AS v1_attempt,
    pref.match_status                                       AS v1_last_status,
    pref.last_match_at                                      AS v1_last_match_at,
    (r.profile_id IS NOT NULL)                              AS v1_has_result,
    coalesce(r.has_mec, false)                              AS v1_has_mec_result,
    coalesce(r.has_partner, false)                          AS v1_has_partner_result,
    coalesce(r.has_partner AND NOT r.has_mec, false)        AS v1_partner_only,
    r.last_generated_at                                     AS v1_last_result_at
  FROM public.user_profiles p
  -- user_preferences.user_id é UNIQUE: o join não multiplica perfis.
  LEFT JOIN public.user_preferences pref ON pref.user_id = p.id
  LEFT JOIN v0_chat c ON c.user_id = p.id
  LEFT JOIN v1_results r ON r.profile_id = p.id
)
SELECT
  f.profile_id,
  f.is_dependent,
  f.v0_attempt,
  f.v0_result,
  f.v0_first_interaction_at,
  f.v0_last_interaction_at,
  f.v1_attempt,
  f.v1_last_status,
  f.v1_last_match_at,
  f.v1_has_result,
  f.v1_has_mec_result,
  f.v1_partner_only,
  f.v1_last_result_at,
  CASE
    WHEN f.v0_result OR f.v1_has_result THEN 'concluded'
    WHEN f.v0_attempt OR f.v1_attempt   THEN 'attempted_no_result'
    ELSE 'never'
  END AS bucket,
  array_remove(ARRAY[
    CASE WHEN f.v0_attempt            THEN 'v0_chat_interaction' END,
    CASE WHEN f.v0_result             THEN 'v0_result' END,
    CASE WHEN f.v1_attempt            THEN 'v1_attempt' END,
    CASE WHEN f.v1_has_mec_result     THEN 'v1_mec_result' END,
    CASE WHEN f.v1_has_partner_result THEN 'v1_partner_result' END
  ], NULL)::text[] AS evidence_sources
FROM flags f;

COMMENT ON VIEW public.vw_user_match_evidence IS
'Uma linha por user_profiles.id com evidências de Match v0 (chat match_workflow = tentativa; workflow_data.last_course_ids = resultado) e v1 (user_preferences = tentativa; user_opportunity_matches = resultado atual, MEC ou parceiro). bucket ∈ {concluded, attempted_no_result, never}. Datas v0 são de interação, não de resultado. Sem grant para API; ler via get_command_center_demographics(). Card f245da71.';

-- ── Demografia resolvida ────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.vw_user_demographics_resolved
WITH (security_invoker = true) AS
WITH form_fields AS (
  -- Só perguntas cuja semântica é a do campo do perfil. school_type não tem
  -- mapping_source nos formulários atuais; a pergunta é inequívoca.
  SELECT f.id AS form_id,
         f.partner_id,
         f.field_name,
         CASE
           WHEN f.mapping_source = 'user_profiles.education'       THEN 'education'
           WHEN f.mapping_source = 'user_profiles.race'            THEN 'race'
           WHEN f.mapping_source = 'user_profiles.school_type'     THEN 'school_type'
           WHEN f.mapping_source IS NULL
            AND f.question_text ~* 'tipo de escola'                THEN 'school_type'
           WHEN f.mapping_source = 'user_income.per_capita_income' THEN 'income'
         END AS field
    FROM public.partner_forms f
),
raw_answers AS (
  -- answers é chaveado por field_name ou por partner_forms.id, e a chave só
  -- vale dentro do partner_id da própria candidatura.
  SELECT s.id         AS application_id,
         s.user_id,
         s.status,
         s.created_at,
         s.updated_at,
         ff.form_id,
         ff.field,
         CASE jsonb_typeof(e.value)
           WHEN 'string' THEN btrim(e.value #>> '{}')
           WHEN 'object' THEN e.value::text
         END AS raw
    FROM public.student_applications s
   CROSS JOIN LATERAL jsonb_each(
           CASE WHEN jsonb_typeof(s.answers) = 'object' THEN s.answers ELSE '{}'::jsonb END
         ) AS e(key, value)
    JOIN form_fields ff
      ON ff.partner_id = s.partner_id
     AND (ff.field_name = e.key OR ff.form_id::text = e.key)
   WHERE ff.field IS NOT NULL
),
parsed AS (
  -- A calculadora de renda grava um JSON serializado como texto. Só é lido se
  -- for JSON válido; texto inválido vira NULL em vez de derrubar a view.
  SELECT a.*,
         CASE WHEN a.field = 'income' AND a.raw LIKE '{%' AND pg_input_is_valid(a.raw, 'jsonb')
              THEN a.raw::jsonb
         END AS j
    FROM raw_answers a
),
candidates AS (
  SELECT p.application_id, p.user_id, p.status, p.created_at, p.updated_at, p.form_id,
         c.kind, c.value_text, c.value_num
    FROM parsed p
   CROSS JOIN LATERAL (
     -- CASE aninhado: o cast só roda quando o JSON garante um número.
     SELECT CASE WHEN jsonb_typeof(p.j -> 'per_capita_income') = 'number'
                 THEN (p.j ->> 'per_capita_income')::numeric
            END AS brl,
            coalesce(p.field = 'income'
                     AND p.raw ~* '^(até|de|mais que|mais de|acima de)\s+[0-9]+([.,][0-9]+)?(\s+a\s+[0-9]+([.,][0-9]+)?)?\s+sal[áa]rios?\s+m[íi]nimos?$',
                     false) AS is_band
   ) n
   CROSS JOIN LATERAL (
     SELECT
       CASE
         WHEN p.field <> 'income'          THEN p.field
         WHEN n.brl >= 0                   THEN 'income_brl'
         WHEN n.brl IS NULL AND n.is_band  THEN 'income_band_sm'
       END AS kind,
       CASE p.field
         WHEN 'education' THEN
           CASE
             WHEN p.raw = 'Pós-Gradução'        THEN 'Pós-Graduação'
             WHEN p.raw = 'Superior Incompleto' THEN 'Ensino Superior Incompleto'
             WHEN p.raw IN ('Ensino Fundamental', 'Ensino Médio Incompleto', 'Ensino Médio Completo',
                            'Ensino Superior Incompleto', 'Ensino Superior Completo', 'Pós-Graduação')
                                                THEN p.raw
           END
         WHEN 'race' THEN
           CASE WHEN p.raw IN ('Amarela', 'Branca', 'Indígena', 'Parda', 'Preta', 'Outra', 'Prefiro não informar')
                THEN p.raw END
         WHEN 'school_type' THEN
           CASE WHEN p.raw IN ('Escola pública', 'Escola particular com bolsa 100%',
                               'Escola particular com bolsa parcial', 'Escola particular sem bolsa')
                THEN p.raw END
         WHEN 'income' THEN
           CASE WHEN n.brl IS NULL AND n.is_band THEN p.raw END
       END AS value_text,
       CASE WHEN n.brl >= 0 THEN n.brl END AS value_num
   ) c
   WHERE c.kind IS NOT NULL
     AND (c.value_text IS NOT NULL OR c.value_num IS NOT NULL)
),
ranked AS (
  SELECT c.*,
         row_number() OVER (PARTITION BY c.user_id, c.kind
                            ORDER BY c.updated_at DESC, c.created_at DESC, c.application_id DESC, c.form_id DESC) AS rn
    FROM candidates c
),
divergence AS (
  SELECT user_id, kind,
         count(DISTINCT coalesce(value_text, round(value_num, 2)::text)) AS n_values
    FROM candidates
   GROUP BY user_id, kind
),
form_best AS (
  SELECT r.user_id, r.kind, r.value_text, r.value_num, r.status, r.updated_at, d.n_values
    FROM ranked r
    JOIN divergence d ON d.user_id = r.user_id AND d.kind = r.kind
   WHERE r.rn = 1
),
profile_values AS (
  SELECT p.id,
         CASE nullif(btrim(coalesce(p.education, '')), '')
           WHEN 'Pós-Gradução'        THEN 'Pós-Graduação'
           WHEN 'Superior Incompleto' THEN 'Ensino Superior Incompleto'
           ELSE nullif(btrim(coalesce(p.education, '')), '')
         END                                             AS education,
         nullif(btrim(coalesce(p.race, '')), '')         AS race,
         nullif(btrim(coalesce(p.school_type, '')), '')  AS school_type,
         inc.per_capita_income                           AS income_profile,
         pref.family_income_per_capita                   AS income_onboarding
    FROM public.user_profiles p
    -- user_income.user_id e user_preferences.user_id são UNIQUE.
    LEFT JOIN public.user_income inc ON inc.user_id = p.id
    LEFT JOIN public.user_preferences pref ON pref.user_id = p.id
),
resolved AS (
  SELECT pv.*,
         fe.value_text AS f_edu,    fe.status AS f_edu_status,    fe.updated_at AS f_edu_date,    fe.n_values AS f_edu_n,
         fr.value_text AS f_race,   fr.status AS f_race_status,   fr.updated_at AS f_race_date,   fr.n_values AS f_race_n,
         fs.value_text AS f_school, fs.status AS f_school_status, fs.updated_at AS f_school_date, fs.n_values AS f_school_n,
         fb.value_num  AS f_brl,    fb.status AS f_brl_status,    fb.updated_at AS f_brl_date,    fb.n_values AS f_brl_n,
         fm.value_text AS f_band,   fm.status AS f_band_status,   fm.updated_at AS f_band_date,   fm.n_values AS f_band_n,
         coalesce(pv.income_profile, pv.income_onboarding) AS income_declared
    FROM profile_values pv
    LEFT JOIN form_best fe ON fe.user_id = pv.id AND fe.kind = 'education'
    LEFT JOIN form_best fr ON fr.user_id = pv.id AND fr.kind = 'race'
    LEFT JOIN form_best fs ON fs.user_id = pv.id AND fs.kind = 'school_type'
    LEFT JOIN form_best fb ON fb.user_id = pv.id AND fb.kind = 'income_brl'
    LEFT JOIN form_best fm ON fm.user_id = pv.id AND fm.kind = 'income_band_sm'
)
SELECT
  r.id                                                                    AS profile_id,
  'tp1c-2026-10-15.v1'::text                                              AS rule_version,

  coalesce(r.education, r.f_edu)                                          AS education,
  CASE WHEN r.education IS NOT NULL THEN 'profile'
       WHEN r.f_edu IS NOT NULL     THEN 'partner_form' END               AS education_source,
  CASE WHEN r.education IS NULL THEN r.f_edu_status END                   AS education_source_status,
  CASE WHEN r.education IS NULL THEN r.f_edu_date END                     AS education_source_date,
  coalesce((r.education IS NOT NULL AND r.f_edu IS NOT NULL AND r.education <> r.f_edu)
           OR r.f_edu_n > 1, false)                                       AS education_conflict,

  coalesce(r.race, r.f_race)                                              AS race,
  coalesce(coalesce(r.race, r.f_race) = 'Prefiro não informar', false)    AS race_declined,
  CASE WHEN r.race IS NOT NULL   THEN 'profile'
       WHEN r.f_race IS NOT NULL THEN 'partner_form' END                  AS race_source,
  CASE WHEN r.race IS NULL THEN r.f_race_status END                       AS race_source_status,
  CASE WHEN r.race IS NULL THEN r.f_race_date END                         AS race_source_date,
  coalesce((r.race IS NOT NULL AND r.f_race IS NOT NULL AND r.race <> r.f_race)
           OR r.f_race_n > 1, false)                                      AS race_conflict,

  coalesce(r.school_type, r.f_school)                                     AS school_type,
  CASE WHEN r.school_type IS NOT NULL THEN 'profile'
       WHEN r.f_school IS NOT NULL    THEN 'partner_form' END             AS school_type_source,
  CASE WHEN r.school_type IS NULL THEN r.f_school_status END              AS school_type_source_status,
  CASE WHEN r.school_type IS NULL THEN r.f_school_date END                AS school_type_source_date,
  coalesce((r.school_type IS NOT NULL AND r.f_school IS NOT NULL AND r.school_type <> r.f_school)
           OR r.f_school_n > 1, false)                                    AS school_type_conflict,

  -- Renda: user_income > onboarding v0 > formulário em R$ > faixa em SM.
  coalesce(r.income_declared, r.f_brl)                                    AS income_brl,
  CASE WHEN coalesce(r.income_declared, r.f_brl) IS NULL THEN r.f_band END AS income_band_sm,
  CASE WHEN coalesce(r.income_declared, r.f_brl) IS NOT NULL THEN 'brl'
       WHEN r.f_band IS NOT NULL                             THEN 'sm_band' END AS income_kind,
  CASE WHEN r.income_profile IS NOT NULL    THEN 'profile'
       WHEN r.income_onboarding IS NOT NULL THEN 'onboarding_v0'
       WHEN r.f_brl IS NOT NULL             THEN 'partner_form'
       WHEN r.f_band IS NOT NULL            THEN 'partner_form' END       AS income_source,
  CASE WHEN r.income_declared IS NOT NULL THEN NULL
       WHEN r.f_brl IS NOT NULL           THEN r.f_brl_status
       ELSE r.f_band_status END                                           AS income_source_status,
  CASE WHEN r.income_declared IS NOT NULL THEN NULL
       WHEN r.f_brl IS NOT NULL           THEN r.f_brl_date
       ELSE r.f_band_date END                                             AS income_source_date,
  -- Faixa em SM nunca é comparada com valor em reais: isso exigiria conversão.
  coalesce((r.income_declared IS NOT NULL AND r.f_brl IS NOT NULL
            AND round(r.income_declared, 2) <> round(r.f_brl, 2))
           OR r.f_brl_n > 1
           OR (coalesce(r.income_declared, r.f_brl) IS NULL AND r.f_band_n > 1), false) AS income_conflict
FROM resolved r;

COMMENT ON VIEW public.vw_user_demographics_resolved IS
'Uma linha por user_profiles.id com escolaridade, raça, tipo de escola e renda resolvidos por precedência (perfil válido > formulário de parceiro mais recente; renda: user_income > onboarding v0 > formulário em R$ > faixa em salários mínimos), com source/source_status/source_date/conflict e rule_version. Datas de perfil não são registradas por campo (NULL). Sem grant para API; ler via get_command_center_demographics(). Card f245da71.';

-- Nenhum papel de API lê as views diretamente. service_role também fica de
-- fora: não há consumidor de backend, e o default privilege do Supabase daria
-- ALL a ele.
DO $acl_views$
DECLARE
  v_role TEXT;
BEGIN
  REVOKE ALL ON public.vw_user_match_evidence FROM PUBLIC;
  REVOKE ALL ON public.vw_user_demographics_resolved FROM PUBLIC;
  FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated', 'service_role', 'partner'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
      EXECUTE format('REVOKE ALL ON public.vw_user_match_evidence FROM %I', v_role);
      EXECUTE format('REVOKE ALL ON public.vw_user_demographics_resolved FROM %I', v_role);
    END IF;
  END LOOP;
END
$acl_views$;

-- ── RPC ─────────────────────────────────────────────────────────────────────
-- Mesma assinatura () → json: CREATE OR REPLACE substitui sem criar overload.
-- Chaves e tipos atuais preservados (contrato do Index/PR58); tudo o que é
-- novo é aditivo.
CREATE OR REPLACE FUNCTION public.get_command_center_demographics()
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSON;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_command_center_demographics: acesso restrito ao backoffice'
      USING ERRCODE = '42501';
  END IF;

  WITH m AS (
    SELECT bucket, v1_has_result, v1_has_mec_result
      FROM public.vw_user_match_evidence
  ),
  d AS (
    SELECT * FROM public.vw_user_demographics_resolved
  ),
  -- with_match passa a ser "concluiu Match alguma vez" (v0 ∪ v1, D1/D2).
  -- Resultado no motor atual vira métrica secundária.
  health AS (
    SELECT
      count(*) FILTER (WHERE bucket = 'concluded')            AS with_match,
      count(*) FILTER (WHERE bucket <> 'concluded')           AS without_match,
      count(*)                                                AS total,
      count(*) FILTER (WHERE bucket = 'attempted_no_result')  AS attempted_no_result,
      count(*) FILTER (WHERE bucket = 'never')                AS never,
      count(*) FILTER (WHERE v1_has_result)                   AS with_current_result,
      count(*) FILTER (WHERE v1_has_mec_result)               AS with_current_mec_result
    FROM m
  ),
  -- "Não respondeu" é bucket explícito e vai por último.
  dim_education AS (
    SELECT coalesce(education, 'Não respondeu') AS label, count(*)::bigint AS value,
           (education IS NULL) AS is_unanswered
    FROM d GROUP BY 1, 3
  ),
  dim_race AS (
    SELECT coalesce(race, 'Não respondeu') AS label, count(*)::bigint AS value,
           (race IS NULL) AS is_unanswered
    FROM d GROUP BY 1, 3
  ),
  dim_school AS (
    SELECT coalesce(school_type, 'Não respondeu') AS label, count(*)::bigint AS value,
           (school_type IS NULL) AS is_unanswered
    FROM d GROUP BY 1, 3
  ),
  -- Faixas em R$ como antes. Quem só declarou faixa em salários mínimos ganha
  -- bucket próprio (D3), entre as faixas em R$ e "Não respondeu".
  dim_income AS (
    SELECT
      CASE
        WHEN income_brl IS NOT NULL THEN
          CASE
            WHEN income_brl <= 500  THEN 'Até R$ 500'
            WHEN income_brl <= 1000 THEN 'R$ 500 a R$ 1.000'
            WHEN income_brl <= 1500 THEN 'R$ 1.000 a R$ 1.500'
            WHEN income_brl <= 3000 THEN 'R$ 1.500 a R$ 3.000'
            ELSE                         'Acima de R$ 3.000'
          END
        WHEN income_band_sm IS NOT NULL THEN 'Faixa declarada em salários mínimos'
        ELSE 'Não respondeu'
      END AS label,
      CASE
        WHEN income_brl IS NOT NULL THEN
          CASE
            WHEN income_brl <= 500  THEN 1
            WHEN income_brl <= 1000 THEN 2
            WHEN income_brl <= 1500 THEN 3
            WHEN income_brl <= 3000 THEN 4
            ELSE 5
          END
        WHEN income_band_sm IS NOT NULL THEN 90
        ELSE 99
      END AS bucket_order,
      count(*)::bigint AS value
    FROM d GROUP BY 1, 2
  ),
  prov AS (
    SELECT
      min(rule_version)                                                                  AS rule_version,
      count(*) FILTER (WHERE education_source = 'profile')                               AS edu_profile,
      count(*) FILTER (WHERE education_source = 'partner_form')                          AS edu_form,
      count(*) FILTER (WHERE education_source IS NULL)                                   AS edu_none,
      count(*) FILTER (WHERE education_conflict)                                         AS edu_conflicts,
      count(*) FILTER (WHERE race_source = 'profile')                                    AS race_profile,
      count(*) FILTER (WHERE race_source = 'partner_form')                               AS race_form,
      count(*) FILTER (WHERE race_source IS NULL)                                        AS race_none,
      count(*) FILTER (WHERE race_conflict)                                              AS race_conflicts,
      count(*) FILTER (WHERE race_declined)                                              AS race_declined,
      count(*) FILTER (WHERE school_type_source = 'profile')                             AS school_profile,
      count(*) FILTER (WHERE school_type_source = 'partner_form')                        AS school_form,
      count(*) FILTER (WHERE school_type_source IS NULL)                                 AS school_none,
      count(*) FILTER (WHERE school_type_conflict)                                       AS school_conflicts,
      count(*) FILTER (WHERE income_source = 'profile')                                  AS inc_profile,
      count(*) FILTER (WHERE income_source = 'onboarding_v0')                            AS inc_onboarding,
      count(*) FILTER (WHERE income_source = 'partner_form' AND income_kind = 'brl')     AS inc_form,
      count(*) FILTER (WHERE income_source = 'partner_form' AND income_kind = 'sm_band') AS inc_sm_band,
      count(*) FILTER (WHERE income_kind IS NULL)                                        AS inc_none,
      count(*) FILTER (WHERE income_conflict)                                            AS inc_conflicts
    FROM d
  )
  SELECT json_build_object(
    'match_health', (
      SELECT json_build_object(
        'with_match', with_match,
        'without_match', without_match,
        'total', total,
        'attempted_no_result', attempted_no_result,
        'never', never,
        'with_current_result', with_current_result,
        'with_current_mec_result', with_current_mec_result
      ) FROM health
    ),
    'education', (
      SELECT coalesce(json_agg(json_build_object('label', label, 'value', value)
             ORDER BY is_unanswered, value DESC, label), '[]'::json) FROM dim_education
    ),
    'income', (
      SELECT coalesce(json_agg(json_build_object('label', label, 'value', value)
             ORDER BY bucket_order), '[]'::json) FROM dim_income
    ),
    'race', (
      SELECT coalesce(json_agg(json_build_object('label', label, 'value', value)
             ORDER BY is_unanswered, value DESC, label), '[]'::json) FROM dim_race
    ),
    'school_type', (
      SELECT coalesce(json_agg(json_build_object('label', label, 'value', value)
             ORDER BY is_unanswered, value DESC, label), '[]'::json) FROM dim_school
    ),
    -- Contagem por origem do valor exibido em cada dimensão (aditivo).
    'provenance', (
      SELECT json_build_object(
        'rule_version', rule_version,
        'education',   json_build_object('profile', edu_profile, 'partner_form', edu_form,
                                         'unanswered', edu_none, 'conflicts', edu_conflicts),
        'race',        json_build_object('profile', race_profile, 'partner_form', race_form,
                                         'unanswered', race_none, 'conflicts', race_conflicts,
                                         'declined', race_declined),
        'school_type', json_build_object('profile', school_profile, 'partner_form', school_form,
                                         'unanswered', school_none, 'conflicts', school_conflicts),
        'income',      json_build_object('profile', inc_profile, 'onboarding_v0', inc_onboarding,
                                         'partner_form', inc_form, 'sm_band', inc_sm_band,
                                         'unanswered', inc_none, 'conflicts', inc_conflicts)
      ) FROM prov
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.get_command_center_demographics() IS
'Saúde do match (concluiu v0∪v1, tentou sem resultado, nunca; resultado atual como métrica secundária) + 4 distribuições demográficas resolvidas com proveniência, num único round-trip. Lê vw_user_match_evidence e vw_user_demographics_resolved. Devolve apenas contagens agregadas e exige is_backoffice_admin(). TP-1 1B / card 7731cb55; complemento card f245da71.';

DO $acl$
DECLARE
  v_role TEXT;
BEGIN
  EXECUTE 'REVOKE EXECUTE ON FUNCTION public.get_command_center_demographics() FROM PUBLIC';
  FOREACH v_role IN ARRAY ARRAY['anon', 'partner'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
      EXECUTE format('REVOKE EXECUTE ON FUNCTION public.get_command_center_demographics() FROM %I', v_role);
    END IF;
  END LOOP;
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.get_command_center_demographics() TO authenticated';
END
$acl$;
