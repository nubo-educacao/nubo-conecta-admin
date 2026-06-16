-- fix_admin_dashboard_partner_opportunities_join.sql
-- ====================================================
-- student_applications.partner_id agora referencia partner_opportunities.id
-- (100% das 526 candidaturas em prod), não mais a tabela legada partners.
-- get_admin_funnel_users, get_admin_applications_over_time e vw_partner_funnel
-- ainda faziam JOIN com partners, então candidaturas de parceiros novos
-- (ex: BIP Impulsiona) ficavam invisíveis no dashboard do backoffice.

CREATE OR REPLACE FUNCTION public.get_admin_applications_over_time(p_partner_id uuid DEFAULT NULL::uuid, p_days_ago integer DEFAULT 30)
 RETURNS TABLE(date text, partner_id uuid, partner_name text, count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        to_char(sa.created_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM-DD') AS date,
        sa.partner_id,
        po.name AS partner_name,
        COUNT(*) AS count
    FROM public.student_applications sa
    LEFT JOIN public.partner_opportunities po ON po.id = sa.partner_id
    WHERE (p_partner_id IS NULL OR sa.partner_id = p_partner_id)
      AND (p_days_ago IS NULL OR sa.created_at >= (now() - (p_days_ago || ' days')::interval))
    GROUP BY to_char(sa.created_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM-DD'), sa.partner_id, po.name
    ORDER BY date ASC;
END;
$function$;


CREATE OR REPLACE FUNCTION public.get_admin_funnel_users()
 RETURNS TABLE(whatsapp text, full_name text, funnel_phase text, step_order integer, furthest_passport_phase text, active_partner_name text, progress_percent integer, progress_filled integer, progress_total integer, is_dependent boolean, parent_full_name text, external_redirect_clicks integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
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


CREATE OR REPLACE VIEW "public"."vw_partner_funnel" AS
 WITH "partner_clicks" AS (
         SELECT "partners_click"."partner_id",
            "count"(DISTINCT "partners_click"."user_id") AS "total_unique_clicks"
           FROM "public"."partners_click"
          WHERE ("partners_click"."created_at" >= '2026-03-09 00:00:00+00'::timestamp with time zone)
          GROUP BY "partners_click"."partner_id"
        ), "partner_apps" AS (
         SELECT "student_applications"."partner_id",
            "count"(DISTINCT "student_applications"."user_id") AS "total_applications_started",
            "count"(DISTINCT
                CASE
                    WHEN ("student_applications"."status" = 'SUBMITTED'::"text") THEN "student_applications"."user_id"
                    ELSE NULL::"uuid"
                END) AS "total_applications_submitted"
           FROM "public"."student_applications"
          WHERE ("student_applications"."created_at" >= '2026-03-09 00:00:00+00'::timestamp with time zone)
          GROUP BY "student_applications"."partner_id"
        ), "external_clicks" AS (
         SELECT "external_redirect_clicks"."partner_id",
            "count"(DISTINCT "external_redirect_clicks"."user_id") AS "total_external_redirect_clicks"
           FROM "public"."external_redirect_clicks"
          WHERE ("external_redirect_clicks"."created_at" >= '2026-03-09 00:00:00+00'::timestamp with time zone)
          GROUP BY "external_redirect_clicks"."partner_id"
        )
 SELECT "po"."id" AS "partner_id",
    "po"."name" AS "partner_name",
    COALESCE("pc"."total_unique_clicks", (0)::bigint) AS "total_unique_clicks",
    COALESCE("pa"."total_applications_started", (0)::bigint) AS "total_applications_started",
    COALESCE("pa"."total_applications_submitted", (0)::bigint) AS "total_applications_submitted",
    COALESCE("ec"."total_external_redirect_clicks", (0)::bigint) AS "total_external_redirect_clicks"
   FROM ((("public"."partner_opportunities" "po"
     LEFT JOIN "partner_clicks" "pc" ON (("po"."id" = "pc"."partner_id")))
     LEFT JOIN "partner_apps" "pa" ON (("po"."id" = "pa"."partner_id")))
     LEFT JOIN "external_clicks" "ec" ON (("po"."id" = "ec"."partner_id")));

ALTER VIEW "public"."vw_partner_funnel" OWNER TO "postgres";
