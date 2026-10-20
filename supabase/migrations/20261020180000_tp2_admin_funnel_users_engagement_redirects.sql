-- get_admin_funnel_users() deixa de ler external_redirect_clicks (TP-2 / NUB-RD-77b).
--
-- Era o último leitor SQL ativo da tabela legada de redirects: o export CSV do
-- /b2b-dashboard (PassportDashboard) chama esta RPC. A contagem por usuário passa
-- a vir de engagement_events (redirect de oportunidade parceira, SUM(event_count)),
-- que tem o histórico 1:1 (legacy_external_redirect) e as escritas live
-- (partner_application). Conferido em produção em 2026-10-20: 594 = 594 eventos,
-- 559 usuários, nenhuma contagem por usuário diferente. Redirect MEC fica fora,
-- como na tabela legada, que só recebia parceiro.
--
-- O nome da coluna de retorno (external_redirect_clicks) é contrato e não muda.
-- O corpo é o de 20261016135200 (igual em PROD e DEV, mesmo md5), com o mesmo
-- guard e search_path; só a CTE user_redirects muda. Mesma assinatura e retorno,
-- então CREATE OR REPLACE preserva dependências. O dual-write continua: esta
-- migration não toca external_redirect_clicks nem o produtor.

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
        SELECT e.user_id, SUM(e.event_count) AS click_count
        FROM public.engagement_events e
        WHERE e.event_type = 'redirect'
          AND e.entity_type = 'partner_opportunity'
          AND e.user_id IS NOT NULL
        GROUP BY e.user_id
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

REVOKE EXECUTE ON FUNCTION public.get_admin_funnel_users() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_admin_funnel_users() TO authenticated, service_role;
