CREATE OR REPLACE FUNCTION public.get_student_applications_with_details(p_partner_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, user_id uuid, partner_id uuid, partner_name text, full_name text, phone text, status text, answers jsonb, created_at timestamp with time zone, eligibility_results jsonb, eligibility_score numeric, complex_eligibility_report jsonb)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        sa.id,
        sa.user_id,
        sa.partner_id,
        p.name AS partner_name,
        up.full_name,
        u.phone,
        sa.status,
        sa.answers,
        sa.created_at,
        up.eligibility_results,
        sa.eligibility_score,
        sa.complex_eligibility_report
    FROM public.student_applications sa
    LEFT JOIN public.user_profiles up ON sa.user_id = up.id
    LEFT JOIN auth.users u ON sa.user_id = u.id
    LEFT JOIN public.partner_opportunities p ON sa.partner_id = p.id
    WHERE (p_partner_id IS NULL OR sa.partner_id = p_partner_id)
    ORDER BY sa.created_at DESC;
END;
$function$;
