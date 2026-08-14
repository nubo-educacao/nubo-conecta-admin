-- TP-1 1B t5/t6 — card 7731cb55 / ADR-0027
--
-- Uma RPC, um round-trip, cinco distribuições. O plano pede explicitamente uma
-- agregadora única em vez de 4 queries separadas: são 4 varreduras da mesma
-- tabela com os mesmos joins, e o Command Center já carrega dezenas de widgets.
--
-- Saúde do Match entra aqui como PIZZA, não como funil. ADR-0027 é explícita:
-- match é segmento de saúde do motor, não etapa de conversão. Os funis (MEC e
-- parceiro) são separados e vivem nos dashboards de domínio.
--
-- Ganho de escopo registrado no TP-1: o plano original previa 2 dimensões
-- demográficas (escolaridade e renda). QA-8 adicionou `race` (migration
-- 20260724183000) e `school_type` (20260729143541), então são 4 — de graça.
--
-- ⚠️ `race` é dado pessoal sensível (LGPD, Art. 5º, II). Esta RPC devolve apenas
-- CONTAGENS AGREGADAS, nunca linhas identificáveis, e é a razão de ela nascer
-- com guard administrativo desde a primeira versão. Não afrouxar isso depois
-- para "reaproveitar num dashboard público".

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

  WITH base AS (
    -- DISTINCT ON espelha a semântica de get_students_paginated: user_income e
    -- user_preferences podem ter mais de uma linha por usuário, e sem isso as
    -- contagens inflam silenciosamente.
    SELECT DISTINCT ON (p.id)
      p.id,
      nullif(trim(coalesce(p.education, '')), '')   AS education,
      nullif(trim(coalesce(p.race, '')), '')        AS race,
      nullif(trim(coalesce(p.school_type, '')), '') AS school_type,
      COALESCE(inc.per_capita_income, pref.family_income_per_capita) AS income
    FROM public.user_profiles p
    LEFT JOIN public.user_income inc ON inc.user_id = p.id
    LEFT JOIN public.user_preferences pref ON pref.user_id = p.id
    ORDER BY p.id
  ),
  matched AS (
    SELECT DISTINCT profile_id FROM public.user_opportunity_matches
  ),
  health AS (
    SELECT
      count(*) FILTER (WHERE m.profile_id IS NOT NULL) AS with_match,
      count(*) FILTER (WHERE m.profile_id IS NULL)     AS without_match,
      count(*)                                          AS total
    FROM base b
    LEFT JOIN matched m ON m.profile_id = b.id
  ),
  -- Cada dimensão categórica vira (label, count). "Não respondeu" é bucket
  -- explícito e vai por último: campo em branco é informação, não ausência de
  -- linha, e some do gráfico se for tratado como NULL.
  dim_education AS (
    SELECT coalesce(education, 'Não respondeu') AS label, count(*)::bigint AS value,
           (education IS NULL) AS is_unanswered
    FROM base GROUP BY 1, 3
  ),
  dim_race AS (
    SELECT coalesce(race, 'Não respondeu') AS label, count(*)::bigint AS value,
           (race IS NULL) AS is_unanswered
    FROM base GROUP BY 1, 3
  ),
  dim_school AS (
    SELECT coalesce(school_type, 'Não respondeu') AS label, count(*)::bigint AS value,
           (school_type IS NULL) AS is_unanswered
    FROM base GROUP BY 1, 3
  ),
  -- Renda per capita está em BRL (o front formata com R$ e 2 casas — ver
  -- StudentExportButton.tsx e StudentDetailsModal.tsx). Faixas fixas em reais.
  dim_income AS (
    SELECT
      CASE
        WHEN income IS NULL       THEN 'Não respondeu'
        WHEN income <= 500        THEN 'Até R$ 500'
        WHEN income <= 1000       THEN 'R$ 500 a R$ 1.000'
        WHEN income <= 1500       THEN 'R$ 1.000 a R$ 1.500'
        WHEN income <= 3000       THEN 'R$ 1.500 a R$ 3.000'
        ELSE                           'Acima de R$ 3.000'
      END AS label,
      CASE
        WHEN income IS NULL THEN 99
        WHEN income <= 500  THEN 1
        WHEN income <= 1000 THEN 2
        WHEN income <= 1500 THEN 3
        WHEN income <= 3000 THEN 4
        ELSE 5
      END AS bucket_order,
      count(*)::bigint AS value
    FROM base GROUP BY 1, 2
  )
  SELECT json_build_object(
    'match_health', (
      SELECT json_build_object(
        'with_match', with_match,
        'without_match', without_match,
        'total', total
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
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.get_command_center_demographics() IS
'Saúde do match (pizza) + 4 distribuições demográficas do Command Center, num único round-trip. Devolve apenas contagens agregadas — nunca linhas identificáveis — e exige is_backoffice_admin(). TP-1 1B / card 7731cb55.';

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
