-- Admin-only, paginated data contracts for the educational catalog explorers.

CREATE OR REPLACE FUNCTION public.get_admin_educational_institutions(
  p_page integer DEFAULT 0,
  p_page_size integer DEFAULT 20,
  p_search text DEFAULT NULL,
  p_state text DEFAULT NULL,
  p_source text DEFAULT 'all'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_admin_educational_institutions: acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;

  IF p_page < 0 OR p_page_size < 1 OR p_page_size > 100 THEN
    RAISE EXCEPTION 'get_admin_educational_institutions: paginação inválida' USING ERRCODE = '22023';
  END IF;

  WITH campus_rollup AS (
    SELECT
      cp.institution_id,
      min(cp.state) FILTER (WHERE cp.state IS NOT NULL) AS campus_state,
      count(DISTINCT cp.id)::integer AS campus_count,
      count(DISTINCT c.id)::integer AS course_count
    FROM public.campus cp
    LEFT JOIN public.courses c ON c.campus_id = cp.id
    GROUP BY cp.institution_id
  ),
  filtered AS (
    SELECT
      i.id,
      i.name,
      i.external_code,
      i.is_partner,
      coalesce(ie.state, cr.campus_state) AS state,
      ie.igc,
      coalesce(cr.campus_count, 0) AS campus_count,
      coalesce(cr.course_count, 0) AS course_count,
      coalesce(ui.open_opportunities_count, 0)::integer AS open_opportunities_count
    FROM public.institutions i
    LEFT JOIN public.institutions_info_emec ie ON ie.institution_id = i.id
    LEFT JOIN campus_rollup cr ON cr.institution_id = i.id
    LEFT JOIN public.v_unified_institutions ui ON ui.id = i.id
    WHERE
      (p_search IS NULL OR i.name ILIKE '%' || p_search || '%' OR i.external_code ILIKE '%' || p_search || '%')
      AND (
        p_state IS NULL
        OR ie.state = p_state
        OR EXISTS (
          SELECT 1 FROM public.campus state_campus
          WHERE state_campus.institution_id = i.id AND state_campus.state = p_state
        )
      )
      AND (
        p_source = 'all'
        OR (p_source = 'partner' AND i.is_partner)
        OR (p_source = 'mec' AND ie.institution_id IS NOT NULL)
      )
  ),
  paged AS (
    SELECT *
    FROM filtered
    ORDER BY name, id
    LIMIT p_page_size
    OFFSET p_page * p_page_size
  )
  SELECT jsonb_build_object(
    'data', coalesce((SELECT jsonb_agg(to_jsonb(paged) ORDER BY name) FROM paged), '[]'::jsonb),
    'total', (SELECT count(*) FROM filtered)
  )
  INTO v_result;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_admin_institution_campuses(
  p_institution_id uuid,
  p_page integer DEFAULT 0,
  p_page_size integer DEFAULT 15,
  p_search text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_admin_institution_campuses: acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;

  IF p_page < 0 OR p_page_size < 1 OR p_page_size > 100 THEN
    RAISE EXCEPTION 'get_admin_institution_campuses: paginação inválida' USING ERRCODE = '22023';
  END IF;

  WITH course_rollup AS (
    SELECT
      c.campus_id,
      count(DISTINCT c.id)::integer AS course_count,
      count(o.id)::integer AS opportunity_count
    FROM public.courses c
    LEFT JOIN public.opportunities o ON o.course_id = c.id
    GROUP BY c.campus_id
  ),
  filtered AS (
    SELECT
      cp.id,
      cp.name,
      cp.external_code,
      cp.city,
      cp.state,
      coalesce(cr.course_count, 0) AS course_count,
      coalesce(cr.opportunity_count, 0) AS opportunity_count
    FROM public.campus cp
    LEFT JOIN course_rollup cr ON cr.campus_id = cp.id
    WHERE cp.institution_id = p_institution_id
      AND (
        p_search IS NULL
        OR cp.name ILIKE '%' || p_search || '%'
        OR cp.city ILIKE '%' || p_search || '%'
      )
  ),
  paged AS (
    SELECT * FROM filtered
    ORDER BY name, id
    LIMIT p_page_size
    OFFSET p_page * p_page_size
  )
  SELECT jsonb_build_object(
    'data', coalesce((SELECT jsonb_agg(to_jsonb(paged) ORDER BY name) FROM paged), '[]'::jsonb),
    'total', (SELECT count(*) FROM filtered)
  )
  INTO v_result;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_admin_educational_filter_options()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_admin_educational_filter_options: acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'institutions', coalesce((
      SELECT jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name) ORDER BY i.name)
      FROM public.institutions i
    ), '[]'::jsonb),
    'degrees', coalesce((
      SELECT jsonb_agg(degree_type ORDER BY degree_type)
      FROM (SELECT DISTINCT c.degree_type FROM public.courses c WHERE c.degree_type IS NOT NULL) degrees
    ), '[]'::jsonb),
    'years', coalesce((
      SELECT jsonb_agg(year ORDER BY year DESC)
      FROM (SELECT DISTINCT o.year FROM public.opportunities o WHERE o.year IS NOT NULL) years
    ), '[]'::jsonb),
    'states', coalesce((
      SELECT jsonb_agg(state ORDER BY state)
      FROM (
        SELECT ie.state FROM public.institutions_info_emec ie WHERE ie.state IS NOT NULL
        UNION
        SELECT cp.state FROM public.campus cp WHERE cp.state IS NOT NULL
      ) states
    ), '[]'::jsonb)
  )
  INTO v_result;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_admin_educational_campus_options(
  p_institution_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_admin_educational_campus_options: acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(options) ORDER BY options.name), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT cp.id, cp.name, cp.city, cp.state
    FROM public.campus cp
    WHERE cp.institution_id = p_institution_id
    ORDER BY cp.name
    LIMIT 300
  ) options;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_admin_educational_courses(
  p_page integer DEFAULT 0,
  p_page_size integer DEFAULT 20,
  p_search text DEFAULT NULL,
  p_institution_id uuid DEFAULT NULL,
  p_campus_id uuid DEFAULT NULL,
  p_degree text DEFAULT NULL,
  p_year integer DEFAULT NULL,
  p_opportunity_type text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_admin_educational_courses: acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;

  IF p_page < 0 OR p_page_size < 1 OR p_page_size > 100 THEN
    RAISE EXCEPTION 'get_admin_educational_courses: paginação inválida' USING ERRCODE = '22023';
  END IF;

  WITH matched_opportunities AS MATERIALIZED (
    SELECT replace(found.unified_id, 'mec_', '')::uuid AS opportunity_id
    FROM public.search_opportunities(p_search) found
    WHERE p_search IS NOT NULL
      AND found.unified_id ~ '^mec_[0-9a-fA-F-]{36}$'
  ),
  filtered AS (
    SELECT
      c.id,
      c.course_name,
      c.course_code,
      c.degree_type,
      cp.id AS campus_id,
      cp.name AS campus_name,
      i.id AS institution_id,
      i.name AS institution_name,
      cp.city,
      cp.state,
      count(DISTINCT o.id)::integer AS opportunity_count
    FROM public.courses c
    JOIN public.campus cp ON cp.id = c.campus_id
    JOIN public.institutions i ON i.id = cp.institution_id
    JOIN public.opportunities o ON o.course_id = c.id
    WHERE
      (p_institution_id IS NULL OR i.id = p_institution_id)
      AND (p_campus_id IS NULL OR cp.id = p_campus_id)
      AND (p_degree IS NULL OR c.degree_type = p_degree)
      AND (p_year IS NULL OR o.year = p_year)
      AND (p_opportunity_type IS NULL OR lower(o.opportunity_type) = lower(p_opportunity_type))
      AND (
        p_search IS NULL
        OR EXISTS (
          SELECT 1 FROM matched_opportunities matched
          WHERE matched.opportunity_id = o.id
        )
      )
    GROUP BY c.id, c.course_name, c.course_code, c.degree_type,
      cp.id, cp.name, i.id, i.name, cp.city, cp.state
  ),
  paged AS (
    SELECT * FROM filtered
    ORDER BY course_name, institution_name, campus_name, id
    LIMIT p_page_size
    OFFSET p_page * p_page_size
  )
  SELECT jsonb_build_object(
    'data', coalesce((SELECT jsonb_agg(to_jsonb(paged) ORDER BY course_name, institution_name) FROM paged), '[]'::jsonb),
    'total', (SELECT count(*) FROM filtered)
  )
  INTO v_result;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_admin_course_opportunities(
  p_course_id uuid,
  p_year integer DEFAULT NULL,
  p_opportunity_type text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_admin_course_opportunities: acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(filtered) ORDER BY filtered.year DESC, filtered.semester, filtered.opportunity_type, filtered.shift), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT
      o.id,
      o.shift,
      o.scholarship_type,
      o.concurrency_type,
      o.concurrency_tags,
      o.scholarship_tags,
      o.cutoff_score,
      o.year,
      o.semester,
      o.opportunity_type
    FROM public.opportunities o
    WHERE o.course_id = p_course_id
      AND (p_year IS NULL OR o.year = p_year)
      AND (p_opportunity_type IS NULL OR lower(o.opportunity_type) = lower(p_opportunity_type))
    ORDER BY o.year DESC, o.semester, o.opportunity_type, o.shift
    LIMIT 500
  ) filtered;

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_admin_educational_institutions(integer, integer, text, text, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.get_admin_institution_campuses(uuid, integer, integer, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.get_admin_educational_filter_options() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.get_admin_educational_campus_options(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.get_admin_educational_courses(integer, integer, text, uuid, uuid, text, integer, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.get_admin_course_opportunities(uuid, integer, text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.get_admin_educational_institutions(integer, integer, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_institution_campuses(uuid, integer, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_educational_filter_options() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_educational_campus_options(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_educational_courses(integer, integer, text, uuid, uuid, text, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_course_opportunities(uuid, integer, text) TO authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'partner') THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.get_admin_educational_institutions(integer, integer, text, text, text) FROM partner';
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.get_admin_institution_campuses(uuid, integer, integer, text) FROM partner';
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.get_admin_educational_filter_options() FROM partner';
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.get_admin_educational_campus_options(uuid) FROM partner';
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.get_admin_educational_courses(integer, integer, text, uuid, uuid, text, integer, text) FROM partner';
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.get_admin_course_opportunities(uuid, integer, text) FROM partner';
  END IF;
END;
$$;
