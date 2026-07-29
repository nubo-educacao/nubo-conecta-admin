CREATE OR REPLACE FUNCTION public.get_student_matches_admin(p_profile_id UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_total_count BIGINT;
  v_matches JSON;
BEGIN
  SELECT count(*) INTO v_total_count 
  FROM public.user_opportunity_matches 
  WHERE profile_id = p_profile_id;

  SELECT coalesce(json_agg(t.*), '[]'::json) INTO v_matches
  FROM (
    SELECT 
      m.unified_opportunity_id,
      m.match_score,
      COALESCE(v.title, 'Oportunidade') as title,
      COALESCE(v.provider_name, '-') as provider_name
    FROM public.user_opportunity_matches m
    LEFT JOIN public.v_unified_opportunities v ON v.unified_id = m.unified_opportunity_id
    WHERE m.profile_id = p_profile_id
    ORDER BY m.match_score DESC
    LIMIT 20
  ) t;

  RETURN json_build_object('count', v_total_count, 'matches', v_matches);
END;
$$;
