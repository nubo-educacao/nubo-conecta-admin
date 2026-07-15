-- 20260703190000_drop_mv_course_catalog.sql
-- Remove the mv_course_catalog materialized view and its refresh functions.
--
-- Rationale (verified): the active stack (nubo-conecta-app, nubo-conecta-admin,
-- cloudinha-conecta-agent) does NOT read mv_course_catalog. The active app browses
-- opportunities via v_unified_opportunities / get_unified_opportunities_by_distance.
-- The only readers (get_courses_with_opportunities, get_user_favorites_details) belong
-- to the legacy nubo-hub-app and already expect a completely different (rich) schema
-- than the current 2-column matview, so they are non-functional against it regardless.
--
-- We drop the matview and the two functions whose sole purpose was to refresh it.
-- The two legacy reader RPCs are intentionally left in place (they are legacy-app
-- feature endpoints, not part of this cleanup); they will simply error if ever called,
-- exactly as they already do.

DROP FUNCTION IF EXISTS public.etl_import_refresh_catalog();
DROP FUNCTION IF EXISTS public.refresh_course_catalog();

-- Matview drop also removes its unique index (uq_mv_course_catalog_course_name).
DROP MATERIALIZED VIEW IF EXISTS public.mv_course_catalog;
