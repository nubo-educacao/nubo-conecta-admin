-- TP-4 4a (ordenação) + TP-6 task 0 (hardening) — card 1a658f84
--
-- PROBLEMA 1 — a ordenação nunca funcionou para nenhuma coluna.
--   O corpo anterior fazia:
--       SELECT DISTINCT ON (p.id) ... ORDER BY p.id, <col> <dir> LIMIT/OFFSET
--   DISTINCT ON exige que a expressão distinta LIDERE o ORDER BY. Como p.id é
--   único, <col> só desempatava linhas de mesmo id — que nunca existem. Ou seja:
--   o sort do front chegava na função, era interpolado, e não tinha efeito algum.
--   O sintoma relatado ("ordenação não funciona") não era específico de `age`.
--
-- PROBLEMA 2 — o mapa de colunas cobria 5 das 7 colunas clicáveis da UI.
--   src/components/students/StudentTable.tsx emite: full_name, age, city,
--   education, whatsapp, is_nubo_student, created_at.
--   O CASE mapeava tudo menos `age` e `whatsapp`, que caíam no ELSE (created_at).
--   `whatsapp` é coluna computada (COALESCE(p.phone, au.phone)) e por isso não
--   tinha como ser referenciada no ORDER BY interno.
--
-- CORREÇÃO
--   O DISTINCT ON fica isolado numa subquery interna, ordenada por p.id como o
--   operador exige. O ORDER BY real e o LIMIT/OFFSET passam para a subquery
--   externa, aplicados sobre os ALIASES DE SAÍDA — o que resolve os dois
--   problemas de uma vez e torna ordenável também a coluna computada.
--   Desempate por `id` mantém a paginação estável (sem linha repetida ou sumida
--   entre páginas quando há empate no campo ordenado).
--
-- PROBLEMA 3 (segurança) — a função é SECURITY DEFINER, não tinha guard de
--   autorização, não fixava search_path e tinha EXECUTE para PUBLIC/anon.
--   Ela devolve nome, whatsapp, idade, cidade, renda per capita e RAÇA de todos
--   os perfis. `race` é dado pessoal sensível (LGPD, Art. 5º, II) e a anon key
--   é pública — está no bundle do front. Qualquer pessoa com a chave podia
--   paginar a base inteira de estudantes.
--
--   Guard: public.is_backoffice_admin(), o mesmo idioma já usado nas policies de
--   partner_institutions, partner_opportunities e external_redirect_clicks.
--   Consumidores verificados (grep em src/): apenas services/studentsService.ts,
--   usado por pages/Students.tsx e components/students/StudentExportButton.tsx.
--   Ambos são telas de backoffice. Nenhum consumo pelo portal de parceiro.
--
-- Assinatura idêntica à anterior — CREATE OR REPLACE substitui de fato, sem
-- criar overload. (Assinatura diferente criaria uma SEGUNDA função e a antiga
-- continuaria atendendo as chamadas.)

CREATE OR REPLACE FUNCTION public.get_students_paginated(
  p_page INT,
  p_page_size INT,
  p_filter_name TEXT DEFAULT NULL,
  p_filter_city TEXT DEFAULT NULL,
  p_filter_education TEXT DEFAULT NULL,
  p_filter_is_nubo_student BOOLEAN DEFAULT NULL,
  p_filter_income_min NUMERIC DEFAULT NULL,
  p_filter_income_max NUMERIC DEFAULT NULL,
  p_filter_quota_types TEXT[] DEFAULT NULL,
  p_sort_by TEXT DEFAULT 'created_at',
  p_sort_order TEXT DEFAULT 'desc',
  p_filter_state TEXT DEFAULT NULL,
  p_filter_age_min INT DEFAULT NULL,
  p_filter_age_max INT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
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

  -- 1. Contagem total (inalterada — mesmos filtros, mesma semântica)
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
    AND (p_filter_age_max IS NULL OR p.age <= p_filter_age_max);

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
    p_filter_age_max
  INTO v_data;

  RETURN json_build_object('data', v_data, 'count', v_total_count);
END; $$;

-- ACL mínima. Admins do backoffice são usuários autenticados; o guard acima é
-- que separa admin de usuário comum. service_role ignora ACL e segue funcionando.
-- O GRANT para `partner` existente em produção é removido: nenhuma tela do portal
-- de parceiro chama esta função (grep em src/ confirmou consumidor único).
-- REVOKE nomeando um role inexistente aborta a migration inteira. Prod tem o role
-- `partner`; dev está atrás e pode não ter. Por isso o revoke é feito por role
-- existente, não numa lista fixa.
DO $acl$
DECLARE
  v_sig CONSTANT TEXT :=
    'public.get_students_paginated(INT, INT, TEXT, TEXT, TEXT, BOOLEAN, NUMERIC, NUMERIC, TEXT[], TEXT, TEXT, TEXT, INT, INT)';
  v_role TEXT;
BEGIN
  EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', v_sig);

  FOREACH v_role IN ARRAY ARRAY['anon', 'partner'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
      EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM %I', v_sig, v_role);
    END IF;
  END LOOP;

  EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', v_sig);
END
$acl$;
