-- =============================================================================
-- Migration: mec_import_rpcs — Sprint 02 Wave 1.6
-- Três RPCs SECURITY DEFINER para ingestão de dados MEC via CSV:
--   1. process_mec_institutions_csv — upsert de instituições via external_code
--   2. process_mec_campus_csv — upsert de campus via join em institutions.external_code
--   3. process_mec_courses_csv — insert de courses + opportunities (sisu/prouni)
-- GRANT EXECUTE para authenticated: Edge Function chama com service_role ou JWT admin.
-- Circuit Breaker: revisar antes de qualquer `supabase db push`.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- RPC 1: process_mec_institutions_csv
-- Input: jsonb array de objetos { external_code, name }
-- Behavior: UPSERT via external_code (conflict key)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION process_mec_institutions_csv(p_records jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_record    jsonb;
  v_processed integer := 0;
  v_errors    jsonb   := '[]'::jsonb;
BEGIN
  FOR v_record IN SELECT jsonb_array_elements(p_records)
  LOOP
    BEGIN
      INSERT INTO institutions (name, external_code)
      VALUES (
        v_record->>'name',
        v_record->>'external_code'
      )
      ON CONFLICT (external_code) WHERE external_code IS NOT NULL
      DO UPDATE SET
        name = EXCLUDED.name;

      v_processed := v_processed + 1;
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_array(
        jsonb_build_object(
          'record', v_record,
          'error',  SQLERRM
        )
      );
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'processed', v_processed,
    'errors',    v_errors
  );
END;
$$;

GRANT EXECUTE ON FUNCTION process_mec_institutions_csv(jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- RPC 2: process_mec_campus_csv
-- Input: jsonb array de objetos { institution_external_code, name, city, state, latitude?, longitude? }
-- Behavior: UPSERT via join em institutions.external_code
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION process_mec_campus_csv(p_records jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_record         jsonb;
  v_institution_id uuid;
  v_processed      integer := 0;
  v_errors         jsonb   := '[]'::jsonb;
BEGIN
  FOR v_record IN SELECT jsonb_array_elements(p_records)
  LOOP
    BEGIN
      -- Resolve institution via external_code (Gap 2 resolution)
      SELECT id INTO v_institution_id
      FROM institutions
      WHERE external_code = v_record->>'institution_external_code';

      IF v_institution_id IS NULL THEN
        RAISE EXCEPTION 'Institution not found for external_code: %', v_record->>'institution_external_code';
      END IF;

      INSERT INTO campus (institution_id, name, city, state, latitude, longitude)
      VALUES (
        v_institution_id,
        v_record->>'name',
        v_record->>'city',
        v_record->>'state',
        NULLIF(v_record->>'latitude',  '')::double precision,
        NULLIF(v_record->>'longitude', '')::double precision
      )
      ON CONFLICT (institution_id, name, city)
      DO UPDATE SET
        state     = EXCLUDED.state,
        latitude  = COALESCE(EXCLUDED.latitude,  campus.latitude),
        longitude = COALESCE(EXCLUDED.longitude, campus.longitude);

      v_processed := v_processed + 1;
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_array(
        jsonb_build_object(
          'record', v_record,
          'error',  SQLERRM
        )
      );
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'processed', v_processed,
    'errors',    v_errors
  );
END;
$$;

GRANT EXECUTE ON FUNCTION process_mec_campus_csv(jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- RPC 3: process_mec_courses_csv
-- Input: jsonb array de objetos {
--   campus_id, course_name, opportunity_type (sisu|prouni),
--   year, semester, shift, cutoff_score?, scholarship_type?
-- }
-- Behavior: INSERT courses (if not exists) + INSERT opportunities
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION process_mec_courses_csv(p_records jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_record    jsonb;
  v_course_id uuid;
  v_processed integer := 0;
  v_errors    jsonb   := '[]'::jsonb;
BEGIN
  FOR v_record IN SELECT jsonb_array_elements(p_records)
  LOOP
    BEGIN
      -- Upsert course by campus_id + course_name
      INSERT INTO courses (campus_id, course_name)
      VALUES (
        (v_record->>'campus_id')::uuid,
        v_record->>'course_name'
      )
      ON CONFLICT (campus_id, course_name) DO NOTHING
      RETURNING id INTO v_course_id;

      -- If conflict, fetch existing id
      IF v_course_id IS NULL THEN
        SELECT id INTO v_course_id
        FROM courses
        WHERE campus_id   = (v_record->>'campus_id')::uuid
          AND course_name = v_record->>'course_name';
      END IF;

      -- Insert opportunity (idempotent: skip if same course/type/year/semester/shift exists)
      INSERT INTO opportunities (
        course_id,
        opportunity_type,
        year,
        semester,
        shift,
        cutoff_score,
        scholarship_type
      )
      VALUES (
        v_course_id,
        v_record->>'opportunity_type',
        (v_record->>'year')::integer,
        v_record->>'semester',
        v_record->>'shift',
        NULLIF(v_record->>'cutoff_score', '')::numeric,
        v_record->>'scholarship_type'
      )
      ON CONFLICT (course_id, opportunity_type, year, semester, shift) DO NOTHING;

      v_processed := v_processed + 1;
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_array(
        jsonb_build_object(
          'record', v_record,
          'error',  SQLERRM
        )
      );
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'processed', v_processed,
    'errors',    v_errors
  );
END;
$$;

GRANT EXECUTE ON FUNCTION process_mec_courses_csv(jsonb) TO authenticated;
