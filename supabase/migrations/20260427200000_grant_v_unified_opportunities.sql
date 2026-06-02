-- =============================================================================
-- Migration: Grant SELECT on v_unified_opportunities to anon + authenticated
-- Sprint 6 QA fix — view was missing grants causing 403/permission denied
-- in nubo-conecta-app (anon key).
-- =============================================================================

GRANT SELECT ON public.v_unified_opportunities TO anon, authenticated;
