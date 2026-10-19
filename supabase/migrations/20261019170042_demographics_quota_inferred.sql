-- NUB-RD-92 — demografia inferida por cota (TP-B 88f53add rev. 2, decisões D4/N3).
--
-- Só 2% dos perfis têm raça/cor e 11% tipo de escola, mas centenas declararam
-- cotas em user_preferences.quota_types. Esta migration passa a usar a cota
-- como fonte SEPARADA, rotulada "(por cota)", sem nunca transformá-la em
-- autodeclaração. Nenhuma tabela é escrita: muda só o read path.
--
-- ⚠️ Delta explícito à decisão TP1C (20261015204255): aquele header diz que
-- "quota_types … NÃO são fonte de raça, renda ou tipo de escola". NUB-RD-92
-- supersede esse trecho só para quota_types × raça/escola: a cota é fonte
-- separada, rotulada "inferido por cota", nunca autodeclaração. As colunas
-- race/school_type e suas *_source continuam exatamente como eram; a inferência
-- vive em colunas novas, acrescentadas AO FINAL da view.
--
-- Regras:
--   * Normalização: lower(unaccent(btrim(x))), espaços/hífens → '_'
--     (normalize_quota_token). Vazio vira NULL e é ignorado.
--   * Mapeamento literal (D4). Fora da tabela = ignorado e contado como
--     não mapeado (quilombola(s), ppiq, baixa renda, ampla concorrência,
--     pcd/pdc, 100% e qualquer outro):
--       ppi                                      → race   "PPI (por cota)"
--       pretos_e_pardos                          → race   "Pretos e pardos (por cota)"
--       indigenas | indigena                     → race   "Indígena (por cota)"
--       escola_publica                           → escola "Escola pública (por cota)"
--       escola_privada_bolsa_integral | bolsa_integral
--                                                → escola "Privada com bolsa integral (por cota)"
--   * Precedência racial (N3): Indígena > Pretos e pardos > PPI. PPI e "pretos
--     e pardos" não separam preta/parda/indígena: nunca viram raça individual.
--   * Escola pública E bolsa integral no mesmo usuário = conflito: não infere
--     (P-B1, a confirmar no aceite).
--   * Autodeclaração sempre prevalece: qualquer valor de perfil ou formulário,
--     INCLUSIVE "Prefiro não informar", bloqueia a inferência daquela dimensão.
--   * quota_source_date = user_preferences.updated_at, só quando algo foi
--     inferido (é a data do registro de preferências, não da declaração).
--
-- RPC get_command_center_demographics(uuid, uuid, boolean): mesma assinatura e
-- mesmo tipo de retorno; tudo é aditivo.
--   * race[]/school_type[]: itens "(por cota)" como rótulos próprios, nunca
--     somados a um autodeclarado; cada item ganha "source" (self_declared |
--     quota_inferred | unanswered). Soma de cada dimensão = match_health.total.
--   * provenance.race/.school_type: + quota_inferred, quota_unmapped e (escola)
--     quota_conflict. quota_unmapped = perfis com ao menos um token fora do
--     mapeamento; quota_conflict = perfis sem autodeclaração de escola com
--     pública + bolsa. Os dois são diagnóstico: NÃO são parcelas da cobertura.
--   * coverage{race, school_type}: cada perfil conta uma vez.
--       self_declared  = valor autodeclarado conhecido (recusa NÃO entra)
--       quota_inferred = inferido por cota (sem autodeclaração nem recusa)
--       uncovered      = o restante (inclui a recusa)
--       self_declared + quota_inferred + uncovered = total_users
--     race.declined mostra a recusa à parte (subconjunto de uncovered).
--     Percentuais com 1 casa; total_users = 0 → NULL.
--   * Recorte first-touch inalterado: vale para as linhas inferidas também.
--   * Demografia é snapshot do estado atual (sem período).
--
-- Guard, SECURITY DEFINER, search_path e ACL iguais aos de 20261016140000. A
-- assinatura exata é DROPada antes do CREATE (sem overload; nenhuma view ou
-- função depende da RPC). As views continuam sem grant para papéis de API.
--
-- Reversão: reaplicar o bloco da view de 20261015204255 não serve (CREATE OR
-- REPLACE VIEW não remove colunas): DROP VIEW vw_user_demographics_resolved,
-- reaplicar o bloco da view + ACL de 20261015204255, reaplicar o bloco da RPC
-- de 20261016140000 e DROP FUNCTION normalize_quota_token(text).

-- ── Normalização de token de cota ───────────────────────────────────────────
-- unaccent() de 1 argumento é STABLE (depende do search_path); a forma com o
-- dicionário qualificado permite IMMUTABLE. A extensão existe em public no DEV
-- e em PROD (conferido em 19/10/2026).
CREATE FUNCTION public.normalize_quota_token(p_token text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = ''
AS $$
  SELECT nullif(
    pg_catalog.regexp_replace(
      pg_catalog.lower(public.unaccent('public.unaccent'::regdictionary, pg_catalog.btrim(p_token))),
      '[[:space:]-]+', '_', 'g'),
    '')
$$;

COMMENT ON FUNCTION public.normalize_quota_token(text) IS
'Normaliza um token de user_preferences.quota_types: lower(unaccent(btrim(x))) com espaços/hífens trocados por _; vazio → NULL. Uso interno de vw_user_demographics_resolved. NUB-RD-92.';

DO $acl_norm$
DECLARE
  v_role TEXT;
BEGIN
  REVOKE ALL ON FUNCTION public.normalize_quota_token(text) FROM PUBLIC;
  FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated', 'service_role', 'partner'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
      EXECUTE format('REVOKE ALL ON FUNCTION public.normalize_quota_token(text) FROM %I', v_role);
    END IF;
  END LOOP;
END
$acl_norm$;

-- ── Demografia resolvida: definição vigente + colunas de cota ao final ──────
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
         pref.family_income_per_capita                   AS income_onboarding,
         pref.updated_at                                 AS pref_updated_at
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
),
-- NUB-RD-92: cotas declaradas → sinais por dimensão (mapeamento literal D4).
quota_tokens AS (
  SELECT pref.user_id, public.normalize_quota_token(t.raw) AS token
    FROM public.user_preferences pref
   CROSS JOIN LATERAL unnest(pref.quota_types) AS t(raw)
),
quota AS (
  SELECT q.user_id,
         bool_or(q.token IN ('indigenas', 'indigena'))                         AS q_indigena,
         bool_or(q.token = 'pretos_e_pardos')                                  AS q_pretos_pardos,
         bool_or(q.token = 'ppi')                                              AS q_ppi,
         bool_or(q.token = 'escola_publica')                                   AS q_publica,
         bool_or(q.token IN ('escola_privada_bolsa_integral', 'bolsa_integral')) AS q_bolsa,
         bool_or(q.token NOT IN ('ppi', 'pretos_e_pardos', 'indigenas', 'indigena', 'escola_publica',
                                 'escola_privada_bolsa_integral', 'bolsa_integral')) AS q_unmapped
    FROM quota_tokens q
   WHERE q.token IS NOT NULL
   GROUP BY q.user_id
),
with_quota AS (
  -- Autodeclaração (perfil ou formulário, inclusive a recusa) bloqueia a
  -- inferência da dimensão. Precedência racial N3: Indígena > Pretos e pardos > PPI.
  SELECT r.*,
         CASE WHEN coalesce(r.race, r.f_race) IS NULL THEN
           CASE WHEN q.q_indigena      THEN 'Indígena (por cota)'
                WHEN q.q_pretos_pardos THEN 'Pretos e pardos (por cota)'
                WHEN q.q_ppi           THEN 'PPI (por cota)'
           END
         END AS q_race_label,
         CASE WHEN coalesce(r.school_type, r.f_school) IS NULL
               AND NOT (coalesce(q.q_publica, false) AND coalesce(q.q_bolsa, false)) THEN
           CASE WHEN q.q_publica THEN 'Escola pública (por cota)'
                WHEN q.q_bolsa   THEN 'Privada com bolsa integral (por cota)'
           END
         END AS q_school_label,
         coalesce(coalesce(r.school_type, r.f_school) IS NULL
                  AND q.q_publica AND q.q_bolsa, false)                        AS q_school_conflict,
         coalesce(q.q_unmapped, false)                                         AS q_unmapped
    FROM resolved r
    LEFT JOIN quota q ON q.user_id = r.id
)
SELECT
  r.id                                                                    AS profile_id,
  'tp1c-2026-10-15.v1+nub-rd-92'::text                                    AS rule_version,

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
           OR (coalesce(r.income_declared, r.f_brl) IS NULL AND r.f_band_n > 1), false) AS income_conflict,

  -- NUB-RD-92 (append): inferência por cota, fonte separada da autodeclaração.
  r.q_race_label                                                          AS race_quota_label,
  r.q_school_label                                                        AS school_type_quota_label,
  CASE WHEN r.q_race_label IS NOT NULL OR r.q_school_label IS NOT NULL
       THEN r.pref_updated_at END                                         AS quota_source_date,
  r.q_school_conflict                                                     AS school_type_quota_conflict,
  r.q_unmapped                                                            AS quota_has_unmapped
FROM with_quota r;

COMMENT ON VIEW public.vw_user_demographics_resolved IS
'Uma linha por user_profiles.id com escolaridade, raça, tipo de escola e renda resolvidos por precedência (perfil válido > formulário de parceiro mais recente; renda: user_income > onboarding v0 > formulário em R$ > faixa em salários mínimos), com source/source_status/source_date/conflict e rule_version. Datas de perfil não são registradas por campo (NULL). NUB-RD-92: race_quota_label/school_type_quota_label trazem a inferência por cota (user_preferences.quota_types, mapeamento D4, precedência N3), fonte SEPARADA que só existe sem autodeclaração — nunca altera race/school_type. Sem grant para API; ler via get_command_center_demographics(). Card f245da71; NUB-RD-92.';

-- Mesma ACL de 20261015204255: nenhum papel de API lê a view diretamente.
DO $acl_views$
DECLARE
  v_role TEXT;
BEGIN
  REVOKE ALL ON public.vw_user_demographics_resolved FROM PUBLIC;
  FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated', 'service_role', 'partner'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
      EXECUTE format('REVOKE ALL ON public.vw_user_demographics_resolved FROM %I', v_role);
    END IF;
  END LOOP;
END
$acl_views$;

-- ── RPC ─────────────────────────────────────────────────────────────────────
-- Corpo de 20261016140000; muda só o que está marcado NUB-RD-92.
DROP FUNCTION IF EXISTS public.get_command_center_demographics(uuid, uuid, boolean);

CREATE FUNCTION public.get_command_center_demographics(
  p_filter_campaign_id uuid DEFAULT NULL,
  p_filter_channel_id uuid DEFAULT NULL,
  p_filter_unattributed boolean DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSON;
  v_filtered boolean := p_filter_campaign_id IS NOT NULL
                     OR p_filter_channel_id IS NOT NULL
                     OR p_filter_unattributed IS TRUE;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_command_center_demographics: acesso restrito ao backoffice'
      USING ERRCODE = '42501';
  END IF;

  PERFORM public.assert_attribution_filter(p_filter_campaign_id, p_filter_channel_id, p_filter_unattributed);

  WITH m AS (
    SELECT bucket, v1_has_result, v1_has_mec_result
      FROM public.vw_user_match_evidence
     WHERE NOT v_filtered OR public.matches_first_touch_attribution(
             profile_id, p_filter_campaign_id, p_filter_channel_id, p_filter_unattributed)
  ),
  d AS (
    SELECT * FROM public.vw_user_demographics_resolved
     WHERE NOT v_filtered OR public.matches_first_touch_attribution(
             profile_id, p_filter_campaign_id, p_filter_channel_id, p_filter_unattributed)
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
  -- NUB-RD-92: o rótulo "(por cota)" é próprio; nunca soma com um autodeclarado.
  -- Ordem: autodeclarados, inferidos por cota, "Não respondeu".
  dim_race AS (
    SELECT coalesce(race, race_quota_label, 'Não respondeu') AS label,
           CASE WHEN race IS NOT NULL             THEN 'self_declared'
                WHEN race_quota_label IS NOT NULL THEN 'quota_inferred'
                ELSE 'unanswered' END AS source,
           count(*)::bigint AS value
    FROM d GROUP BY 1, 2
  ),
  dim_school AS (
    SELECT coalesce(school_type, school_type_quota_label, 'Não respondeu') AS label,
           CASE WHEN school_type IS NOT NULL             THEN 'self_declared'
                WHEN school_type_quota_label IS NOT NULL THEN 'quota_inferred'
                ELSE 'unanswered' END AS source,
           count(*)::bigint AS value
    FROM d GROUP BY 1, 2
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
      count(*)                                                                           AS total_users,
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
      count(*) FILTER (WHERE income_conflict)                                            AS inc_conflicts,
      -- NUB-RD-92
      count(*) FILTER (WHERE race IS NOT NULL AND NOT race_declined)                     AS race_self,
      count(*) FILTER (WHERE race_quota_label IS NOT NULL)                               AS race_quota,
      count(*) FILTER (WHERE school_type IS NOT NULL)                                    AS school_self,
      count(*) FILTER (WHERE school_type_quota_label IS NOT NULL)                        AS school_quota,
      count(*) FILTER (WHERE school_type_quota_conflict)                                 AS school_quota_conflict,
      count(*) FILTER (WHERE quota_has_unmapped)                                         AS quota_unmapped
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
      SELECT coalesce(json_agg(json_build_object('label', label, 'value', value, 'source', source)
             ORDER BY source = 'unanswered', source = 'quota_inferred', value DESC, label), '[]'::json) FROM dim_race
    ),
    'school_type', (
      SELECT coalesce(json_agg(json_build_object('label', label, 'value', value, 'source', source)
             ORDER BY source = 'unanswered', source = 'quota_inferred', value DESC, label), '[]'::json) FROM dim_school
    ),
    -- Contagem por origem do valor exibido em cada dimensão (aditivo).
    'provenance', (
      SELECT json_build_object(
        'rule_version', rule_version,
        'education',   json_build_object('profile', edu_profile, 'partner_form', edu_form,
                                         'unanswered', edu_none, 'conflicts', edu_conflicts),
        'race',        json_build_object('profile', race_profile, 'partner_form', race_form,
                                         'unanswered', race_none, 'conflicts', race_conflicts,
                                         'declined', race_declined,
                                         'quota_inferred', race_quota, 'quota_unmapped', quota_unmapped),
        'school_type', json_build_object('profile', school_profile, 'partner_form', school_form,
                                         'unanswered', school_none, 'conflicts', school_conflicts,
                                         'quota_inferred', school_quota, 'quota_unmapped', quota_unmapped,
                                         'quota_conflict', school_quota_conflict),
        'income',      json_build_object('profile', inc_profile, 'onboarding_v0', inc_onboarding,
                                         'partner_form', inc_form, 'sm_band', inc_sm_band,
                                         'unanswered', inc_none, 'conflicts', inc_conflicts)
      ) FROM prov
    ),
    -- NUB-RD-92: cobertura por perfil único. self + quota + uncovered = total.
    'coverage', (
      SELECT json_build_object(
        'race', json_build_object(
          'total_users', total_users,
          'self_declared', race_self,
          'quota_inferred', race_quota,
          'uncovered', total_users - race_self - race_quota,
          'declined', race_declined,
          'self_declared_pct',  CASE WHEN total_users > 0 THEN round(100.0 * race_self / total_users, 1) END,
          'quota_inferred_pct', CASE WHEN total_users > 0 THEN round(100.0 * race_quota / total_users, 1) END,
          'uncovered_pct',      CASE WHEN total_users > 0 THEN round(100.0 * (total_users - race_self - race_quota) / total_users, 1) END,
          'covered_pct',        CASE WHEN total_users > 0 THEN round(100.0 * (race_self + race_quota) / total_users, 1) END),
        'school_type', json_build_object(
          'total_users', total_users,
          'self_declared', school_self,
          'quota_inferred', school_quota,
          'uncovered', total_users - school_self - school_quota,
          'self_declared_pct',  CASE WHEN total_users > 0 THEN round(100.0 * school_self / total_users, 1) END,
          'quota_inferred_pct', CASE WHEN total_users > 0 THEN round(100.0 * school_quota / total_users, 1) END,
          'uncovered_pct',      CASE WHEN total_users > 0 THEN round(100.0 * (total_users - school_self - school_quota) / total_users, 1) END,
          'covered_pct',        CASE WHEN total_users > 0 THEN round(100.0 * (school_self + school_quota) / total_users, 1) END)
      ) FROM prov
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.get_command_center_demographics(uuid, uuid, boolean) IS
'Saúde do match (concluiu v0∪v1, tentou sem resultado, nunca; resultado atual como métrica secundária) + 4 distribuições demográficas resolvidas com proveniência, num único round-trip. Lê vw_user_match_evidence e vw_user_demographics_resolved. Devolve apenas contagens agregadas e exige is_backoffice_admin(). Recorte opcional por campanha/divulgador first-touch (p_filter_*). NUB-RD-92: raça/escola com itens "(por cota)" separados (source), provenance.*.quota_* e bloco coverage por perfil único; snapshot atual, sem período. TP-1 1B / card 7731cb55; complemento card f245da71.';

DO $acl$
DECLARE
  v_role TEXT;
BEGIN
  EXECUTE 'REVOKE EXECUTE ON FUNCTION public.get_command_center_demographics(uuid, uuid, boolean) FROM PUBLIC';
  FOREACH v_role IN ARRAY ARRAY['anon', 'partner'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
      EXECUTE format('REVOKE EXECUTE ON FUNCTION public.get_command_center_demographics(uuid, uuid, boolean) FROM %I', v_role);
    END IF;
  END LOOP;
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.get_command_center_demographics(uuid, uuid, boolean) TO authenticated';
END
$acl$;
