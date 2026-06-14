-- 20260609220410_fix_etl_import_sisu_has_more_regression.sql
-- Fixes the has_more regression introduced in alter_rawsisu_columns_to_text.

CREATE OR REPLACE FUNCTION public.etl_import_sisu(
  p_program_id uuid,
  p_limit integer DEFAULT NULL,
  p_offset integer DEFAULT 0,
  p_log_id uuid DEFAULT NULL
)
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
  v_errors            TEXT;
  v_raw_count         INTEGER;
  v_inst_count        INTEGER;
  v_campus_count      INTEGER;
  v_course_count      INTEGER;
  v_opp_count         INTEGER;
  v_detail_msg        TEXT;
  v_has_more          BOOLEAN := FALSE;
  v_total_processed_in_log INTEGER := 0;
  v_batch_rows        INTEGER := 0;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester FROM public.programs WHERE id = p_program_id;
  IF v_year IS NULL THEN RAISE EXCEPTION 'Program not found'; END IF;

  SELECT COUNT(*) INTO v_raw_count FROM public.rawsisu;

  IF p_log_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed)
    VALUES (p_program_id, 'sisu', 'running', now(), 0) RETURNING id INTO v_log_id;
  ELSE
    v_log_id := p_log_id;
  END IF;

  BEGIN
    -- 1. Insert institutions using CO_IES (clean dots if any)
    INSERT INTO public.institutions (external_code, name)
    SELECT DISTINCT replace(r."CO_IES", '.', '') as external_code, r."NO_IES" 
    FROM (SELECT * FROM public.rawsisu ORDER BY "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA" LIMIT p_limit OFFSET p_offset) r
    WHERE r."CO_IES" IS NOT NULL AND replace(r."CO_IES", '.', '') <> ''
    ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name;

    -- 2. Insert campus using unique constraint (institution_id, name, city)
    INSERT INTO public.campus (institution_id, name, city, state, region)
    SELECT DISTINCT i.id, r."NO_CAMPUS", 
      COALESCE(
        (SELECT c.name FROM public.cities c
         WHERE public.f_unaccent(lower(c.name)) = public.f_unaccent(lower(r."NO_MUNICIPIO_CAMPUS"))
           AND c.state = r."SG_UF_CAMPUS" LIMIT 1),
        r."NO_MUNICIPIO_CAMPUS"
      ) as city,
      r."SG_UF_CAMPUS",
      r."DS_REGIAO_CAMPUS"
    FROM (SELECT * FROM public.rawsisu ORDER BY "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA" LIMIT p_limit OFFSET p_offset) r
    JOIN public.institutions i ON i.external_code = replace(r."CO_IES", '.', '')
    WHERE r."NO_CAMPUS" IS NOT NULL
    ON CONFLICT (institution_id, name, city) DO UPDATE SET state = EXCLUDED.state, region = EXCLUDED.region;

    -- 3. Insert courses using (campus_id, course_code) unique constraint
    INSERT INTO public.courses (campus_id, course_code, course_name, degree_type)
    SELECT DISTINCT ca.id, replace(r."CO_IES_CURSO", '.', '') as course_code, r."NO_CURSO", r."DS_GRAU"
    FROM (SELECT * FROM public.rawsisu ORDER BY "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA" LIMIT p_limit OFFSET p_offset) r
    JOIN public.institutions i ON i.external_code = replace(r."CO_IES", '.', '')
    JOIN public.campus ca ON ca.institution_id = i.id AND ca.name = r."NO_CAMPUS"
    WHERE r."CO_IES_CURSO" IS NOT NULL AND replace(r."CO_IES_CURSO", '.', '') <> ''
    ON CONFLICT (campus_id, course_code) DO UPDATE SET course_name = EXCLUDED.course_name, degree_type = EXCLUDED.degree_type;

    -- 4. Bulk Upsert Opportunities & update Vacancies records
    WITH batched_raw AS (
      SELECT * FROM public.rawsisu 
      ORDER BY "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA" 
      LIMIT p_limit OFFSET p_offset
    ),
    mapped_raw AS (
      SELECT 
        c.id AS course_id, 
        v_semester AS semester, 
        r."DS_TURNO" AS shift, 
        r."DS_MOD_CONCORRENCIA" AS concurrency_type,
        (SELECT tags FROM public.concurrency_tag_rules WHERE type_name = r."DS_MOD_CONCORRENCIA" LIMIT 1) AS concurrency_tags,
        v_year AS year, 
        'sisu'::text AS opportunity_type,
        CASE 
          WHEN r."NU_NOTACORTE" IS NULL OR TRIM(r."NU_NOTACORTE") = '' THEN NULL 
          ELSE REPLACE(REPLACE(TRIM(r."NU_NOTACORTE"), '.', ''), ',', '.')::numeric 
        END AS cutoff_score,
        replace(r."QT_INSCRICAO", '.', '') AS qt_inscricao,
        to_jsonb(r) AS raw_data
      FROM batched_raw r
      JOIN public.institutions i ON i.external_code = replace(r."CO_IES", '.', '')
      JOIN public.campus ca ON ca.institution_id = i.id AND ca.name = r."NO_CAMPUS"
      JOIN public.courses c ON c.campus_id = ca.id AND c.course_code = replace(r."CO_IES_CURSO", '.', '')
    ),
    mapped AS (
      SELECT DISTINCT ON (course_id, opportunity_type, year, semester, shift, concurrency_type) * 
      FROM mapped_raw 
      ORDER BY course_id, opportunity_type, year, semester, shift, concurrency_type, cutoff_score DESC
    ),
    upserted AS (
      INSERT INTO public.opportunities (
        course_id, semester, shift, concurrency_type, concurrency_tags, year, opportunity_type, cutoff_score, raw_data
      )
      SELECT course_id, semester, shift, concurrency_type, concurrency_tags, year, opportunity_type, cutoff_score, raw_data
      FROM mapped
      ON CONFLICT (course_id, opportunity_type, year, semester, shift, concurrency_type) 
      WHERE concurrency_type IS NOT NULL
      DO UPDATE SET
        cutoff_score = EXCLUDED.cutoff_score,
        concurrency_tags = EXCLUDED.concurrency_tags,
        raw_data = EXCLUDED.raw_data,
        updated_at = now()
      RETURNING id, course_id, shift, concurrency_type
    ),
    updated_vacancies AS (
      UPDATE public.opportunities_sisu_vacancies sv
      SET qt_inscricao = m.qt_inscricao, updated_at = now()
      FROM upserted u
      JOIN mapped m ON m.course_id = u.course_id AND m.shift = u.shift AND m.concurrency_type = u.concurrency_type
      WHERE sv.opportunity_id = u.id AND m.qt_inscricao IS NOT NULL
      RETURNING sv.opportunity_id
    )
    SELECT (SELECT count(*) FROM mapped_raw) INTO v_processed;
  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF p_limit IS NOT NULL THEN
    SELECT COUNT(*) INTO v_batch_rows FROM (
      SELECT 1 FROM public.rawsisu LIMIT p_limit OFFSET p_offset
    ) sub;
    v_has_more := (v_batch_rows = p_limit);
  ELSE
    v_has_more := FALSE;
  END IF;

  UPDATE public.etl_run_logs SET records_processed = COALESCE(records_processed, 0) + v_processed WHERE id = v_log_id
  RETURNING records_processed INTO v_total_processed_in_log;

  IF NOT v_has_more THEN
    SELECT COUNT(DISTINCT replace("CO_IES", '.', '')) INTO v_inst_count FROM public.rawsisu WHERE "CO_IES" IS NOT NULL;
    SELECT COUNT(DISTINCT (replace("CO_IES", '.', '') || '|' || "NO_CAMPUS")) INTO v_campus_count FROM public.rawsisu WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL;
    SELECT COUNT(DISTINCT replace("CO_IES_CURSO", '.', '')) INTO v_course_count FROM public.rawsisu WHERE "CO_IES_CURSO" IS NOT NULL;
    SELECT COUNT(*) INTO v_opp_count FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu';

    IF v_errors IS NULL THEN
      v_detail_msg := 'Sisu importado com sucesso.' || chr(10) || '• Linhas no arquivo raw:          ' || v_raw_count || chr(10) || '• IES distintas no arquivo:       ' || v_inst_count || chr(10) || '• Campus distintos:               ' || v_campus_count || chr(10) || '• Cursos distintos:               ' || v_course_count || chr(10) || '• Oportunidades no ciclo:         ' || v_opp_count;
      UPDATE public.etl_run_logs SET status = 'success', errors = v_detail_msg, finished_at = now() WHERE id = v_log_id;
      TRUNCATE TABLE public.rawsisu;
      
      -- Mark program as fully imported
      UPDATE public.programs SET is_fully_imported = true WHERE id = p_program_id;
    ELSE
      UPDATE public.etl_run_logs SET status = 'error', errors = v_errors, finished_at = now() WHERE id = v_log_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'has_more', v_has_more, 'log_id', v_log_id, 'total_raw_rows', v_raw_count, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id; END IF;
  RETURN jsonb_build_object('processed', 0, 'has_more', FALSE, 'status', 'error', 'errors', SQLERRM);
END;
$$;
