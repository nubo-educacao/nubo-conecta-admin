-- fix_partner_applications_rpc_sources.sql
-- =========================================
-- Fix get_partner_applications_by_institution to read from the correct sources:
--   * eligibility_results lives in student_applications (populated per application),
--     NOT in user_profiles (which is null/missing for most students).
--   * full_name lives in the application's answers JSON ("Nome" / "full_name"),
--     since most students have no user_profiles row.
-- This is why the partner portal "Elegibilidade" and "Nome" columns were blank.

CREATE OR REPLACE FUNCTION "public"."get_partner_applications_by_institution"(p_institution_id uuid DEFAULT NULL::uuid)
RETURNS TABLE(
    id uuid,
    user_id uuid,
    partner_id uuid,
    partner_name text,
    full_name text,
    phone text,
    status text,
    answers jsonb,
    eligibility_results jsonb,
    created_at timestamp with time zone
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  SELECT
    sa.id,
    sa.user_id,
    sa.partner_id,
    po.name AS partner_name,
    COALESCE(
      NULLIF(TRIM(up.full_name), ''),
      NULLIF(TRIM(sa.answers->>'Nome'), ''),
      NULLIF(TRIM(sa.answers->>'full_name'), '')
    ) AS full_name,
    u.phone,
    sa.status,
    sa.answers,
    COALESCE(sa.eligibility_results, up.eligibility_results) AS eligibility_results,
    sa.created_at
  FROM
    public.student_applications sa
  LEFT JOIN
    public.partner_opportunities po ON sa.partner_id = po.id
  LEFT JOIN
    public.user_profiles up ON sa.user_id = up.id
  LEFT JOIN
    auth.users u ON sa.user_id = u.id
  WHERE
    (p_institution_id IS NULL OR po.institution_id = p_institution_id)
  ORDER BY
    sa.created_at DESC;
END;
$function$;
