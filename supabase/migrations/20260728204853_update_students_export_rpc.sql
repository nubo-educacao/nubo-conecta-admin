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
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE 
  v_offset INT; 
  v_total_count BIGINT; 
  v_data JSON;
  v_order_clause TEXT;
BEGIN
  v_offset := p_page * p_page_size;

  -- Map sort_by to actual columns
  v_order_clause := CASE p_sort_by
    WHEN 'full_name' THEN 'p.full_name'
    WHEN 'city' THEN 'p.city'
    WHEN 'education' THEN 'p.education'
    WHEN 'is_nubo_student' THEN 'p.is_nubo_student'
    WHEN 'created_at' THEN 'p.created_at'
    ELSE 'p.created_at'
  END;

  -- 1. Calculate Total Count
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

  -- 2. Fetch Data with dynamic sort
  EXECUTE format('
    SELECT coalesce(json_agg(t.*), ''[]''::json)
    FROM (
        SELECT DISTINCT ON (p.id)
          p.id,
          p.full_name,
          p.phone as whatsapp,
          p.age,
          p.race,
          p.city,
          p.state,
          p.education,
          p.is_nubo_student,
          p.created_at,
          COALESCE(inc.per_capita_income, pref.family_income_per_capita) as per_capita_income,
          pref.quota_types,
          (SELECT COUNT(*) FROM public.student_applications sa WHERE sa.user_id = p.id AND sa.status = ''DRAFT'') as draft_applications_count,
          (SELECT STRING_AGG(po.name, '', '') FROM public.student_applications sa JOIN public.partner_opportunities po ON po.id = sa.partner_id WHERE sa.user_id = p.id AND sa.status = ''DRAFT'') as draft_applications_list,
          (SELECT COUNT(*) FROM public.student_applications sa WHERE sa.user_id = p.id AND sa.status != ''DRAFT'') as completed_applications_count,
          (SELECT STRING_AGG(po.name, '', '') FROM public.student_applications sa JOIN public.partner_opportunities po ON po.id = sa.partner_id WHERE sa.user_id = p.id AND sa.status != ''DRAFT'') as completed_applications_list,
          (SELECT COUNT(*) FROM public.user_opportunity_matches m WHERE m.profile_id = p.id) as total_matches,
          (SELECT STRING_AGG(v.title || '' ('' || v.provider_name || '') - '' || ROUND(m.match_score) || ''%%'', ''; '') 
           FROM (SELECT unified_opportunity_id, match_score FROM public.user_opportunity_matches WHERE profile_id = p.id ORDER BY match_score DESC LIMIT 10) m
           JOIN public.v_unified_opportunities v ON v.unified_id = m.unified_opportunity_id) as matches_list,
          (SELECT STRING_AGG(
            COALESCE(
              v_c.title || '' ('' || v_c.provider_name || '')'',
              v_p.title || '' ('' || v_p.provider_name || '')'',
              inst.name
            ), ''; '')
           FROM public.user_favorites f
           LEFT JOIN public.v_unified_opportunities v_c ON v_c.unified_id = ''mec_'' || f.course_id
           LEFT JOIN public.v_unified_opportunities v_p ON v_p.unified_id = ''partner_'' || f.partner_opportunities_id
           LEFT JOIN public.institutions inst ON inst.id = f.institution_id
           WHERE f.user_id = p.id) as favorites_list
        FROM public.user_profiles p
        LEFT JOIN public.user_income inc ON inc.user_id = p.id
        LEFT JOIN public.user_preferences pref ON pref.user_id = p.id
        WHERE
          ($1 IS NULL OR p.full_name ILIKE ''%%'' || $1 || ''%%'')
          AND ($2 IS NULL OR p.city ILIKE ''%%'' || $2 || ''%%'')
          AND ($3 IS NULL OR p.education ILIKE ''%%'' || $3 || ''%%'')
          AND ($4 IS NULL OR p.is_nubo_student = $4)
          AND ($5 IS NULL OR COALESCE(inc.per_capita_income, pref.family_income_per_capita) >= $5)
          AND ($6 IS NULL OR COALESCE(inc.per_capita_income, pref.family_income_per_capita) <= $6)
          AND ($7 IS NULL OR pref.quota_types && $7)
          AND ($10 IS NULL OR p.state = $10)
          AND ($11 IS NULL OR p.age >= $11)
          AND ($12 IS NULL OR p.age <= $12)
        ORDER BY p.id, %s %s
        LIMIT $8
        OFFSET $9
    ) t',
    v_order_clause,
    CASE WHEN lower(p_sort_order) = 'asc' THEN 'ASC' ELSE 'DESC' END
  )
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
