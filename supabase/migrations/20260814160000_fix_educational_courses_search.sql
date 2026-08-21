-- O explorer de cursos foi publicado dependendo de search_opportunities(),
-- função que não existe no nubo-hub. Mantém o contrato da RPC e faz a busca
-- acento-insensível diretamente no catálogo normalizado.

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

  WITH filtered AS (
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
        OR public.unaccent(c.course_name) ILIKE '%' || public.unaccent(p_search) || '%'
        OR public.unaccent(i.name) ILIKE '%' || public.unaccent(p_search) || '%'
        OR public.unaccent(cp.name) ILIKE '%' || public.unaccent(p_search) || '%'
        OR c.course_code ILIKE '%' || p_search || '%'
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
    'data', coalesce((
      SELECT jsonb_agg(to_jsonb(paged) ORDER BY course_name, institution_name)
      FROM paged
    ), '[]'::jsonb),
    'total', (SELECT count(*) FROM filtered)
  )
  INTO v_result;

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_admin_educational_courses(
  integer, integer, text, uuid, uuid, text, integer, text
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.get_admin_educational_courses(
  integer, integer, text, uuid, uuid, text, integer, text
) TO authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'partner') THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.get_admin_educational_courses(integer, integer, text, uuid, uuid, text, integer, text) FROM partner';
  END IF;
END;
$$;
