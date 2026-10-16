-- Autorização dentro das RPCs legadas que devolvem dados pessoais (Sprint 9.0, TP-2 / PR #66).
--
-- 20261015204010 tirou EXECUTE de PUBLIC/anon, mas as duas funções abaixo são
-- SECURITY DEFINER sem checagem interna: qualquer JWT autenticado do mesmo
-- projeto (inclusive um aluno do nubo-conecta-app) lia nome e telefone.
--
-- * get_admin_funnel_users(): lista global de usuários (export do /b2b-dashboard).
--   Só backoffice, permissão 'Parceiros' ou service_role. Sem ramo de parceiro:
--   o resultado não é recortado por instituição.
-- * get_partner_applications_by_institution(uuid): portal do parceiro. Mantém o
--   membro de partners_users da própria instituição; a consulta sem instituição
--   (todas as candidaturas) fica restrita a backoffice/'Parceiros'/service_role.
--   Antes também era executável por anon.
--
-- Os corpos são os de produção (pg_get_functiondef em 2026-10-16) com o guard no
-- início; assinatura e retorno não mudam, então CREATE OR REPLACE preserva
-- dependências. Mesmo critério de get_tp2_partner_funnel (20261009195500).

CREATE OR REPLACE FUNCTION public.get_admin_funnel_users()
 RETURNS TABLE(whatsapp text, full_name text, funnel_phase text, step_order integer, furthest_passport_phase text, active_partner_name text, progress_percent integer, progress_filled integer, progress_total integer, is_dependent boolean, parent_full_name text, external_redirect_clicks integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
BEGIN
    IF NOT (COALESCE(auth.role(), '') = 'service_role'
            OR public.is_backoffice_admin()
            OR EXISTS (SELECT 1 FROM public.user_permissions p
                        WHERE p.user_id = auth.uid() AND p.permission = 'Parceiros')) THEN
        RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    WITH latest_app AS (
        SELECT DISTINCT ON (sa.user_id)
            sa.user_id,
            po.name AS partner_name,
            sa.status,
            sa.partner_id,
            (SELECT count(*) FROM jsonb_object_keys(sa.answers)) AS filled_count
        FROM public.student_applications sa
        JOIN public.partner_opportunities po ON po.id = sa.partner_id
        ORDER BY sa.user_id, sa.updated_at DESC
    ),
    partner_totals AS (
        SELECT partner_id, count(*) AS total_count
        FROM public.partner_forms
        GROUP BY partner_id
    ),
    user_redirects AS (
        SELECT user_id, count(*) AS click_count
        FROM public.external_redirect_clicks
        GROUP BY user_id
    )
    SELECT
        CASE
            WHEN v.isdependent = true THEN parent_au.phone::text
            ELSE au.phone::text
        END AS whatsapp,
        v.full_name::text,
        CASE
            WHEN v.total_applications_submitted >= 2 THEN '6. 2ª Candidatura Concluída'
            WHEN v.total_applications_started >= 2 THEN '5. 2ª Candidatura Iniciada'
            WHEN v.total_applications_submitted >= 1 THEN '4. 1ª Candidatura Concluída'
            WHEN v.total_applications_started >= 1 THEN '3. 1ª Candidatura Iniciada'
            WHEN v.passport_started = true THEN '2. Passaporte Iniciado'
            ELSE '1. Total de Usuários'
        END AS funnel_phase,
        CASE
            WHEN v.total_applications_submitted >= 2 THEN 6
            WHEN v.total_applications_started >= 2 THEN 5
            WHEN v.total_applications_submitted >= 1 THEN 4
            WHEN v.total_applications_started >= 1 THEN 3
            WHEN v.passport_started = true THEN 2
            ELSE 1
        END AS step_order,
        v.furthest_passport_phase::text,
        laa.partner_name,
        CASE
            WHEN laa.status = 'SUBMITTED' THEN 100
            WHEN pt.total_count > 0 THEN LEAST(100, ROUND((laa.filled_count * 100.0) / pt.total_count))::integer
            ELSE NULL
        END AS progress_percent,
        laa.filled_count::integer AS progress_filled,
        pt.total_count::integer AS progress_total,
        v.isdependent AS is_dependent,
        parent_up.full_name::text AS parent_full_name,
        COALESCE(ur.click_count, 0)::integer AS external_redirect_clicks
    FROM public.vw_admin_user_funnel v
    LEFT JOIN auth.users au ON au.id = v.user_id
    LEFT JOIN latest_app laa ON laa.user_id = v.user_id
    LEFT JOIN partner_totals pt ON pt.partner_id = laa.partner_id
    LEFT JOIN public.user_profiles parent_up ON parent_up.id = v.parent_user_id
    LEFT JOIN auth.users parent_au ON parent_au.id = v.parent_user_id
    LEFT JOIN user_redirects ur ON ur.user_id = v.user_id
    ORDER BY step_order DESC, v.full_name ASC;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_partner_applications_by_institution(p_institution_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, user_id uuid, partner_id uuid, partner_name text, institution_id uuid, institution_name text, full_name text, phone text, status text, answers jsonb, eligibility_results jsonb, created_at timestamp with time zone, phase_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
BEGIN
  IF NOT (COALESCE(auth.role(), '') = 'service_role'
          OR public.is_backoffice_admin()
          OR EXISTS (SELECT 1 FROM public.user_permissions p
                      WHERE p.user_id = auth.uid() AND p.permission = 'Parceiros')
          OR (p_institution_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM public.partners_users pu
                 WHERE pu.user_id = auth.uid() AND pu.partner_id = p_institution_id))) THEN
    RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501';
  END IF;

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
    sa.eligibility_results,
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

REVOKE EXECUTE ON FUNCTION public.get_admin_funnel_users() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_admin_funnel_users() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_partner_applications_by_institution(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_partner_applications_by_institution(uuid) TO authenticated, service_role;
