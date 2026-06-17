-- add_get_partner_applications_by_institution.sql
-- ================================================
-- New RPC to fetch student applications for a partner institution.
-- Takes institution_id (from partner_users.partner_id), finds all partner_opportunities
-- for that institution, then returns all student_applications for those opportunities.

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
    up.full_name,
    u.phone,
    sa.status,
    sa.answers,
    up.eligibility_results,
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
