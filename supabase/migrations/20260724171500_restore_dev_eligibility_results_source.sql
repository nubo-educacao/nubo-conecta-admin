-- 20260724171500_restore_dev_eligibility_results_source.sql
--
-- 20260723193000 era um hotfix ESPECÍFICO de prod (eligibility_results em
-- student_applications lá) e foi aplicado sem querer no banco dev também via
-- db push, quebrando de novo get_student_applications_with_details /
-- get_partner_applications_by_institution no dev — em dev essa coluna vive em
-- user_profiles, não em student_applications (confirmado antes em
-- 20260722180000, que já lia up.eligibility_results corretamente).
--
-- Restaura a leitura via up.eligibility_results (fonte correta no dev).

DROP FUNCTION IF EXISTS "public"."get_partner_applications_by_institution"(uuid);
DROP FUNCTION IF EXISTS public.get_student_applications_with_details(uuid);

CREATE OR REPLACE FUNCTION "public"."get_partner_applications_by_institution"(p_institution_id uuid DEFAULT NULL::uuid)
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
    eligibility_results jsonb,
    created_at timestamp with time zone,
    phase_id uuid
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
    po.institution_id,
    inst.name AS institution_name,
    up.full_name,
    u.phone,
    sa.status,
    sa.answers,
    up.eligibility_results,
    sa.created_at,
    sa.phase_id
  FROM
    public.student_applications sa
  LEFT JOIN
    public.partner_opportunities po ON sa.partner_id = po.id
  LEFT JOIN
    public.institutions inst ON po.institution_id = inst.id
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

CREATE OR REPLACE FUNCTION public.get_student_applications_with_details(p_partner_id uuid DEFAULT NULL::uuid)
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
    phase_id uuid
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
 AS $function$
BEGIN
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
        up.eligibility_results,
        sa.phase_id
    FROM
        public.student_applications sa
    LEFT JOIN
        public.user_profiles up ON sa.user_id = up.id
    LEFT JOIN
        auth.users u ON sa.user_id = u.id
    LEFT JOIN
        public.partner_opportunities po ON sa.partner_id = po.id
    LEFT JOIN
        public.institutions inst ON po.institution_id = inst.id
    WHERE
        (p_partner_id IS NULL OR sa.partner_id = p_partner_id)
    ORDER BY
        sa.created_at DESC;
END;
$function$;
