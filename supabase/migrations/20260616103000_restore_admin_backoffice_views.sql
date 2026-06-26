-- restore_admin_backoffice_views.sql
-- ==================================
-- Restaura views do backoffice removidas indevidamente em post-migration-cleanup.sql (Card 5).
-- Eram consideradas "legadas" por não existirem em dev, mas o admin (passportDashboardService.ts)
-- depende delas diretamente. Definições recuperadas de backup_prod_schema.sql.

CREATE OR REPLACE VIEW "public"."reversed_student_applications" AS
 SELECT "sa"."id" AS "application_id",
    "sa"."user_id",
    "sa"."partner_id",
    "sa"."status",
    "sa"."created_at",
    "u"."phone" AS "user_phone",
    ("sa"."answers" ->> 'Nome Completo'::"text") AS "nome_completo",
    ("sa"."answers" ->> 'Nome de preferência'::"text") AS "nome_preferencia",
    COALESCE(("sa"."answers" ->> 'Email candidato'::"text"), ("sa"."answers" ->> 'Email'::"text")) AS "email",
    ("sa"."answers" ->> 'Profissão do pai'::"text") AS "profissao_pai",
    ("sa"."answers" ->> 'Nome responsável'::"text") AS "nome_responsavel",
    "sa"."answers" AS "formato_original_json"
   FROM ("public"."student_applications" "sa"
     LEFT JOIN "auth"."users" "u" ON (("u"."id" = "sa"."user_id")))
  WHERE (((COALESCE(("sa"."answers" ->> 'Email candidato'::"text"), ("sa"."answers" ->> 'Email'::"text")) ~ '@.+\.(com|br|net|org)[a-zA-Z0-9]+'::"text") AND (COALESCE(("sa"."answers" ->> 'Email candidato'::"text"), ("sa"."answers" ->> 'Email'::"text")) !~ '@.+\.(com|br|net|org)$'::"text")) OR (("sa"."answers" ->> 'Nome de preferência'::"text") ~ '^[a-z].*[A-Z]$'::"text") OR (("sa"."answers" ->> 'Nome Completo'::"text") ~ '^[a-z].*[A-Z]$'::"text") OR (("sa"."answers")::"text" ~~* ANY (ARRAY['%margatsnI%'::"text", '%ipazstahW%'::"text", '%koobecaF%'::"text", '%eniwodniL%'::"text", '%rotlucirGA%'::"text", '%oriehnegnE%'::"text"])) OR (("sa"."answers")::"text" ~ '[a-zçáàâãéêíóôõú][A-ZÇÁÀÂÃÉÊÍÓÔÕÚ]'::"text"));

ALTER VIEW "public"."reversed_student_applications" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_admin_user_funnel" AS
 WITH "user_apps" AS (
         SELECT "student_applications"."user_id",
            "count"(*) AS "total_applications_started",
            "count"(*) FILTER (WHERE ("student_applications"."status" = 'SUBMITTED'::"text")) AS "total_applications_submitted"
           FROM "public"."student_applications"
          GROUP BY "student_applications"."user_id"
        )
 SELECT "up"."id" AS "user_id",
    "up"."full_name",
    "up"."created_at",
    "up"."isdependent",
    "up"."parent_user_id",
    "up"."passport_phase",
    "up"."furthest_passport_phase",
    (("up"."active_workflow" = 'passport_workflow'::"text") OR ("up"."furthest_passport_phase" IS NOT NULL)) AS "passport_started",
    COALESCE("ua"."total_applications_started", (0)::bigint) AS "total_applications_started",
    COALESCE("ua"."total_applications_submitted", (0)::bigint) AS "total_applications_submitted"
   FROM ("public"."user_profiles" "up"
     LEFT JOIN "user_apps" "ua" ON (("ua"."user_id" = "up"."id")))
  WHERE ("up"."created_at" >= '2026-03-09 00:00:00+00'::timestamp with time zone);

ALTER VIEW "public"."vw_admin_user_funnel" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_admin_funnel_chart" AS
 SELECT '1. Total de Usuários'::"text" AS "step_name",
    1 AS "step_order",
    "count"(*) AS "user_count"
   FROM "public"."vw_admin_user_funnel"
UNION ALL
 SELECT '2. Passaporte Iniciado'::"text" AS "step_name",
    2 AS "step_order",
    "count"(*) AS "user_count"
   FROM "public"."vw_admin_user_funnel"
  WHERE ("vw_admin_user_funnel"."passport_started" = true)
UNION ALL
 SELECT '3. 1ª Candidatura Iniciada'::"text" AS "step_name",
    3 AS "step_order",
    "count"(*) AS "user_count"
   FROM "public"."vw_admin_user_funnel"
  WHERE ("vw_admin_user_funnel"."total_applications_started" >= 1)
UNION ALL
 SELECT '4. 1ª Candidatura Concluída'::"text" AS "step_name",
    4 AS "step_order",
    "count"(*) AS "user_count"
   FROM "public"."vw_admin_user_funnel"
  WHERE ("vw_admin_user_funnel"."total_applications_submitted" >= 1)
UNION ALL
 SELECT '5. 2ª Candidatura Iniciada'::"text" AS "step_name",
    5 AS "step_order",
    "count"(*) AS "user_count"
   FROM "public"."vw_admin_user_funnel"
  WHERE ("vw_admin_user_funnel"."total_applications_started" >= 2)
UNION ALL
 SELECT '6. 2ª Candidatura Concluída'::"text" AS "step_name",
    6 AS "step_order",
    "count"(*) AS "user_count"
   FROM "public"."vw_admin_user_funnel"
  WHERE ("vw_admin_user_funnel"."total_applications_submitted" >= 2);

ALTER VIEW "public"."vw_admin_funnel_chart" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_admin_furthest_passport_phases" AS
 SELECT COALESCE("furthest_passport_phase", 'UNSTARTED'::"text") AS "furthest_passport_phase",
    "count"(*) AS "total_users"
   FROM "public"."user_profiles"
  WHERE ("created_at" >= '2026-03-09 00:00:00+00'::timestamp with time zone)
  GROUP BY "furthest_passport_phase";

ALTER VIEW "public"."vw_admin_furthest_passport_phases" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_admin_passport_phases" AS
 SELECT COALESCE("passport_phase", 'UNSTARTED'::"text") AS "passport_phase",
    "count"(*) AS "total_users"
   FROM "public"."user_profiles"
  WHERE ("created_at" >= '2026-03-09 00:00:00+00'::timestamp with time zone)
  GROUP BY "passport_phase";

ALTER VIEW "public"."vw_admin_passport_phases" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_partner_application_details" AS
 SELECT "sa"."id" AS "application_id",
    "sa"."partner_id",
    "sa"."user_id",
    "up"."full_name" AS "student_name",
    "sa"."status",
    "sa"."created_at",
    "sa"."updated_at",
    ( SELECT "count"(*) AS "count"
           FROM "jsonb_object_keys"(
                CASE
                    WHEN ("jsonb_typeof"("sa"."answers") = 'object'::"text") THEN "sa"."answers"
                    ELSE '{}'::"jsonb"
                END) "jsonb_object_keys"("jsonb_object_keys")) AS "total_answers_filled"
   FROM ("public"."student_applications" "sa"
     JOIN "public"."user_profiles" "up" ON (("up"."id" = "sa"."user_id")));

ALTER VIEW "public"."vw_partner_application_details" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_partner_application_completion_buckets" AS
 WITH "partner_form_counts" AS (
         SELECT "partner_forms"."partner_id",
            "count"(*) AS "total_forms"
           FROM "public"."partner_forms"
          GROUP BY "partner_forms"."partner_id"
        ), "application_percentages" AS (
         SELECT "a"."application_id",
            "a"."partner_id",
            "a"."status",
            "a"."total_answers_filled",
            COALESCE("fc"."total_forms", (0)::bigint) AS "total_forms",
                CASE
                    WHEN ("a"."status" = 'SUBMITTED'::"text") THEN (100)::bigint
                    WHEN (COALESCE("fc"."total_forms", (0)::bigint) = 0) THEN (0)::bigint
                    ELSE LEAST((100)::bigint, (("a"."total_answers_filled" * 100) / "fc"."total_forms"))
                END AS "completion_percent"
           FROM ("public"."vw_partner_application_details" "a"
             LEFT JOIN "partner_form_counts" "fc" ON (("a"."partner_id" = "fc"."partner_id")))
        )
 SELECT "partner_id",
        CASE
            WHEN ("completion_percent" <= 25) THEN '1. Até 25%'::"text"
            WHEN ("completion_percent" <= 50) THEN '2. Até 50%'::"text"
            WHEN ("completion_percent" <= 75) THEN '3. Até 75%'::"text"
            ELSE '4. Até 100%'::"text"
        END AS "completion_bucket",
    "count"(*) AS "applications_count"
   FROM "application_percentages"
  GROUP BY "partner_id",
        CASE
            WHEN ("completion_percent" <= 25) THEN '1. Até 25%'::"text"
            WHEN ("completion_percent" <= 50) THEN '2. Até 50%'::"text"
            WHEN ("completion_percent" <= 75) THEN '3. Até 75%'::"text"
            ELSE '4. Até 100%'::"text"
        END;

ALTER VIEW "public"."vw_partner_application_completion_buckets" OWNER TO "postgres";


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
 SELECT "p"."id" AS "partner_id",
    "p"."name" AS "partner_name",
    COALESCE("pc"."total_unique_clicks", (0)::bigint) AS "total_unique_clicks",
    COALESCE("pa"."total_applications_started", (0)::bigint) AS "total_applications_started",
    COALESCE("pa"."total_applications_submitted", (0)::bigint) AS "total_applications_submitted",
    COALESCE("ec"."total_external_redirect_clicks", (0)::bigint) AS "total_external_redirect_clicks"
   FROM ((("public"."partners" "p"
     LEFT JOIN "partner_clicks" "pc" ON (("p"."id" = "pc"."partner_id")))
     LEFT JOIN "partner_apps" "pa" ON (("p"."id" = "pa"."partner_id")))
     LEFT JOIN "external_clicks" "ec" ON (("p"."id" = "ec"."partner_id")));

ALTER VIEW "public"."vw_partner_funnel" OWNER TO "postgres";
