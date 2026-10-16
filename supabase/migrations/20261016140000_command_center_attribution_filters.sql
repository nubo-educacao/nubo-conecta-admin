-- Command Center — filtros de campanha/divulgador por aquisição FIRST-TOUCH
-- Mesmo contrato do TP-7 / NHB-123b (artefato 46d78fd5, confirmado pelo PO em
-- 15/10/2026), já aplicado a Estudantes e Inscrições em
-- 20261015202330_tp7_first_touch_attribution_filters.sql.
--
-- Regra: a pessoa pertence à campanha/divulgador do link do seu PRIMEIRO toque
--   user_attribution.first_touch_link_id → channel_links.(campaign_id, channel_id)
-- O último toque não entra. Links arquivados continuam valendo (recorte histórico).
--
-- Parâmetros novos, idênticos aos das RPCs de Estudantes e sempre AO FIM:
--   p_filter_campaign_id   uuid    DEFAULT NULL
--   p_filter_channel_id    uuid    DEFAULT NULL   (AND com a campanha, no mesmo link)
--   p_filter_unattributed  boolean DEFAULT NULL   (true = sem linha em
--                                                  user_attribution ou first-touch nulo)
-- Todos NULL = resultado, contagens e ordenação exatamente iguais aos de antes:
-- o predicado é curto-circuitado por v_filtered e nem chega a ser avaliado.
-- `unattributed = true` junto com campanha/divulgador é recusado (22023), pelo
-- mesmo helper assert_attribution_filter do TP-7.
--
-- Funções alteradas (corpo copiado da última definição; só o recorte é novo):
--   * get_command_center_opportunity_interest  (20261009203000)
--     Com filtro ativo, só entram cliques de usuários LOGADOS: engagement_events
--     anônimos (user_id NULL) não têm como ser atribuídos e são excluídos.
--     Sem filtro, os anônimos continuam contando como antes.
--   * get_command_center_demographics          (20261015204255)
--     O recorte é aplicado às duas views (uma linha por user_profiles.id), então
--     saúde do Match e as quatro distribuições partem do mesmo conjunto e a soma
--     de cada dimensão continua igual a match_health.total.
--
-- user_attribution tem PK em user_id: o predicado nunca multiplica pessoas.
-- Nada de regex/LIKE em referral_source.
--
-- Cada assinatura antiga é DROPada antes do CREATE. CREATE OR REPLACE com
-- assinatura diferente criaria um overload, e o PostgREST passaria a falhar com
-- "could not choose the best candidate function" (PGRST203). Nenhuma view ou
-- função do schema depende destas duas RPCs (só o front as chama).
--
-- Guard, SECURITY DEFINER, search_path, chaves de retorno e ACL são os das
-- definições anteriores. Depende dos helpers matches_first_touch_attribution e
-- assert_attribution_filter, criados em 20261015202330.
--
-- Reversão: reaplicar o bloco de cada função das migrations 20261009203000 e
-- 20261015204255 depois de DROPar as assinaturas novas.

-- ─── get_command_center_opportunity_interest ────────────────────────────────

DROP FUNCTION IF EXISTS public.get_command_center_opportunity_interest(timestamptz, timestamptz, integer);

CREATE FUNCTION public.get_command_center_opportunity_interest(
  p_from timestamptz DEFAULT NULL,
  p_to timestamptz DEFAULT NULL,
  p_limit integer DEFAULT 10,
  p_filter_campaign_id uuid DEFAULT NULL,
  p_filter_channel_id uuid DEFAULT NULL,
  p_filter_unattributed boolean DEFAULT NULL
)
RETURNS TABLE (opportunity_id text, title text, provider text, clicks bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_from timestamptz := coalesce(p_from, now() - interval '7 days');
  v_to timestamptz := coalesce(p_to, now());
  v_filtered boolean := p_filter_campaign_id IS NOT NULL
                     OR p_filter_channel_id IS NOT NULL
                     OR p_filter_unattributed IS TRUE;
BEGIN
  IF NOT coalesce(public.is_backoffice_admin(), false) THEN
    RAISE EXCEPTION 'get_command_center_opportunity_interest: acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;
  PERFORM public.assert_attribution_filter(p_filter_campaign_id, p_filter_channel_id, p_filter_unattributed);
  IF v_to <= v_from THEN
    RAISE EXCEPTION 'Período inválido' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  WITH events AS (
    SELECT e.entity_type,
      coalesce(e.entity_id, CASE
        WHEN e.unified_opportunity_id ~ ('^' || CASE e.entity_type WHEN 'partner_opportunity' THEN 'partner_' ELSE 'mec_' END || '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
        THEN substring(e.unified_opportunity_id FROM position('_' IN e.unified_opportunity_id) + 1)::uuid
      END) AS resolved_id,
      e.event_count
    FROM public.engagement_events e
    WHERE e.event_type = 'card_click' AND e.source = 'card'
      AND e.entity_type IN ('partner_opportunity', 'mec_opportunity')
      AND e.occurred_at >= v_from AND e.occurred_at < v_to
      -- Recorte first-touch: só com filtro ativo, e aí só cliques de logados.
      AND (NOT v_filtered OR (e.user_id IS NOT NULL AND public.matches_first_touch_attribution(
            e.user_id, p_filter_campaign_id, p_filter_channel_id, p_filter_unattributed)))
  ), totals AS (
    SELECT e.entity_type, e.resolved_id, sum(e.event_count)::bigint AS clicks
    FROM events e WHERE e.resolved_id IS NOT NULL
    GROUP BY e.entity_type, e.resolved_id
  ), resolved AS (
    SELECT 'partner_' || po.id::text AS opportunity_id, po.name::text AS title,
      i.name::text AS provider, t.clicks
    FROM totals t JOIN public.partner_opportunities po ON po.id = t.resolved_id
      JOIN public.institutions i ON i.id = po.institution_id
    WHERE t.entity_type = 'partner_opportunity'
    UNION ALL
    SELECT 'mec_' || o.id::text, concat(c.course_name, ' — ', upper(o.opportunity_type), ' ', o.year, '/', o.semester),
      i.name::text, t.clicks
    FROM totals t JOIN public.opportunities o ON o.id = t.resolved_id
      JOIN public.courses c ON c.id = o.course_id
      JOIN public.campus ca ON ca.id = c.campus_id
      JOIN public.institutions i ON i.id = ca.institution_id
    WHERE t.entity_type = 'mec_opportunity'
  )
  SELECT r.opportunity_id, r.title, r.provider, r.clicks FROM resolved r
  ORDER BY r.clicks DESC, r.title, r.opportunity_id
  LIMIT greatest(1, least(coalesce(p_limit, 10), 100));
END;
$$;
REVOKE ALL ON FUNCTION public.get_command_center_opportunity_interest(timestamptz,timestamptz,integer,uuid,uuid,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_command_center_opportunity_interest(timestamptz,timestamptz,integer,uuid,uuid,boolean) FROM anon;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'partner') THEN
    REVOKE ALL ON FUNCTION public.get_command_center_opportunity_interest(timestamptz,timestamptz,integer,uuid,uuid,boolean) FROM partner;
  END IF;
END $$;
GRANT EXECUTE ON FUNCTION public.get_command_center_opportunity_interest(timestamptz,timestamptz,integer,uuid,uuid,boolean) TO authenticated;
COMMENT ON FUNCTION public.get_command_center_opportunity_interest(timestamptz,timestamptz,integer,uuid,uuid,boolean) IS
  'TP-1 / handoff TP-2 0cb07420: ranking por SUM(event_count), apenas card_click de fonte card; período [from,to), sem legado dual-write, favoritos, views ou redirects. Recorte opcional por campanha/divulgador first-touch (p_filter_*); com recorte ativo só entram cliques de usuários logados.';

-- ─── get_command_center_demographics ────────────────────────────────────────

DROP FUNCTION IF EXISTS public.get_command_center_demographics();

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

COMMENT ON FUNCTION public.get_command_center_demographics(uuid, uuid, boolean) IS
'Saúde do match (concluiu v0∪v1, tentou sem resultado, nunca; resultado atual como métrica secundária) + 4 distribuições demográficas resolvidas com proveniência, num único round-trip. Lê vw_user_match_evidence e vw_user_demographics_resolved. Devolve apenas contagens agregadas e exige is_backoffice_admin(). Recorte opcional por campanha/divulgador first-touch (p_filter_*). TP-1 1B / card 7731cb55; complemento card f245da71.';

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
