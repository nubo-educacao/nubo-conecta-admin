-- fix_partner_funnel_view.sql
-- ===========================
-- Update vw_partner_funnel to:
-- 1. Count ALL clicks in partners_click (not just external_redirect_clicks)
-- 2. Merge Concluídas (SUBMITTED + redirected status), removing separate "Cliques Externos" column
-- 3. Rename total_applications_submitted → total_applications_completed

DROP VIEW IF EXISTS "public"."vw_partner_funnel" CASCADE;

CREATE VIEW "public"."vw_partner_funnel" AS
 WITH "partner_clicks" AS (
         SELECT "partners_click"."partner_id",
            "count"(DISTINCT "partners_click"."user_id") AS "total_unique_clicks"
           FROM "public"."partners_click"
          GROUP BY "partners_click"."partner_id"
        ), "partner_apps" AS (
         SELECT "student_applications"."partner_id",
            "count"(DISTINCT "student_applications"."user_id") AS "total_applications_started",
            "count"(DISTINCT
                CASE
                    WHEN ("student_applications"."status" = 'SUBMITTED'::"text" OR "student_applications"."status" = 'redirected'::"text") THEN "student_applications"."user_id"
                    ELSE NULL::"uuid"
                END) AS "total_applications_completed"
           FROM "public"."student_applications"
          GROUP BY "student_applications"."partner_id"
        )
 SELECT "po"."id" AS "partner_id",
    "po"."name" AS "partner_name",
    COALESCE("pc"."total_unique_clicks", (0)::bigint) AS "total_unique_clicks",
    COALESCE("pa"."total_applications_started", (0)::bigint) AS "total_applications_started",
    COALESCE("pa"."total_applications_completed", (0)::bigint) AS "total_applications_completed"
   FROM (("public"."partner_opportunities" "po"
     LEFT JOIN "partner_clicks" "pc" ON (("po"."id" = "pc"."partner_id")))
     LEFT JOIN "partner_apps" "pa" ON (("po"."id" = "pa"."partner_id")));

ALTER VIEW "public"."vw_partner_funnel" OWNER TO "postgres";
