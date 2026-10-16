-- TP-7 / NHB-123b — filtros de campanha/divulgador por aquisição FIRST-TOUCH
-- Execução Snaps a35258f7; contrato no artefato 46d78fd5 (confirmado pelo PO
-- em 15/10/2026).
--
-- Regra: a pessoa pertence à campanha/divulgador do link do seu PRIMEIRO toque
--   user_attribution.first_touch_link_id → channel_links.(campaign_id, channel_id)
-- O último toque não entra. É o mesmo critério de get_channel_performance.
--
-- Parâmetros novos, idênticos nas três RPCs e sempre AO FIM da assinatura:
--   p_filter_campaign_id   uuid    DEFAULT NULL
--   p_filter_channel_id    uuid    DEFAULT NULL   (AND com a campanha, no mesmo link)
--   p_filter_unattributed  boolean DEFAULT NULL   (true = sem first-touch)
-- Todos NULL = resultado, contagem e ordenação exatamente iguais aos de antes.
-- `unattributed = true` junto com campanha/divulgador é recusado (22023).
--
-- user_attribution tem PK em user_id: o predicado nunca multiplica pessoas.
-- Nada de regex/LIKE em referral_source.
--
-- Cada assinatura antiga é DROPada antes do CREATE. CREATE OR REPLACE com
-- assinatura diferente criaria um overload, e o PostgREST passaria a falhar com
-- "could not choose the best candidate function" (PGRST203).
--
-- Também nesta migration, porque as funções são recriadas:
--   * get_student_stats ganha guard de backoffice, search_path fixo e SQL
--     estático (antes: format() concatenando filtros). A renda passa a usar
--     COALESCE(user_income, user_preferences), igual à lista — antes o card de
--     total divergia da lista com filtro de renda.
--   * get_student_applications_with_details ganha guard de backoffice. Antes
--     era executável por anon e devolvia telefone e respostas. O único
--     consumidor é a tela admin /applications; o portal parceiro usa
--     get_partner_applications_by_institution, que não é tocada.
-- O shape de retorno das três funções não muda.

-- ─── Predicado compartilhado ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.matches_first_touch_attribution(
  p_user_id uuid,
  p_campaign_id uuid,
  p_channel_id uuid,
  p_unattributed boolean
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN p_unattributed IS TRUE THEN NOT EXISTS (
      SELECT 1
      FROM public.user_attribution ua
      WHERE ua.user_id = p_user_id
        AND ua.first_touch_link_id IS NOT NULL
    )
    WHEN p_campaign_id IS NULL AND p_channel_id IS NULL THEN true
    ELSE EXISTS (
      SELECT 1
      FROM public.user_attribution ua
      JOIN public.channel_links cl ON cl.id = ua.first_touch_link_id
      WHERE ua.user_id = p_user_id
        AND (p_campaign_id IS NULL OR cl.campaign_id = p_campaign_id)
        AND (p_channel_id IS NULL OR cl.channel_id = p_channel_id)
    )
  END;
$$;

COMMENT ON FUNCTION public.matches_first_touch_attribution(uuid, uuid, uuid, boolean) IS
  'TP-7: true se a pessoa casa com o filtro de campanha/divulgador pelo first-touch. Todos NULL = true.';

CREATE OR REPLACE FUNCTION public.assert_attribution_filter(
  p_campaign_id uuid,
  p_channel_id uuid,
  p_unattributed boolean
)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
BEGIN
  IF p_unattributed IS TRUE AND (p_campaign_id IS NOT NULL OR p_channel_id IS NOT NULL) THEN
    RAISE EXCEPTION 'filtro de atribuição incompatível: "sem atribuição" não combina com campanha/divulgador'
      USING ERRCODE = '22023';
  END IF;
END;
$$;

-- Só as RPCs (SECURITY DEFINER, rodando como owner) chamam os helpers.
REVOKE ALL ON FUNCTION public.matches_first_touch_attribution(uuid, uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.assert_attribution_filter(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;

-- ─── get_students_paginated ─────────────────────────────────────────────────
-- Corpo idêntico ao de produção (20260811140000), acrescido do predicado na
-- contagem e na página.

DROP FUNCTION IF EXISTS public.get_students_paginated(
  integer, integer, text, text, text, boolean, numeric, numeric, text[], text, text, text, integer, integer
);

CREATE FUNCTION public.get_students_paginated(
  p_page integer,
  p_page_size integer,
  p_filter_name text DEFAULT NULL,
  p_filter_city text DEFAULT NULL,
  p_filter_education text DEFAULT NULL,
  p_filter_is_nubo_student boolean DEFAULT NULL,
  p_filter_income_min numeric DEFAULT NULL,
  p_filter_income_max numeric DEFAULT NULL,
  p_filter_quota_types text[] DEFAULT NULL,
  p_sort_by text DEFAULT 'created_at',
  p_sort_order text DEFAULT 'desc',
  p_filter_state text DEFAULT NULL,
  p_filter_age_min integer DEFAULT NULL,
  p_filter_age_max integer DEFAULT NULL,
  p_filter_campaign_id uuid DEFAULT NULL,
  p_filter_channel_id uuid DEFAULT NULL,
  p_filter_unattributed boolean DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $function$
DECLARE
  v_offset INT;
  v_total_count BIGINT;
  v_data JSON;
  v_order_col TEXT;
  v_order_dir TEXT;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_students_paginated: acesso restrito ao backoffice'
      USING ERRCODE = '42501';
  END IF;

  PERFORM public.assert_attribution_filter(p_filter_campaign_id, p_filter_channel_id, p_filter_unattributed);

  v_offset := p_page * p_page_size;

  -- Whitelist das colunas ordenáveis. Os valores são ALIASES DE SAÍDA da
  -- subquery interna, não colunas qualificadas — é o que permite ordenar por
  -- `whatsapp`, que é computada. Qualquer valor fora da lista cai em created_at.
  v_order_col := CASE p_sort_by
    WHEN 'full_name'       THEN 'full_name'
    WHEN 'age'             THEN 'age'
    WHEN 'city'            THEN 'city'
    WHEN 'education'       THEN 'education'
    WHEN 'whatsapp'        THEN 'whatsapp'
    WHEN 'is_nubo_student' THEN 'is_nubo_student'
    WHEN 'created_at'      THEN 'created_at'
    ELSE 'created_at'
  END;

  v_order_dir := CASE WHEN lower(p_sort_order) = 'asc' THEN 'ASC' ELSE 'DESC' END;

  -- 1. Contagem total (mesmos filtros da página)
  SELECT count(DISTINCT p.id) INTO v_total_count
  FROM public.user_profiles p
  LEFT JOIN public.user_income inc ON inc.user_id = p.id
  LEFT JOIN public.user_preferences pref ON p.id = pref.user_id
  WHERE (p_filter_name IS NULL OR p.full_name ILIKE '%' || p_filter_name || '%')
    AND (p_filter_city IS NULL OR p.city ILIKE '%' || p_filter_city || '%')
    AND (p_filter_education IS NULL OR p.education ILIKE '%' || p_filter_education || '%')
    AND (p_filter_is_nubo_student IS NULL OR p.is_nubo_student = p_filter_is_nubo_student)
    AND (p_filter_income_min IS NULL OR COALESCE(inc.per_capita_income, pref.family_income_per_capita) >= p_filter_income_min)
    AND (p_filter_income_max IS NULL OR COALESCE(inc.per_capita_income, pref.family_income_per_capita) <= p_filter_income_max)
    AND (p_filter_quota_types IS NULL OR pref.quota_types && p_filter_quota_types)
    AND (p_filter_state IS NULL OR p.state = p_filter_state)
    AND (p_filter_age_min IS NULL OR p.age >= p_filter_age_min)
    AND (p_filter_age_max IS NULL OR p.age <= p_filter_age_max)
    AND public.matches_first_touch_attribution(p.id, p_filter_campaign_id, p_filter_channel_id, p_filter_unattributed);

  -- 2. Página de dados.
  --    Interna: DISTINCT ON (p.id) ORDER BY p.id  — exigência do operador.
  --    Externa: ORDER BY <coluna pedida> + LIMIT/OFFSET — a ordenação real.
  EXECUTE format($fmt$
    SELECT coalesce(json_agg(t.*), '[]'::json)
    FROM (
      SELECT *
      FROM (
        SELECT DISTINCT ON (p.id)
          p.id,
          p.full_name,
          COALESCE(p.phone, au.phone) as whatsapp,
          p.age,
          p.race,
          p.city,
          p.state,
          p.education,
          p.is_nubo_student,
          p.created_at,
          COALESCE(inc.per_capita_income, pref.family_income_per_capita) as per_capita_income,
          pref.quota_types,
          (SELECT COUNT(*) FROM public.student_applications sa WHERE sa.user_id = p.id AND sa.status = 'DRAFT') as draft_applications_count,
          (SELECT STRING_AGG(po.name, ', ') FROM public.student_applications sa JOIN public.partner_opportunities po ON po.id = sa.partner_id WHERE sa.user_id = p.id AND sa.status = 'DRAFT') as draft_applications_list,
          (SELECT COUNT(*) FROM public.student_applications sa WHERE sa.user_id = p.id AND sa.status != 'DRAFT') as completed_applications_count,
          (SELECT STRING_AGG(po.name, ', ') FROM public.student_applications sa JOIN public.partner_opportunities po ON po.id = sa.partner_id WHERE sa.user_id = p.id AND sa.status != 'DRAFT') as completed_applications_list,
          (SELECT COUNT(*) FROM public.user_opportunity_matches m WHERE m.profile_id = p.id) as total_matches,
          (SELECT STRING_AGG(v.title || ' (' || v.provider_name || ') - ' || ROUND(m.match_score) || '%%', '; ')
           FROM (SELECT unified_opportunity_id, match_score FROM public.user_opportunity_matches WHERE profile_id = p.id ORDER BY match_score DESC LIMIT 10) m
           JOIN public.v_unified_opportunities v ON v.unified_id = m.unified_opportunity_id) as matches_list,
          (SELECT STRING_AGG(
            COALESCE(
              v_c.title || ' (' || v_c.provider_name || ')',
              v_p.title || ' (' || v_p.provider_name || ')',
              inst.name
            ), '; ')
           FROM public.user_favorites f
           LEFT JOIN public.v_unified_opportunities v_c ON v_c.unified_id = 'mec_' || f.course_id
           LEFT JOIN public.v_unified_opportunities v_p ON v_p.unified_id = 'partner_' || f.partner_opportunities_id
           LEFT JOIN public.institutions inst ON inst.id = f.institution_id
           WHERE f.user_id = p.id) as favorites_list
        FROM public.user_profiles p
        LEFT JOIN auth.users au ON au.id = p.id
        LEFT JOIN public.user_income inc ON inc.user_id = p.id
        LEFT JOIN public.user_preferences pref ON pref.user_id = p.id
        WHERE
          ($1 IS NULL OR p.full_name ILIKE '%%' || $1 || '%%')
          AND ($2 IS NULL OR p.city ILIKE '%%' || $2 || '%%')
          AND ($3 IS NULL OR p.education ILIKE '%%' || $3 || '%%')
          AND ($4 IS NULL OR p.is_nubo_student = $4)
          AND ($5 IS NULL OR COALESCE(inc.per_capita_income, pref.family_income_per_capita) >= $5)
          AND ($6 IS NULL OR COALESCE(inc.per_capita_income, pref.family_income_per_capita) <= $6)
          AND ($7 IS NULL OR pref.quota_types && $7)
          AND ($10 IS NULL OR p.state = $10)
          AND ($11 IS NULL OR p.age >= $11)
          AND ($12 IS NULL OR p.age <= $12)
          AND public.matches_first_touch_attribution(p.id, $13, $14, $15)
        ORDER BY p.id
      ) d
      ORDER BY %I %s NULLS LAST, d.id
      LIMIT $8
      OFFSET $9
    ) t
  $fmt$, v_order_col, v_order_dir)
  USING
    p_filter_name,
    p_filter_city,
    p_filter_education,
    p_filter_is_nubo_student,
    p_filter_income_min,
    p_filter_income_max,
    p_filter_quota_types,
    p_page_size,
    v_offset,
    p_filter_state,
    p_filter_age_min,
    p_filter_age_max,
    p_filter_campaign_id,
    p_filter_channel_id,
    p_filter_unattributed
  INTO v_data;

  RETURN json_build_object('data', v_data, 'count', v_total_count);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_students_paginated(
  integer, integer, text, text, text, boolean, numeric, numeric, text[], text, text, text, integer, integer, uuid, uuid, boolean
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_students_paginated(
  integer, integer, text, text, text, boolean, numeric, numeric, text[], text, text, text, integer, integer, uuid, uuid, boolean
) TO authenticated, service_role;

-- ─── get_student_stats ──────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.get_student_stats(
  text, text, text, boolean, numeric, numeric, text[], text, integer, integer
);

CREATE FUNCTION public.get_student_stats(
  filter_full_name text DEFAULT NULL,
  filter_city text DEFAULT NULL,
  filter_education text DEFAULT NULL,
  filter_is_nubo_student boolean DEFAULT NULL,
  filter_income_min numeric DEFAULT NULL,
  filter_income_max numeric DEFAULT NULL,
  filter_quota_types text[] DEFAULT NULL,
  filter_state text DEFAULT NULL,
  filter_age_min integer DEFAULT NULL,
  filter_age_max integer DEFAULT NULL,
  p_filter_campaign_id uuid DEFAULT NULL,
  p_filter_channel_id uuid DEFAULT NULL,
  p_filter_unattributed boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_total integer;
  v_cities integer;
  v_states integer;
  v_avg_age numeric;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_student_stats: acesso restrito ao backoffice'
      USING ERRCODE = '42501';
  END IF;

  PERFORM public.assert_attribution_filter(p_filter_campaign_id, p_filter_channel_id, p_filter_unattributed);

  -- Mesmos predicados de get_students_paginated. Strings vazias continuam
  -- valendo como "sem filtro", como na versão anterior.
  WITH filtered AS (
    SELECT DISTINCT p.id, p.city, p.state, p.age
    FROM public.user_profiles p
    LEFT JOIN public.user_income inc ON inc.user_id = p.id
    LEFT JOIN public.user_preferences pref ON pref.user_id = p.id
    WHERE (NULLIF(filter_full_name, '') IS NULL OR p.full_name ILIKE '%' || filter_full_name || '%')
      AND (NULLIF(filter_city, '') IS NULL OR p.city ILIKE '%' || filter_city || '%')
      AND (NULLIF(filter_education, '') IS NULL OR p.education ILIKE '%' || filter_education || '%')
      AND (filter_is_nubo_student IS NULL OR p.is_nubo_student = filter_is_nubo_student)
      AND (filter_income_min IS NULL OR COALESCE(inc.per_capita_income, pref.family_income_per_capita) >= filter_income_min)
      AND (filter_income_max IS NULL OR COALESCE(inc.per_capita_income, pref.family_income_per_capita) <= filter_income_max)
      AND (filter_quota_types IS NULL OR pref.quota_types && filter_quota_types)
      AND (filter_state IS NULL OR p.state = filter_state)
      AND (filter_age_min IS NULL OR p.age >= filter_age_min)
      AND (filter_age_max IS NULL OR p.age <= filter_age_max)
      AND public.matches_first_touch_attribution(p.id, p_filter_campaign_id, p_filter_channel_id, p_filter_unattributed)
  )
  SELECT
    count(*),
    count(DISTINCT f.city),
    count(DISTINCT f.state),
    COALESCE(avg(f.age) FILTER (WHERE f.age > 0 AND f.age < 120), 0)
  INTO v_total, v_cities, v_states, v_avg_age
  FROM filtered f;

  RETURN jsonb_build_object(
    'total_students', v_total,
    'total_cities', v_cities,
    'total_states', v_states,
    'average_age', round(v_avg_age, 1)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_student_stats(
  text, text, text, boolean, numeric, numeric, text[], text, integer, integer, uuid, uuid, boolean
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_student_stats(
  text, text, text, boolean, numeric, numeric, text[], text, integer, integer, uuid, uuid, boolean
) TO authenticated, service_role;

-- ─── get_student_applications_with_details ──────────────────────────────────
-- Recorte pelo first-touch do ALUNO (sa.user_id), independentemente da data
-- da inscrição. Shape e ordenação inalterados — futuros consumidores (ex.:
-- modal de atividade do TP-4) devem acrescentar parâmetros ao FIM, com DEFAULT.

DROP FUNCTION IF EXISTS public.get_student_applications_with_details(uuid);

CREATE FUNCTION public.get_student_applications_with_details(
  p_partner_id uuid DEFAULT NULL,
  p_filter_campaign_id uuid DEFAULT NULL,
  p_filter_channel_id uuid DEFAULT NULL,
  p_filter_unattributed boolean DEFAULT NULL
)
RETURNS TABLE(
  id uuid,
  user_id uuid,
  partner_id uuid,
  partner_name text,
  institution_id uuid,
  institution_name text,
  full_name text,
  phone text,
  status text,
  answers jsonb,
  created_at timestamp with time zone,
  eligibility_results jsonb,
  phase_id uuid,
  race text,
  family_income_per_capita numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $function$
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_student_applications_with_details: acesso restrito ao backoffice'
      USING ERRCODE = '42501';
  END IF;

  PERFORM public.assert_attribution_filter(p_filter_campaign_id, p_filter_channel_id, p_filter_unattributed);

  RETURN QUERY
  SELECT
    sa.id,
    sa.user_id,
    sa.partner_id,
    po.name AS partner_name,
    po.institution_id,
    inst.name AS institution_name,
    up.full_name,
    u.phone,
    sa.status,
    sa.answers,
    sa.created_at,
    sa.eligibility_results,
    sa.phase_id,
    up.race,
    ui.per_capita_income AS family_income_per_capita
  FROM public.student_applications sa
  LEFT JOIN public.user_profiles up ON sa.user_id = up.id
  LEFT JOIN auth.users u ON sa.user_id = u.id
  LEFT JOIN public.partner_opportunities po ON sa.partner_id = po.id
  LEFT JOIN public.institutions inst ON po.institution_id = inst.id
  LEFT JOIN public.user_income ui ON sa.user_id = ui.user_id
  WHERE (p_partner_id IS NULL OR sa.partner_id = p_partner_id)
    AND public.matches_first_touch_attribution(sa.user_id, p_filter_campaign_id, p_filter_channel_id, p_filter_unattributed)
  ORDER BY sa.created_at DESC;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_student_applications_with_details(uuid, uuid, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_student_applications_with_details(uuid, uuid, uuid, boolean) TO authenticated, service_role;
