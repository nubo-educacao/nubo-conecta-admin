-- remove_passport_dashboard_views.sql
-- ====================================
-- Remove legacy views from Dashboard do Passaporte. The cards that used these views
-- ("Funil de Conversão (Global)", "Fase Atual do Passaporte", "Fase Mais Avançada Alcançada")
-- were removed from the UI. The views are no longer needed.

DROP VIEW IF EXISTS "public"."vw_admin_funnel_chart" CASCADE;
DROP VIEW IF EXISTS "public"."vw_admin_passport_phases" CASCADE;
DROP VIEW IF EXISTS "public"."vw_admin_furthest_passport_phases" CASCADE;
