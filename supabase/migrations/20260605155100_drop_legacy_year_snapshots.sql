-- Migration: Drop legacy year-fixed raw snapshot tables
-- Context: Before the year-agnostic ETL refactoring (20260603151700), raw staging tables
-- were named with a fixed year suffix (rawsisu2025, rawsisuvacancies2026, etc.).
-- After the refactoring, the ETL pipeline uses year-agnostic buffer tables
-- (rawsisu, rawsisuvacancies, rawprouni, rawprounivacancies, rawprouniocuppied).
-- The year is stamped by the selected program_id at ETL run time, not by the table name.
--
-- These tables are confirmed NOT referenced by any active ETL function, view, or RPC.
-- Estimated disk space recovered: ~269 MB
--
-- WARNING: Only run after confirming all data from these snapshots has been
-- successfully imported into the business schema (opportunities, courses_prouni_vacancies).
-- ============================================================

-- SiSU year-fixed snapshots (~51 MB + 58 MB + 60 MB)
DROP TABLE IF EXISTS public.rawsisu2025;
DROP TABLE IF EXISTS public.rawsisuvacancies2025;
DROP TABLE IF EXISTS public.rawsisuvacancies2026;

-- ProUni year-fixed snapshots (~20 MB + 42 MB + 38 MB)
DROP TABLE IF EXISTS public.rawprouni2025;
DROP TABLE IF EXISTS public.rawprounivacancies2025;
DROP TABLE IF EXISTS public.rawprouniocuppied2025;

-- Legacy one-off ETL helper functions from the pre-refactoring era
DROP FUNCTION IF EXISTS public.process_sisu_structure_2025();
DROP FUNCTION IF EXISTS public.process_sisu_opportunities_2025();
DROP FUNCTION IF EXISTS public.process_sisu_structure_2026();
DROP FUNCTION IF EXISTS public.process_sisu_opportunities_2026();
DROP FUNCTION IF EXISTS public.process_sisu_structure(text);
DROP FUNCTION IF EXISTS public.process_sisu_opportunities(text, int);

-- Note: The following tables are intentionally KEPT (active year-agnostic buffers):
--   rawsisu, rawsisuvacancies, rawprouni, rawprounivacancies, rawprouniocuppied, rawemec
