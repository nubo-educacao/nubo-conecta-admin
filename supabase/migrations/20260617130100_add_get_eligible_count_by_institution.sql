-- add_get_eligible_count_by_institution.sql
-- ==========================================
-- New RPC to count eligible students for a partner institution.
-- Takes institution_id, finds all partner_opportunities for that institution,
-- then counts eligible students who have applied to those opportunities.

CREATE OR REPLACE FUNCTION "public"."get_eligible_count_by_institution"(p_institution_id uuid)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT COALESCE(COUNT(DISTINCT sa.user_id), 0)
  FROM public.student_applications sa
  JOIN public.partner_opportunities po ON sa.partner_id = po.id
  JOIN public.user_profiles up ON sa.user_id = up.id
  WHERE po.institution_id = p_institution_id
    AND (up.eligibility_results ->> 'eligible')::boolean = true;
$function$;
