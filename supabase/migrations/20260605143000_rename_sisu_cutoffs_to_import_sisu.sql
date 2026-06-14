-- Rename etl_import_sisu_cutoffs → etl_import_sisu (single unified function for rawsisu)
-- 20260605143000_rename_sisu_cutoffs_to_import_sisu.sql

-- 1. Drop the narrowly-scoped function
DROP FUNCTION IF EXISTS public.etl_import_sisu_cutoffs(uuid) CASCADE;

-- 2. Create the unified etl_import_sisu
CREATE OR REPLACE FUNCTION public.etl_import_sisu(p_program_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '10min'
AS $$
DECLARE
  v_year              INTEGER;
  v_semester          TEXT;
  v_log_id            UUID;
  v_processed         INTEGER := 0;
  v_info_processed    INTEGER := 0;
  v_errors            TEXT;
  v_rec               RECORD;
  v_course_id         UUID;
  v_inst_id           UUID;
BEGIN
  -- Fetch program details
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN
    RAISE EXCEPTION 'Program not found';
  END IF;

  -- Start log
  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (p_program_id, 'sisu', 'running', now())
  RETURNING id INTO v_log_id;

  -- ============================================================
  -- STEP 1: Populate institutions_info_sisu (acronym, org, category)
  -- ============================================================
  FOR v_rec IN
    SELECT DISTINCT ON ("CO_IES")
      "CO_IES"::text AS inst_external_code,
      "SG_IES" AS acronym,
      "DS_ORGANIZACAO_ACADEMICA" AS academic_organization,
      "DS_CATEGORIA_ADM" AS administrative_category
    FROM public.rawsisu
    WHERE "CO_IES" IS NOT NULL
  LOOP
    BEGIN
      SELECT id INTO v_inst_id
      FROM public.institutions
      WHERE external_code = v_rec.inst_external_code;

      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.institutions_info_sisu (
          institution_id, acronym, academic_organization, administrative_category
        )
        VALUES (
          v_inst_id,
          v_rec.acronym,
          v_rec.academic_organization,
          v_rec.administrative_category
        )
        ON CONFLICT (institution_id)
        DO UPDATE SET
          acronym = EXCLUDED.acronym,
          academic_organization = EXCLUDED.academic_organization,
          administrative_category = EXCLUDED.administrative_category,
          updated_at = now();

        v_info_processed := v_info_processed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN v_errors := SQLERRM; ELSE v_errors := v_errors || '; ' || SQLERRM; END IF;
    END;
  END LOOP;

  -- ============================================================
  -- STEP 2: Update cutoff_score + qt_inscricao on opportunities
  -- ============================================================
  FOR v_rec IN
    SELECT
      "CO_IES"::text AS inst_external_code,
      "NO_CAMPUS" AS campus_name,
      "CO_IES_CURSO"::text AS course_code,
      "DS_TURNO" AS shift,
      "DS_MOD_CONCORRENCIA" AS concurrency_type,
      "NU_NOTACORTE" AS cutoff_score,
      "QT_INSCRICAO" AS qt_inscricao
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

        IF FOUND THEN
          v_processed := v_processed + 1;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN v_errors := SQLERRM; ELSE v_errors := v_errors || '; ' || SQLERRM; END IF;
    END;
  END LOOP;

  -- ============================================================
  -- STEP 3: Refresh materialized views
  -- ============================================================
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

  RETURN jsonb_build_object(
    'institutions_info', v_info_processed,
    'cutoffs_updated', v_processed,
    'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END,
    'errors', v_errors
  );
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'error', errors = SQLERRM, finished_at = now()
    WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.etl_import_sisu(uuid) TO service_role, authenticated;
