-- Fix etl_import_prouni_base to create Institutions, Campus and Courses from rawprouni
-- 20260605135300_prouni_base_full_import.sql

CREATE OR REPLACE FUNCTION public.etl_import_prouni_base(p_program_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '10min'
AS $$
DECLARE
  v_year              INTEGER;
  v_semester          TEXT;
  v_log_id            UUID;
  v_processed         INTEGER := 0;
  v_errors            TEXT;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN
    RAISE EXCEPTION 'Program not found';
  END IF;

  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (p_program_id, 'prouni_base', 'running', now())
  RETURNING id INTO v_log_id;

  BEGIN
    -- 1. Insert/Update Institutions
    INSERT INTO public.institutions (external_code, name)
    SELECT DISTINCT "CODIGO_IES"::text, "IES"
    FROM public.rawprouni
    WHERE "CODIGO_IES" IS NOT NULL
    ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name;

    -- 2. Insert/Update Campus
    INSERT INTO public.campus (institution_id, external_code, name, city, state)
    SELECT DISTINCT 
      i.id AS institution_id,
      r."CODIGO_CAMPUS"::text AS external_code,
      r."CAMPUS" AS name,
      r."MUNICIPIO" AS city,
      r."UF" AS state
    FROM public.rawprouni r
    JOIN public.institutions i ON i.external_code = r."CODIGO_IES"::text
    WHERE r."CODIGO_CAMPUS" IS NOT NULL
    ON CONFLICT (external_code) DO UPDATE SET 
      name = EXCLUDED.name,
      city = EXCLUDED.city,
      state = EXCLUDED.state;

    -- 3. Insert/Update Courses
    INSERT INTO public.courses (campus_id, course_code, course_name)
    SELECT DISTINCT 
      ca.id AS campus_id,
      r."CODIGO_CURSO"::text AS course_code,
      r."CURSO" AS course_name
    FROM public.rawprouni r
    JOIN public.campus ca ON ca.external_code = r."CODIGO_CAMPUS"::text
    WHERE r."CODIGO_CURSO" IS NOT NULL
    ON CONFLICT (campus_id, course_code) DO UPDATE SET 
      course_name = EXCLUDED.course_name;

    -- 4. Insert/Update Opportunities
    WITH mapped_raw AS (
      SELECT 
        c.id AS course_id,
        r."SEMESTRE"::text AS semester,
        r."CO_TURNO" AS shift,
        r."TIPO_BOLSA" AS scholarship_type,
        v_year AS year,
        'prouni' AS opportunity_type,
        CASE 
          WHEN r."NOTA_DE_CORTE" IS NULL OR TRIM(r."NOTA_DE_CORTE") = '' THEN NULL
          ELSE REPLACE(REPLACE(TRIM(r."NOTA_DE_CORTE"), '.', ''), ',', '.')::numeric
        END AS cutoff_score,
        to_jsonb(r) AS raw_data
      FROM public.rawprouni r
      JOIN public.campus ca ON ca.external_code = r."CODIGO_CAMPUS"::text
      JOIN public.courses c ON c.campus_id = ca.id AND c.course_code = r."CODIGO_CURSO"::text
    ),
    mapped AS (
      SELECT DISTINCT ON (course_id, opportunity_type, year, semester, shift) *
      FROM mapped_raw
      ORDER BY course_id, opportunity_type, year, semester, shift, cutoff_score DESC
    ),
    updated AS (
      UPDATE public.opportunities o
      SET 
        cutoff_score = m.cutoff_score,
        raw_data = m.raw_data,
        updated_at = now()
      FROM mapped m
      WHERE o.course_id = m.course_id 
        AND o.opportunity_type = m.opportunity_type 
        AND o.year = m.year 
        AND o.semester = m.semester 
        AND o.shift = m.shift
      RETURNING o.id
    ),
    inserted AS (
      INSERT INTO public.opportunities (
        course_id, semester, shift, scholarship_type, year, opportunity_type, cutoff_score, raw_data
      )
      SELECT m.course_id, m.semester, m.shift, m.scholarship_type, m.year, m.opportunity_type, m.cutoff_score, m.raw_data
      FROM mapped m
      WHERE NOT EXISTS (
        SELECT 1 FROM public.opportunities o 
        WHERE o.course_id = m.course_id 
          AND o.opportunity_type = m.opportunity_type 
          AND o.year = m.year 
          AND o.semester = m.semester 
          AND o.shift = m.shift
      )
      RETURNING id
    )
    SELECT (SELECT count(*) FROM updated) + (SELECT count(*) FROM inserted) INTO v_processed;

    -- Fix Scholarship Tags
    UPDATE public.opportunities
    SET scholarship_tags = '[["BOLSA_INTEGRAL"]]'::jsonb
    WHERE opportunity_type = 'prouni' AND year = v_year AND semester = v_semester
      AND (scholarship_tags IS NULL OR scholarship_tags::text = 'null' OR jsonb_array_length(scholarship_tags) = 0)
      AND (UPPER(scholarship_type) LIKE '%INTEGRAL%' OR UPPER(scholarship_type) = 'BOLSA INTEGRAL');

    UPDATE public.opportunities
    SET scholarship_tags = '[["BOLSA_PARCIAL"]]'::jsonb
    WHERE opportunity_type = 'prouni' AND year = v_year AND semester = v_semester
      AND (scholarship_tags IS NULL OR scholarship_tags::text = 'null' OR jsonb_array_length(scholarship_tags) = 0)
      AND (UPPER(scholarship_type) LIKE '%PARCIAL%' OR UPPER(scholarship_type) LIKE '%50%' OR UPPER(scholarship_type) = 'BOLSA PARCIAL 50%');

  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF v_errors IS NULL THEN
    UPDATE public.etl_run_logs SET status = 'success', records_processed = v_processed, finished_at = now() WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs SET status = 'error', records_processed = v_processed, errors = v_errors, finished_at = now() WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$$;
