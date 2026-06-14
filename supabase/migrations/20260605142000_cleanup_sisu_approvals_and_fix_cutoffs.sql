-- Cleanup obsolete SiSU approvals and add cutoff import
-- 20260605142000_cleanup_sisu_approvals_and_fix_cutoffs.sql

-- 1. Drop unused zombie objects
DROP VIEW IF EXISTS public.v_opportunities_sisu_approvals CASCADE;
DROP TABLE IF EXISTS public.opportunities_sisu_approvals CASCADE;
DROP TABLE IF EXISTS public.rawsisuapprovals2026 CASCADE;
DROP FUNCTION IF EXISTS public.etl_sisu_approvals CASCADE;
DROP FUNCTION IF EXISTS public.etl_import_sisu_approvals CASCADE;

-- 2. Create Year-Agnostic rawsisu staging table
CREATE TABLE IF NOT EXISTS public.rawsisu (LIKE public.rawsisu2025 INCLUDING ALL);

-- If there's already data in rawsisu2025, populate rawsisu to be ready
INSERT INTO public.rawsisu SELECT * FROM public.rawsisu2025 ON CONFLICT DO NOTHING;

-- 3. Create RPC to import cutoffs
CREATE OR REPLACE FUNCTION public.etl_import_sisu_cutoffs(p_program_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_year              INTEGER;
  v_semester          TEXT;
  v_log_id            UUID;
  v_processed         INTEGER := 0;
  v_errors            TEXT;
  v_rec               RECORD;
  v_course_id         UUID;
BEGIN
  -- Fetch program details
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN
    RAISE EXCEPTION 'Program not found';
  END IF;

  -- Start log
  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (p_program_id, 'sisu_cutoffs', 'running', now())
  RETURNING id INTO v_log_id;

  FOR v_rec IN 
    SELECT 
      "CO_IES"::text AS inst_external_code, 
      "NO_CAMPUS" AS campus_name,
      "CO_IES_CURSO"::text AS course_code,
      "DS_TURNO" AS shift,
      "DS_MOD_CONCORRENCIA" AS concurrency_type,
      "NU_NOTACORTE" AS cutoff_score
    FROM public.rawsisu
    WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL AND "CO_IES_CURSO" IS NOT NULL
  LOOP
    BEGIN
      -- Find Course ID
      SELECT c.id INTO v_course_id
      FROM public.courses c
      JOIN public.campus ca ON ca.id = c.campus_id
      JOIN public.institutions i ON i.id = ca.institution_id
      WHERE i.external_code = v_rec.inst_external_code
        AND ca.name = v_rec.campus_name
        AND c.course_code = v_rec.course_code
      LIMIT 1;

      IF v_course_id IS NOT NULL THEN
        UPDATE public.opportunities
        SET 
          cutoff_score = CASE 
            WHEN v_rec.cutoff_score IS NULL OR TRIM(v_rec.cutoff_score) = '' THEN NULL
            ELSE REPLACE(REPLACE(TRIM(v_rec.cutoff_score), '.', ''), ',', '.')::numeric
          END,
          updated_at = now()
        WHERE course_id = v_course_id
          AND opportunity_type = 'sisu'
          AND year = v_year
          AND semester = v_semester
          AND shift = v_rec.shift
          AND concurrency_type = v_rec.concurrency_type;

        -- If rows were updated, count them
        IF FOUND THEN
          v_processed := v_processed + 1;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN v_errors := SQLERRM; ELSE v_errors := v_errors || '; ' || SQLERRM; END IF;
    END;
  END LOOP;

  -- Refresh materialized view to reflect cutoffs
  REFRESH MATERIALIZED VIEW CONCURRENTLY public.v_unified_opportunities;
  REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_course_catalog;

  -- Update log
  IF v_errors IS NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'success', records_processed = v_processed, finished_at = now()
    WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs
    SET status = 'error', records_processed = v_processed, errors = v_errors, finished_at = now()
    WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'error', errors = SQLERRM, finished_at = now()
    WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.etl_import_sisu_cutoffs(uuid) TO service_role, authenticated;
