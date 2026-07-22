-- Migration: Extend candidaturas RPCs with institution (Parceiro) join.
-- Per peer-review guidance (Fase 3.5): never edit an already-applied migration file.
-- This migration supersedes the RPC bodies defined in
-- 20260713162300_update_rpcs_for_phase_id.sql via DROP + CREATE at migration-run
-- time, without modifying that historical file.
--
-- Adds institution_id/institution_name (public.institutions, via
-- partner_opportunities.institution_id) to both RPCs, enabling the unified
-- Parceiro/Oportunidade/Fase/Status filter set (ADR-0014) to distinguish the
-- real partner institution from the opportunity.

DROP FUNCTION IF EXISTS "public"."get_partner_applications_by_institution"(uuid);
DROP FUNCTION IF EXISTS public.get_student_applications_with_details(uuid);

-- 1. get_partner_applications_by_institution
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


-- 2. get_student_applications_with_details
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
