-- Refactor ETL RPCs to use bulk INSERT ... SELECT for massive performance gain and to prevent API timeouts
-- 20260603210456_refactor_etl_bulk_inserts.sql

-- 1. etl_import_prouni_base
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


-- 2. etl_import_prouni_vacancies
CREATE OR REPLACE FUNCTION public.etl_import_prouni_vacancies(p_program_id uuid)
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
  VALUES (p_program_id, 'prouni_vacancies', 'running', now())
  RETURNING id INTO v_log_id;

  BEGIN
    WITH mapped AS (
      SELECT 
        op.id AS opportunity_id,
        v."DS_TIPO_BOLSA" AS ds_tipo_bolsa,
        COALESCE(v."BOLSAS_AMPLA_OFERTADA"::integer, 0) AS bolsas_ampla_ofertada,
        COALESCE(v."BOLSAS_COTA_OFERTADA"::integer, 0) AS bolsas_cota_ofertada,
        v_year AS year,
        v_semester AS semester
      FROM public.rawprounivacancies v
      JOIN public.campus ca ON ca.external_code = v."CO_CAMPUS"::text
      JOIN public.courses c ON c.campus_id = ca.id AND c.course_code = v."CO_CURSO"::text
      JOIN public.opportunities op ON op.course_id = c.id
        AND op.opportunity_type = 'prouni'
        AND op.year = v_year
        AND op.semester = v_semester
    ),
    inserted AS (
      INSERT INTO public.opportunities_prouni_vacancies (
        opportunity_id, ds_tipo_bolsa, bolsas_ampla_ofertada, bolsas_cota_ofertada, year, semester
      )
      SELECT * FROM mapped
      ON CONFLICT (opportunity_id, ds_tipo_bolsa)
      DO UPDATE SET
        bolsas_ampla_ofertada = EXCLUDED.bolsas_ampla_ofertada,
        bolsas_cota_ofertada  = EXCLUDED.bolsas_cota_ofertada,
        updated_at            = now()
      RETURNING 1
    )
    SELECT count(*) INTO v_processed FROM inserted;

    WITH aggregated_data AS (
      SELECT 
        c.id AS course_id,
        jsonb_agg(jsonb_build_object(
          'scholarship_type', pv.ds_tipo_bolsa,
          'broad_competition_offered', pv.bolsas_ampla_ofertada,
          'quotas_offered', pv.bolsas_cota_ofertada
        )) as vacancies_json
      FROM public.opportunities_prouni_vacancies pv
      JOIN public.opportunities o ON o.id = pv.opportunity_id
      JOIN public.courses c ON c.id = o.course_id
      WHERE o.year = v_year AND o.semester = v_semester
      GROUP BY c.id
    )
    UPDATE public.courses c
    SET vacancies = ad.vacancies_json
    FROM aggregated_data ad
    WHERE c.id = ad.course_id;

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


-- 3. etl_import_prouni_occupied
CREATE OR REPLACE FUNCTION public.etl_import_prouni_occupied(p_program_id uuid)
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
  VALUES (p_program_id, 'prouni_occupied', 'running', now())
  RETURNING id INTO v_log_id;

  BEGIN
    WITH mapped AS (
      SELECT 
        op.id AS opportunity_id,
        v."DS_TIPO_BOLSA" AS ds_tipo_bolsa,
        COALESCE(v."BOLSAS_AMPLA_OCUPADA"::integer, 0) AS bolsas_ampla_ocupada,
        COALESCE(v."BOLSAS_COTA_OCUPADA"::integer, 0) AS bolsas_cota_ocupada,
        v_year AS year,
        v_semester AS semester
      FROM public.rawprouniocuppied v
      JOIN public.campus ca ON ca.external_code = v."CO_CAMPUS"::text
      JOIN public.courses c ON c.campus_id = ca.id AND c.course_code = v."CO_CURSO"::text
      JOIN public.opportunities op ON op.course_id = c.id
        AND op.opportunity_type = 'prouni'
        AND op.year = v_year
        AND op.semester = v_semester
    ),
    inserted AS (
      INSERT INTO public.opportunities_prouni_vacancies (
        opportunity_id, ds_tipo_bolsa, bolsas_ampla_ocupada, bolsas_cota_ocupada, year, semester
      )
      SELECT opportunity_id, ds_tipo_bolsa, null, null, year, semester FROM mapped WHERE false -- Ensure correct columns
      ON CONFLICT (opportunity_id, ds_tipo_bolsa) DO NOTHING -- Fallback if not matching exactly
    ),
    updated AS (
      UPDATE public.opportunities_prouni_vacancies pv
      SET bolsas_ampla_ocupada = m.bolsas_ampla_ocupada,
          bolsas_cota_ocupada = m.bolsas_cota_ocupada,
          updated_at = now()
      FROM mapped m
      WHERE pv.opportunity_id = m.opportunity_id AND pv.ds_tipo_bolsa = m.ds_tipo_bolsa
      RETURNING 1
    )
    SELECT count(*) INTO v_processed FROM updated;

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
