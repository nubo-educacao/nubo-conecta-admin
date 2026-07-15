-- 20260703160000_fix_matview_concurrent_refresh_indexes.sql
-- REFRESH MATERIALIZED VIEW CONCURRENTLY requires at least one UNIQUE index on the
-- matview. Migration 20260703120000 recreated v_unified_opportunities and
-- mv_course_catalog with DROP ... CASCADE + CREATE, which dropped the unique indexes
-- those concurrent refreshes depended on — so etl_import_refresh_opportunities and
-- etl_import_refresh_catalog now fail with:
--   "cannot refresh materialized view ... concurrently".
--
-- Re-create the unique indexes. Keys verified unique in production:
--   v_unified_opportunities: (unified_id, type)  — DISTINCT ON per branch + type
--   mv_course_catalog:       (course_name)       — DISTINCT ON (course_name)
--
-- NOTE: any future DROP+CREATE of these matviews must re-create these indexes too.

CREATE UNIQUE INDEX IF NOT EXISTS uq_v_unified_opportunities_id_type
  ON public.v_unified_opportunities (unified_id, type);

CREATE UNIQUE INDEX IF NOT EXISTS uq_mv_course_catalog_course_name
  ON public.mv_course_catalog (course_name);
