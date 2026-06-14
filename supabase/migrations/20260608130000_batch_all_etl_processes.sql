-- Add batch processing and progress tracking to all ETL processes
-- 20260608130000_batch_all_etl_processes.sql

-- ====================================================================================
-- 1. SiSU Vacancies
-- ====================================================================================
CREATE OR REPLACE FUNCTION public.etl_import_sisu_vacancies(
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
  v_rec               RECORD;
  v_inst_id           UUID;
  v_campus_id         UUID;
  v_course_id         UUID;
  v_opp_id            UUID;
  v_raw_count         INTEGER;
  v_skipped           INTEGER;
  v_vacancies_in_db   INTEGER;
  v_opps_with_vaga    INTEGER;
  v_opps_without_vaga INTEGER;
  v_opps_total        INTEGER;
  v_historical_prop   INTEGER;
  v_detail_msg        TEXT;
  v_has_more          BOOLEAN := FALSE;
  v_total_processed_in_log INTEGER := 0;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN
    RAISE EXCEPTION 'Program not found';
  END IF;

  SELECT COUNT(*) INTO v_raw_count FROM public.rawsisuvacancies;

  IF p_log_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed)
    VALUES (p_program_id, 'sisu_vacancies', 'running', now(), 0)
    RETURNING id INTO v_log_id;
  ELSE
    v_log_id := p_log_id;
  END IF;

  FOR v_rec IN
    SELECT DISTINCT "CO_IES"::text AS external_code, "NO_IES" AS name
    FROM (
      SELECT * FROM public.rawsisuvacancies
      ORDER BY "EDICAO", "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA"
      LIMIT p_limit OFFSET p_offset
    ) batch
    WHERE "CO_IES" IS NOT NULL
  LOOP
    BEGIN
      INSERT INTO public.institutions (external_code, name)
      VALUES (v_rec.external_code, v_rec.name)
      ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'IES: ' || SQLERRM, 1500);
    END;
  END LOOP;

  FOR v_rec IN
    SELECT DISTINCT ON ("CO_IES")
      "CO_IES"::text AS inst_external_code,
      "SG_IES" AS acronym,
      "DS_ORGANIZACAO_ACADEMICA" AS academic_organization,
      "DS_CATEGORIA_ADM" AS administrative_category
    FROM (
      SELECT * FROM public.rawsisuvacancies
      ORDER BY "EDICAO", "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA"
      LIMIT p_limit OFFSET p_offset
    ) batch
    WHERE "CO_IES" IS NOT NULL
  LOOP
    BEGIN
      SELECT id INTO v_inst_id FROM public.institutions WHERE external_code = v_rec.inst_external_code;
      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.institutions_info_sisu (institution_id, acronym, academic_organization, administrative_category)
        VALUES (v_inst_id, v_rec.acronym, v_rec.academic_organization, v_rec.administrative_category)
        ON CONFLICT (institution_id) DO UPDATE SET
          acronym = EXCLUDED.acronym, academic_organization = EXCLUDED.academic_organization, administrative_category = EXCLUDED.administrative_category, updated_at = now();
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Info: ' || SQLERRM, 1500);
    END;
  END LOOP;

  FOR v_rec IN
    SELECT DISTINCT "CO_IES"::text AS inst_external_code, "NO_CAMPUS" AS name, "NO_MUNICIPIO_CAMPUS" AS municipio, "SG_UF_CAMPUS" AS state, "DS_REGIAO" AS region
    FROM (
      SELECT * FROM public.rawsisuvacancies
      ORDER BY "EDICAO", "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA"
      LIMIT p_limit OFFSET p_offset
    ) batch
    WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL
  LOOP
    BEGIN
      SELECT id INTO v_inst_id FROM public.institutions WHERE external_code = v_rec.inst_external_code;
      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.campus (institution_id, name, city, state, region)
        VALUES (
          v_inst_id, v_rec.name,
          COALESCE((SELECT c.name FROM public.cities c WHERE public.f_unaccent(lower(c.name)) = public.f_unaccent(lower(v_rec.municipio)) AND c.state = v_rec.state LIMIT 1), v_rec.municipio),
          v_rec.state, v_rec.region
        ) ON CONFLICT (institution_id, name, city) DO UPDATE SET state = EXCLUDED.state, region = EXCLUDED.region;
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Campus: ' || SQLERRM, 1500);
    END;
  END LOOP;

  FOR v_rec IN
    SELECT DISTINCT "CO_IES"::text AS inst_external_code, "NO_CAMPUS" AS campus_name, "CO_IES_CURSO"::text AS course_code, "NO_CURSO" AS course_name, "DS_GRAU" AS degree_type
    FROM (
      SELECT * FROM public.rawsisuvacancies
      ORDER BY "EDICAO", "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA"
      LIMIT p_limit OFFSET p_offset
    ) batch
    WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL AND "CO_IES_CURSO" IS NOT NULL
  LOOP
    BEGIN
      SELECT ca.id INTO v_campus_id FROM public.campus ca JOIN public.institutions i ON i.id = ca.institution_id
      WHERE i.external_code = v_rec.inst_external_code AND ca.name = v_rec.campus_name LIMIT 1;

      IF v_campus_id IS NOT NULL THEN
        INSERT INTO public.courses (campus_id, course_code, course_name, degree_type)
        VALUES (v_campus_id, v_rec.course_code, v_rec.course_name, v_rec.degree_type)
        ON CONFLICT (campus_id, course_code) DO UPDATE SET course_name = EXCLUDED.course_name, degree_type = EXCLUDED.degree_type;
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Course: ' || SQLERRM, 1500);
    END;
  END LOOP;

  FOR v_rec IN
    SELECT "CO_IES"::text AS inst_external_code, "NO_CAMPUS" AS campus_name, "CO_IES_CURSO"::text AS course_code, "DS_TURNO" AS shift, "DS_MOD_CONCORRENCIA" AS concurrency_type, *
    FROM (
      SELECT * FROM public.rawsisuvacancies
      ORDER BY "EDICAO", "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA"
      LIMIT p_limit OFFSET p_offset
    ) batch
    WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL AND "CO_IES_CURSO" IS NOT NULL
  LOOP
    BEGIN
      SELECT c.id INTO v_course_id FROM public.courses c JOIN public.campus ca ON ca.id = c.campus_id JOIN public.institutions i ON i.id = ca.institution_id
      WHERE i.external_code = v_rec.inst_external_code AND ca.name = v_rec.campus_name AND c.course_code = v_rec.course_code LIMIT 1;

      IF v_course_id IS NOT NULL THEN
        INSERT INTO public.opportunities (course_id, semester, shift, concurrency_type, concurrency_tags, year, opportunity_type, cutoff_score, raw_data)
        VALUES (v_course_id, v_semester, v_rec.shift, v_rec.concurrency_type, (SELECT tags FROM public.concurrency_tag_rules WHERE type_name = v_rec.concurrency_type LIMIT 1), v_year, 'sisu', NULL, '{}'::jsonb)
        ON CONFLICT (course_id, opportunity_type, year, semester, shift, concurrency_type) WHERE concurrency_type IS NOT NULL
        DO UPDATE SET concurrency_tags = EXCLUDED.concurrency_tags, updated_at = now() RETURNING id INTO v_opp_id;

        IF v_opp_id IS NOT NULL THEN
          INSERT INTO public.opportunities_sisu_vacancies (opportunity_id, qt_semestre, nu_vagas_autorizadas, qt_vagas_ofertadas, nu_percentual_bonus, tp_mod_concorrencia, tp_cota, ds_mod_concorrencia, peso_redacao, nota_minima_redacao, peso_linguagens, nota_minima_linguagens, peso_matematica, nota_minima_matematica, peso_ciencias_humanas, nota_minima_ciencias_humanas, peso_ciencias_natureza, nota_minima_ciencias_natureza, nu_media_minima_enem, perc_uf_ibge_ppi, perc_uf_ibge_pp, perc_uf_ibge_i, perc_uf_ibge_q, perc_uf_ibge_pcd, nu_perc_lei, nu_perc_ppi, nu_perc_pp, nu_perc_i, nu_perc_q, nu_perc_pcd)
          VALUES (v_opp_id, v_rec."QT_SEMESTRE", v_rec."NU_VAGAS_AUTORIZADAS", v_rec."QT_VAGAS_OFERTADAS", v_rec."NU_PERCENTUAL_BONUS", v_rec."TP_MOD_CONCORRENCIA", v_rec."TP_COTA", v_rec."DS_MOD_CONCORRENCIA", COALESCE(NULLIF(REPLACE(v_rec."PESO_REDACAO", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_REDACAO", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."PESO_LINGUAGENS", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_LINGUAGENS", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."PESO_MATEMATICA", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_MATEMATICA", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."PESO_CIENCIAS_HUMANAS", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_CIENCIAS_HUMANAS", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."PESO_CIENCIAS_NATUREZA", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_CIENCIAS_NATUREZA", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."NU_MEDIA_MINIMA_ENEM", ',', '.'), ''), '0')::numeric, v_rec."PERC_UF_IBGE_PPI", v_rec."PERC_UF_IBGE_PP", v_rec."PERC_UF_IBGE_I", v_rec."PERC_UF_IBGE_Q", v_rec."PERC_UF_IBGE_PCD", v_rec."NU_PERC_LEI", v_rec."NU_PERC_PPI", v_rec."NU_PERC_PP", v_rec."NU_PERC_I", v_rec."NU_PERC_Q", v_rec."NU_PERC_PCD")
          ON CONFLICT (opportunity_id) DO UPDATE SET qt_semestre = EXCLUDED.qt_semestre, nu_vagas_autorizadas = EXCLUDED.nu_vagas_autorizadas, qt_vagas_ofertadas = EXCLUDED.qt_vagas_ofertadas, nu_percentual_bonus = EXCLUDED.nu_percentual_bonus, tp_mod_concorrencia = EXCLUDED.tp_mod_concorrencia, tp_cota = EXCLUDED.tp_cota, ds_mod_concorrencia = EXCLUDED.ds_mod_concorrencia, peso_redacao = EXCLUDED.peso_redacao, nota_minima_redacao = EXCLUDED.nota_minima_redacao, peso_linguagens = EXCLUDED.peso_linguagens, nota_minima_linguagens = EXCLUDED.nota_minima_linguagens, peso_matematica = EXCLUDED.peso_matematica, nota_minima_matematica = EXCLUDED.nota_minima_matematica, peso_ciencias_humanas = EXCLUDED.peso_ciencias_humanas, nota_minima_ciencias_humanas = EXCLUDED.nota_minima_ciencias_humanas, peso_ciencias_natureza = EXCLUDED.peso_ciencias_natureza, nota_minima_ciencias_natureza = EXCLUDED.nota_minima_ciencias_natureza, nu_media_minima_enem = EXCLUDED.nu_media_minima_enem, updated_at = now();

          v_processed := v_processed + 1;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Opp/Vaga: ' || SQLERRM, 1500);
    END;
  END LOOP;

  IF p_limit IS NOT NULL AND v_processed = p_limit THEN v_has_more := TRUE; END IF;

  UPDATE public.etl_run_logs SET records_processed = COALESCE(records_processed, 0) + v_processed WHERE id = v_log_id
  RETURNING records_processed INTO v_total_processed_in_log;

  IF NOT v_has_more THEN
    BEGIN
      UPDATE public.opportunities op_curr SET cutoff_score = op_prev.cutoff_score FROM public.opportunities op_prev
      WHERE op_curr.opportunity_type = 'sisu' AND op_curr.year = v_year AND op_curr.semester = v_semester AND op_prev.opportunity_type = 'sisu' AND op_prev.year = v_year - 1 AND op_prev.semester = v_semester AND op_curr.course_id = op_prev.course_id AND op_curr.shift = op_prev.shift AND op_curr.concurrency_type = op_prev.concurrency_type AND op_prev.cutoff_score IS NOT NULL AND op_curr.cutoff_score IS NULL;

      UPDATE public.opportunities_sisu_vacancies osv_curr SET vagas_ociosas_prev = osv_prev.vagas_ociosas_prev, qt_inscricao_prev = osv_prev.qt_inscricao_prev, qt_vagas_ofertadas_prev = osv_prev.qt_vagas_ofertadas FROM public.opportunities o_curr JOIN public.opportunities o_prev ON o_prev.course_id = o_curr.course_id AND o_prev.shift = o_curr.shift AND o_prev.concurrency_type = o_curr.concurrency_type AND o_prev.year = v_year - 1 AND o_prev.semester = v_semester AND o_prev.opportunity_type = 'sisu' JOIN public.opportunities_sisu_vacancies osv_prev ON osv_prev.opportunity_id = o_prev.id
      WHERE osv_curr.opportunity_id = o_curr.id AND o_curr.year = v_year AND o_curr.semester = v_semester AND o_curr.opportunity_type = 'sisu';

      GET DIAGNOSTICS v_historical_prop = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN v_historical_prop := 0; v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Propagation: ' || SQLERRM, 1500);
    END;

    v_skipped := v_raw_count - v_total_processed_in_log;
    SELECT COUNT(*) INTO v_vacancies_in_db FROM public.opportunities_sisu_vacancies osv JOIN public.opportunities o ON o.id = osv.opportunity_id WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu';
    SELECT COUNT(*) INTO v_opps_total FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu';
    SELECT COUNT(DISTINCT o.id) INTO v_opps_with_vaga FROM public.opportunities o JOIN public.opportunities_sisu_vacancies osv ON osv.opportunity_id = o.id WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu';
    v_opps_without_vaga := v_opps_total - v_opps_with_vaga;

    IF v_errors IS NULL THEN
      v_detail_msg := 'Vagas SiSU importadas com sucesso.' || chr(10) || '• Linhas no arquivo raw:          ' || v_raw_count || chr(10) || '• Vagas vinculadas (mapeadas):    ' || v_total_processed_in_log || chr(10) || '• Linhas ignoradas (s/ opp.):     ' || v_skipped || chr(10) || '• Registros em sisu_vacancies:    ' || v_vacancies_in_db || chr(10) || '• Oportunidades c/ vaga:          ' || v_opps_with_vaga || ' / ' || v_opps_total || chr(10) || '• Oportunidades s/ vaga:          ' || v_opps_without_vaga || chr(10) || '• Vagas c/ histórico propagado:   ' || COALESCE(v_historical_prop, 0);
      UPDATE public.etl_run_logs SET status = 'success', errors = v_detail_msg, finished_at = now() WHERE id = v_log_id;
      TRUNCATE TABLE public.rawsisuvacancies;
    ELSE
      UPDATE public.etl_run_logs SET status = 'error', errors = v_errors, finished_at = now() WHERE id = v_log_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('vacancies_processed', v_processed, 'has_more', v_has_more, 'log_id', v_log_id, 'total_raw_rows', v_raw_count, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN UPDATE public.etl_run_logs SET status = 'error', errors = LEFT(SQLERRM, 1500), finished_at = now() WHERE id = v_log_id; END IF;
  RETURN jsonb_build_object('processed', 0, 'has_more', FALSE, 'status', 'error', 'errors', SQLERRM);
END;
$$;


-- ====================================================================================
-- 2. SiSU Base
-- ====================================================================================
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
  v_rec               RECORD;
  v_course_id         UUID;
  v_raw_count         INTEGER;
  v_skipped           INTEGER;
  v_opps_with_cutoff  INTEGER;
  v_detail_msg        TEXT;
  v_has_more          BOOLEAN := FALSE;
  v_total_processed_in_log INTEGER := 0;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN RAISE EXCEPTION 'Program not found'; END IF;

  SELECT COUNT(*) INTO v_raw_count FROM public.rawsisu;

  IF p_log_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed)
    VALUES (p_program_id, 'sisu', 'running', now(), 0)
    RETURNING id INTO v_log_id;
  ELSE
    v_log_id := p_log_id;
  END IF;

  FOR v_rec IN
    SELECT "CO_IES"::text AS inst_external_code, "NO_CAMPUS" AS campus_name, "CO_IES_CURSO"::text AS course_code, "DS_TURNO" AS shift, "DS_MOD_CONCORRENCIA" AS concurrency_type, "NU_NOTACORTE" AS raw_cutoff, "QT_INSCRICAO" AS qt_inscricao, s
    FROM (
      SELECT * FROM public.rawsisu ORDER BY "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA" LIMIT p_limit OFFSET p_offset
    ) s
    WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL AND "CO_IES_CURSO" IS NOT NULL
  LOOP
    BEGIN
      SELECT c.id INTO v_course_id FROM public.courses c JOIN public.campus ca ON ca.id = c.campus_id JOIN public.institutions i ON i.id = ca.institution_id
      WHERE i.external_code = v_rec.inst_external_code AND ca.name = v_rec.campus_name AND c.course_code = v_rec.course_code LIMIT 1;

      IF v_course_id IS NOT NULL THEN
        INSERT INTO public.opportunities (course_id, semester, shift, concurrency_type, concurrency_tags, year, opportunity_type, cutoff_score, raw_data)
        VALUES (v_course_id, v_semester, v_rec.shift, v_rec.concurrency_type, (SELECT tags FROM public.concurrency_tag_rules WHERE type_name = v_rec.concurrency_type LIMIT 1), v_year, 'sisu',
          CASE WHEN v_rec.raw_cutoff IS NULL OR TRIM(v_rec.raw_cutoff) = '' THEN NULL ELSE REPLACE(REPLACE(TRIM(v_rec.raw_cutoff), '.', ''), ',', '.')::numeric END,
          to_jsonb(v_rec.s)
        )
        ON CONFLICT (course_id, opportunity_type, year, semester, shift, concurrency_type) WHERE concurrency_type IS NOT NULL
        DO UPDATE SET cutoff_score = EXCLUDED.cutoff_score, concurrency_tags = EXCLUDED.concurrency_tags, raw_data = EXCLUDED.raw_data, updated_at = now();

        v_processed := v_processed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || SQLERRM, 1500);
    END;
  END LOOP;

  IF p_limit IS NOT NULL AND v_processed = p_limit THEN v_has_more := TRUE; END IF;

  UPDATE public.etl_run_logs SET records_processed = COALESCE(records_processed, 0) + v_processed WHERE id = v_log_id
  RETURNING records_processed INTO v_total_processed_in_log;

  IF NOT v_has_more THEN
    v_skipped := v_raw_count - v_total_processed_in_log;
    SELECT COUNT(*) INTO v_opps_with_cutoff FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu' AND cutoff_score IS NOT NULL;

    IF v_errors IS NULL THEN
      v_detail_msg := 'Base SiSU importada com sucesso.' || chr(10) || '• Linhas no arquivo raw:          ' || v_raw_count || chr(10) || '• Linhas mapeadas (atualizadas):  ' || v_total_processed_in_log || chr(10) || '• Linhas ignoradas (s/ curso):    ' || v_skipped || chr(10) || '• Opps. com nota de corte:        ' || v_opps_with_cutoff;
      UPDATE public.etl_run_logs SET status = 'success', errors = v_detail_msg, finished_at = now() WHERE id = v_log_id;
      TRUNCATE TABLE public.rawsisu;
    ELSE
      UPDATE public.etl_run_logs SET status = 'error', errors = v_errors, finished_at = now() WHERE id = v_log_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('opportunities_processed', v_processed, 'has_more', v_has_more, 'log_id', v_log_id, 'total_raw_rows', v_raw_count, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id; END IF;
  RETURN jsonb_build_object('processed', 0, 'has_more', FALSE, 'status', 'error', 'errors', SQLERRM);
END;
$$;


-- ====================================================================================
-- 3. ProUni Base
-- ====================================================================================
CREATE OR REPLACE FUNCTION public.etl_import_prouni_base(
  p_program_id uuid,
  p_limit integer DEFAULT NULL,
  p_offset integer DEFAULT 0,
  p_log_id uuid DEFAULT NULL
)
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
  v_raw_count         INTEGER;
  v_inst_count        INTEGER;
  v_campus_count      INTEGER;
  v_course_count      INTEGER;
  v_opp_count         INTEGER;
  v_opp_integral      INTEGER;
  v_opp_parcial       INTEGER;
  v_opp_with_cutoff   INTEGER;
  v_detail_msg        TEXT;
  v_has_more          BOOLEAN := FALSE;
  v_total_processed_in_log INTEGER := 0;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN RAISE EXCEPTION 'Program not found'; END IF;

  SELECT COUNT(*) INTO v_raw_count FROM public.rawprouni;

  IF p_log_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed)
    VALUES (p_program_id, 'prouni_base', 'running', now(), 0)
    RETURNING id INTO v_log_id;
  ELSE
    v_log_id := p_log_id;
  END IF;

  BEGIN
    -- 1. Institutions
    INSERT INTO public.institutions (external_code, name)
    SELECT DISTINCT "CODIGO_IES"::text, "IES"
    FROM (SELECT * FROM public.rawprouni ORDER BY "CODIGO_IES", "CODIGO_CAMPUS", "CODIGO_CURSO", "CO_TURNO" LIMIT p_limit OFFSET p_offset) r
    WHERE "CODIGO_IES" IS NOT NULL
    ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name;

    -- 2. Campus
    INSERT INTO public.campus (institution_id, external_code, name, city, state)
    SELECT DISTINCT i.id AS institution_id, r."CODIGO_CAMPUS"::text AS external_code, r."CAMPUS" AS name, r."MUNICIPIO" AS city, r."UF" AS state
    FROM (SELECT * FROM public.rawprouni ORDER BY "CODIGO_IES", "CODIGO_CAMPUS", "CODIGO_CURSO", "CO_TURNO" LIMIT p_limit OFFSET p_offset) r
    JOIN public.institutions i ON i.external_code = r."CODIGO_IES"::text
    WHERE r."CODIGO_CAMPUS" IS NOT NULL
    ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name, city = EXCLUDED.city, state = EXCLUDED.state;

    -- 3. Courses
    INSERT INTO public.courses (campus_id, course_code, course_name)
    SELECT DISTINCT ca.id AS campus_id, r."CODIGO_CURSO"::text AS course_code, r."CURSO" AS course_name
    FROM (SELECT * FROM public.rawprouni ORDER BY "CODIGO_IES", "CODIGO_CAMPUS", "CODIGO_CURSO", "CO_TURNO" LIMIT p_limit OFFSET p_offset) r
    JOIN public.campus ca ON ca.external_code = r."CODIGO_CAMPUS"::text
    WHERE r."CODIGO_CURSO" IS NOT NULL
    ON CONFLICT (campus_id, course_code) DO UPDATE SET course_name = EXCLUDED.course_name;

    -- 4. Opportunities
    WITH batched_raw AS (
      SELECT * FROM public.rawprouni ORDER BY "CODIGO_IES", "CODIGO_CAMPUS", "CODIGO_CURSO", "CO_TURNO" LIMIT p_limit OFFSET p_offset
    ),
    mapped_raw AS (
      SELECT c.id AS course_id, r."SEMESTRE"::text AS semester, r."CO_TURNO" AS shift, r."TIPO_BOLSA" AS scholarship_type, v_year AS year, 'prouni' AS opportunity_type,
        CASE WHEN r."NOTA_DE_CORTE" IS NULL OR TRIM(r."NOTA_DE_CORTE") = '' THEN NULL ELSE REPLACE(REPLACE(TRIM(r."NOTA_DE_CORTE"), '.', ''), ',', '.')::numeric END AS cutoff_score,
        to_jsonb(r) AS raw_data
      FROM batched_raw r
      JOIN public.campus ca ON ca.external_code = r."CODIGO_CAMPUS"::text
      JOIN public.courses c ON c.campus_id = ca.id AND c.course_code = r."CODIGO_CURSO"::text
    ),
    mapped AS (
      SELECT DISTINCT ON (course_id, opportunity_type, year, semester, shift) * FROM mapped_raw ORDER BY course_id, opportunity_type, year, semester, shift, cutoff_score DESC
    ),
    updated AS (
      UPDATE public.opportunities o SET cutoff_score = m.cutoff_score, raw_data = m.raw_data, updated_at = now()
      FROM mapped m WHERE o.course_id = m.course_id AND o.opportunity_type = m.opportunity_type AND o.year = m.year AND o.semester = m.semester AND o.shift = m.shift
      RETURNING o.id
    ),
    inserted AS (
      INSERT INTO public.opportunities (course_id, semester, shift, scholarship_type, year, opportunity_type, cutoff_score, raw_data)
      SELECT m.course_id, m.semester, m.shift, m.scholarship_type, m.year, m.opportunity_type, m.cutoff_score, m.raw_data
      FROM mapped m WHERE NOT EXISTS (SELECT 1 FROM public.opportunities o WHERE o.course_id = m.course_id AND o.opportunity_type = m.opportunity_type AND o.year = m.year AND o.semester = m.semester AND o.shift = m.shift)
      RETURNING id
    )
    SELECT (SELECT count(*) FROM mapped_raw) INTO v_processed;

  EXCEPTION WHEN OTHERS THEN v_errors := SQLERRM;
  END;

  IF p_limit IS NOT NULL AND v_processed = p_limit THEN v_has_more := TRUE; END IF;
  IF v_processed = 0 THEN v_has_more := FALSE; END IF;

  UPDATE public.etl_run_logs SET records_processed = COALESCE(records_processed, 0) + v_processed WHERE id = v_log_id
  RETURNING records_processed INTO v_total_processed_in_log;

  IF NOT v_has_more THEN
    -- Tagging updates (bulk)
    UPDATE public.opportunities SET scholarship_tags = '[["BOLSA_INTEGRAL"]]'::jsonb WHERE opportunity_type = 'prouni' AND year = v_year AND semester = v_semester AND (scholarship_tags IS NULL OR scholarship_tags::text = 'null' OR jsonb_array_length(scholarship_tags) = 0) AND (UPPER(scholarship_type) LIKE '%INTEGRAL%' OR UPPER(scholarship_type) = 'BOLSA INTEGRAL');
    UPDATE public.opportunities SET scholarship_tags = '[["BOLSA_PARCIAL"]]'::jsonb WHERE opportunity_type = 'prouni' AND year = v_year AND semester = v_semester AND (scholarship_tags IS NULL OR scholarship_tags::text = 'null' OR jsonb_array_length(scholarship_tags) = 0) AND (UPPER(scholarship_type) LIKE '%PARCIAL%' OR UPPER(scholarship_type) LIKE '%50%' OR UPPER(scholarship_type) = 'BOLSA PARCIAL 50%');

    SELECT COUNT(DISTINCT "CODIGO_IES") INTO v_inst_count FROM public.rawprouni WHERE "CODIGO_IES" IS NOT NULL;
    SELECT COUNT(DISTINCT "CODIGO_CAMPUS") INTO v_campus_count FROM public.rawprouni WHERE "CODIGO_CAMPUS" IS NOT NULL;
    SELECT COUNT(DISTINCT "CODIGO_CURSO") INTO v_course_count FROM public.rawprouni WHERE "CODIGO_CURSO" IS NOT NULL;
    SELECT COUNT(*) INTO v_opp_count FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni';
    SELECT COUNT(*) INTO v_opp_integral FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni' AND scholarship_tags::text LIKE '%BOLSA_INTEGRAL%';
    SELECT COUNT(*) INTO v_opp_parcial FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni' AND scholarship_tags::text LIKE '%BOLSA_PARCIAL%';
    SELECT COUNT(*) INTO v_opp_with_cutoff FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni' AND cutoff_score IS NOT NULL;

    IF v_errors IS NULL THEN
      v_detail_msg := 'Base ProUni importada com sucesso.' || chr(10) || '• Linhas no arquivo raw:          ' || v_raw_count || chr(10) || '• IES distintas no arquivo:       ' || v_inst_count || chr(10) || '• Campus distintos:               ' || v_campus_count || chr(10) || '• Cursos distintos:               ' || v_course_count || chr(10) || '• Oportunidades no ciclo:         ' || v_opp_count || chr(10) || '• Bolsas integrais:               ' || v_opp_integral || chr(10) || '• Bolsas parciais:                ' || v_opp_parcial || chr(10) || '• Opps. com nota de corte:        ' || v_opp_with_cutoff;
      UPDATE public.etl_run_logs SET status = 'success', errors = v_detail_msg, finished_at = now() WHERE id = v_log_id;
      TRUNCATE TABLE public.rawprouni;
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


-- ====================================================================================
-- 4. ProUni Vacancies
-- ====================================================================================
CREATE OR REPLACE FUNCTION public.etl_import_prouni_vacancies(
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
  v_rec               RECORD;
  v_course_id         UUID;
  v_raw_count         INTEGER;
  v_skipped           INTEGER;
  v_vacancies_in_db   INTEGER;
  v_ampla_total       BIGINT;
  v_cota_total        BIGINT;
  v_detail_msg        TEXT;
  v_has_more          BOOLEAN := FALSE;
  v_total_processed_in_log INTEGER := 0;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester FROM public.programs WHERE id = p_program_id;
  IF v_year IS NULL THEN RAISE EXCEPTION 'Program not found'; END IF;
  SELECT COUNT(*) INTO v_raw_count FROM public.rawprounivacancies;

  IF p_log_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed) VALUES (p_program_id, 'prouni_vacancies', 'running', now(), 0) RETURNING id INTO v_log_id;
  ELSE v_log_id := p_log_id; END IF;

  FOR v_rec IN
    SELECT v."CO_CURSO"::text AS co_curso, v."CO_CAMPUS"::text AS co_campus, v."DS_TIPO_BOLSA", COALESCE(v."BOLSAS_AMPLA_OFERTADA"::integer, 0) AS bolsas_ampla_ofertada, COALESCE(v."BOLSAS_COTA_OFERTADA"::integer, 0) AS bolsas_cota_ofertada
    FROM (SELECT * FROM public.rawprounivacancies ORDER BY "CO_CURSO", "CO_CAMPUS", "DS_TIPO_BOLSA" LIMIT p_limit OFFSET p_offset) v
  LOOP
    BEGIN
      SELECT c.id INTO v_course_id FROM public.courses c JOIN public.campus ca ON ca.id = c.campus_id WHERE c.course_code = v_rec.co_curso AND ca.external_code = v_rec.co_campus LIMIT 1;
      IF v_course_id IS NOT NULL THEN
        INSERT INTO public.courses_prouni_vacancies (course_id, ds_tipo_bolsa, bolsas_ampla_ofertada, bolsas_cota_ofertada, year, semester)
        VALUES (v_course_id, v_rec."DS_TIPO_BOLSA", v_rec.bolsas_ampla_ofertada, v_rec.bolsas_cota_ofertada, v_year, v_semester)
        ON CONFLICT (course_id, ds_tipo_bolsa, year, semester) DO UPDATE SET bolsas_ampla_ofertada = EXCLUDED.bolsas_ampla_ofertada, bolsas_cota_ofertada = EXCLUDED.bolsas_cota_ofertada, updated_at = now();
        v_processed := v_processed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || SQLERRM, 1500);
    END;
  END LOOP;

  IF p_limit IS NOT NULL AND v_processed = p_limit THEN v_has_more := TRUE; END IF;

  UPDATE public.etl_run_logs SET records_processed = COALESCE(records_processed, 0) + v_processed WHERE id = v_log_id RETURNING records_processed INTO v_total_processed_in_log;

  IF NOT v_has_more THEN
    v_skipped := v_raw_count - v_total_processed_in_log;
    SELECT COUNT(*) INTO v_vacancies_in_db FROM public.courses_prouni_vacancies WHERE year = v_year AND semester = v_semester;
    SELECT COALESCE(SUM(bolsas_ampla_ofertada), 0) INTO v_ampla_total FROM public.courses_prouni_vacancies WHERE year = v_year AND semester = v_semester;
    SELECT COALESCE(SUM(bolsas_cota_ofertada), 0) INTO v_cota_total FROM public.courses_prouni_vacancies WHERE year = v_year AND semester = v_semester;

    IF v_errors IS NULL THEN
      v_detail_msg := 'Vagas ProUni importadas com sucesso.' || chr(10) || '• Linhas no arquivo raw:          ' || v_raw_count || chr(10) || '• Linhas mapeadas:                ' || v_total_processed_in_log || chr(10) || '• Linhas ignoradas (s/ curso):    ' || v_skipped || chr(10) || '• Registros em courses_prouni_vacancies: ' || v_vacancies_in_db || chr(10) || '• Total bolsas ampla concorrência: ' || v_ampla_total || chr(10) || '• Total bolsas cota:              ' || v_cota_total;
      UPDATE public.etl_run_logs SET status = 'success', errors = v_detail_msg, finished_at = now() WHERE id = v_log_id;
      TRUNCATE TABLE public.rawprounivacancies;
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


-- ====================================================================================
-- 5. ProUni Occupied
-- ====================================================================================
CREATE OR REPLACE FUNCTION public.etl_import_prouni_occupied(
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
  v_rec               RECORD;
  v_course_id         UUID;
  v_raw_count         INTEGER;
  v_skipped           INTEGER;
  v_ampla_ocupada     BIGINT;
  v_cota_ocupada      BIGINT;
  v_courses_with_occ  INTEGER;
  v_detail_msg        TEXT;
  v_has_more          BOOLEAN := FALSE;
  v_total_processed_in_log INTEGER := 0;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester FROM public.programs WHERE id = p_program_id;
  IF v_year IS NULL THEN RAISE EXCEPTION 'Program not found'; END IF;
  SELECT COUNT(*) INTO v_raw_count FROM public.rawprouniocuppied;

  IF p_log_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed) VALUES (p_program_id, 'prouni_occupied', 'running', now(), 0) RETURNING id INTO v_log_id;
  ELSE v_log_id := p_log_id; END IF;

  FOR v_rec IN
    SELECT o."CO_CURSO"::text AS co_curso, o."CO_CAMPUS"::text AS co_campus, o."DS_TIPO_BOLSA", COALESCE(o."BOLSAS_AMPLA_OCUPADA"::integer, 0) AS bolsas_ampla_ocupada, COALESCE(o."BOLSAS_COTA_OCUPADA"::integer, 0) AS bolsas_cota_ocupada
    FROM (SELECT * FROM public.rawprouniocuppied ORDER BY "CO_CURSO", "CO_CAMPUS", "DS_TIPO_BOLSA" LIMIT p_limit OFFSET p_offset) o
  LOOP
    BEGIN
      SELECT c.id INTO v_course_id FROM public.courses c JOIN public.campus ca ON ca.id = c.campus_id WHERE c.course_code = v_rec.co_curso AND ca.external_code = v_rec.co_campus LIMIT 1;
      IF v_course_id IS NOT NULL THEN
        INSERT INTO public.courses_prouni_vacancies (course_id, ds_tipo_bolsa, bolsas_ampla_ocupada, bolsas_cota_ocupada, year, semester)
        VALUES (v_course_id, v_rec."DS_TIPO_BOLSA", v_rec.bolsas_ampla_ocupada, v_rec.bolsas_cota_ocupada, v_year, v_semester)
        ON CONFLICT (course_id, ds_tipo_bolsa, year, semester) DO UPDATE SET bolsas_ampla_ocupada = EXCLUDED.bolsas_ampla_ocupada, bolsas_cota_ocupada = EXCLUDED.bolsas_cota_ocupada, updated_at = now();
        v_processed := v_processed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || SQLERRM, 1500);
    END;
  END LOOP;

  IF p_limit IS NOT NULL AND v_processed = p_limit THEN v_has_more := TRUE; END IF;

  UPDATE public.etl_run_logs SET records_processed = COALESCE(records_processed, 0) + v_processed WHERE id = v_log_id RETURNING records_processed INTO v_total_processed_in_log;

  IF NOT v_has_more THEN
    v_skipped := v_raw_count - v_total_processed_in_log;
    SELECT COALESCE(SUM(bolsas_ampla_ocupada), 0) INTO v_ampla_ocupada FROM public.courses_prouni_vacancies WHERE year = v_year AND semester = v_semester AND bolsas_ampla_ocupada > 0;
    SELECT COALESCE(SUM(bolsas_cota_ocupada), 0) INTO v_cota_ocupada FROM public.courses_prouni_vacancies WHERE year = v_year AND semester = v_semester AND bolsas_cota_ocupada > 0;
    SELECT COUNT(*) INTO v_courses_with_occ FROM public.courses_prouni_vacancies WHERE year = v_year AND semester = v_semester AND (bolsas_ampla_ocupada > 0 OR bolsas_cota_ocupada > 0);

    IF v_errors IS NULL THEN
      v_detail_msg := 'Ocupação ProUni importada com sucesso.' || chr(10) || '• Linhas no arquivo raw:          ' || v_raw_count || chr(10) || '• Linhas mapeadas:                ' || v_total_processed_in_log || chr(10) || '• Linhas ignoradas (s/ curso):    ' || v_skipped || chr(10) || '• Cursos com ocupação registrada: ' || v_courses_with_occ || chr(10) || '• Total bolsas ampla ocupadas:    ' || v_ampla_ocupada || chr(10) || '• Total bolsas cota ocupadas:     ' || v_cota_ocupada;
      UPDATE public.etl_run_logs SET status = 'success', errors = v_detail_msg, finished_at = now() WHERE id = v_log_id;
      TRUNCATE TABLE public.rawprouniocuppied;
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


-- ====================================================================================
-- 6. eMEC
-- ====================================================================================
CREATE OR REPLACE FUNCTION public.etl_import_emec(
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
  v_log_id              UUID;
  v_processed           INTEGER := 0;
  v_errors              TEXT;
  v_rec                 RECORD;
  v_inst_id             UUID;
  v_raw_count           INTEGER;
  v_unmatched           INTEGER;
  v_emec_total          INTEGER;
  v_with_igc            INTEGER;
  v_with_ci             INTEGER;
  v_federal             INTEGER;
  v_estadual            INTEGER;
  v_privado             INTEGER;
  v_detail_msg          TEXT;
  v_has_more            BOOLEAN := FALSE;
  v_total_processed_in_log INTEGER := 0;
BEGIN
  SELECT COUNT(DISTINCT "Código IES") INTO v_raw_count FROM public.rawemec WHERE "Código IES" IS NOT NULL;

  IF p_log_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed) VALUES (null, 'emec', 'running', now(), 0) RETURNING id INTO v_log_id;
  ELSE v_log_id := p_log_id; END IF;

  FOR v_rec IN
    SELECT DISTINCT ON ("Código IES")
      "Código IES"::text AS inst_external_code, "Código Mantenedora" AS maintainer_code, "Razão Social" AS maintainer_name, "CNPJ", "Natureza Jurídica" AS legal_nature, "Telefone" AS phone, "Sitio" AS site, "e-Mail" AS email, "Endereço Sede" AS address_seat, "Município" AS city, "UF" AS state, "Organização Acadêmica" AS academic_organization, "Tipo de Credenciamento" AS credentialing_type, "Categoria Administrativa" AS administrative_category, "Data do Ato de Criação da IES" AS creation_date_str, "CI", "Ano CI" AS ci_year, "CI-EaD", "Ano CI-EaD" AS ci_ead_year, "IGC", "Ano IGC" AS igc_year, "Reitor/Dirigente Principal" AS rector, "Representante Legal" AS legal_representative, "Sinalizações Vigentes" AS current_signs, "Situação da IES" AS status
    FROM (SELECT * FROM public.rawemec ORDER BY "Código IES" LIMIT p_limit OFFSET p_offset) r
    WHERE "Código IES" IS NOT NULL
  LOOP
    BEGIN
      SELECT id INTO v_inst_id FROM public.institutions WHERE external_code = v_rec.inst_external_code;
      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.institutions_info_emec (institution_id, maintainer_code, maintainer_name, cnpj, legal_nature, phone, site, email, address_seat, city, state, academic_organization, credentialing_type, administrative_category, creation_date, ci, ci_year, ci_ead, ci_ead_year, igc, igc_year, rector, legal_representative, current_signs, status)
        VALUES (v_inst_id, v_rec.maintainer_code, v_rec.maintainer_name, v_rec.cnpj, v_rec.legal_nature, v_rec.phone, v_rec.site, v_rec.email, v_rec.address_seat, v_rec.city, v_rec.state, v_rec.academic_organization, v_rec.credentialing_type, v_rec.administrative_category, CASE WHEN v_rec.creation_date_str ~ '^\d{4}-\d{2}-\d{2}$' THEN v_rec.creation_date_str::DATE ELSE NULL END, v_rec."CI", v_rec.ci_year, v_rec."CI-EaD", v_rec.ci_ead_year, v_rec."IGC", v_rec.igc_year, v_rec.rector, v_rec.legal_representative, v_rec.current_signs, v_rec.status)
        ON CONFLICT (institution_id) DO UPDATE SET maintainer_code = EXCLUDED.maintainer_code, maintainer_name = EXCLUDED.maintainer_name, cnpj = EXCLUDED.cnpj, legal_nature = EXCLUDED.legal_nature, phone = EXCLUDED.phone, site = EXCLUDED.site, email = EXCLUDED.email, address_seat = EXCLUDED.address_seat, city = EXCLUDED.city, state = EXCLUDED.state, academic_organization = EXCLUDED.academic_organization, credentialing_type = EXCLUDED.credentialing_type, administrative_category = EXCLUDED.administrative_category, creation_date = EXCLUDED.creation_date, ci = EXCLUDED.ci, ci_year = EXCLUDED.ci_year, ci_ead = EXCLUDED.ci_ead, ci_ead_year = EXCLUDED.ci_ead_year, igc = EXCLUDED.igc, igc_year = EXCLUDED.igc_year, rector = EXCLUDED.rector, legal_representative = EXCLUDED.legal_representative, current_signs = EXCLUDED.current_signs, status = EXCLUDED.status, updated_at = now();
        v_processed := v_processed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || SQLERRM, 1500);
    END;
  END LOOP;

  IF p_limit IS NOT NULL AND v_processed = p_limit THEN v_has_more := TRUE; END IF;

  UPDATE public.etl_run_logs SET records_processed = COALESCE(records_processed, 0) + v_processed WHERE id = v_log_id RETURNING records_processed INTO v_total_processed_in_log;

  IF NOT v_has_more THEN
    v_unmatched := v_raw_count - v_total_processed_in_log;
    SELECT COUNT(*) INTO v_emec_total FROM public.institutions_info_emec;
    SELECT COUNT(*) INTO v_with_igc FROM public.institutions_info_emec WHERE igc IS NOT NULL AND igc > 0;
    SELECT COUNT(*) INTO v_with_ci FROM public.institutions_info_emec WHERE ci IS NOT NULL AND ci > 0;
    SELECT COUNT(*) INTO v_federal FROM public.institutions_info_emec WHERE UPPER(administrative_category) LIKE '%FEDERAL%';
    SELECT COUNT(*) INTO v_estadual FROM public.institutions_info_emec WHERE UPPER(administrative_category) LIKE '%ESTADUAL%';
    SELECT COUNT(*) INTO v_privado FROM public.institutions_info_emec WHERE UPPER(administrative_category) LIKE '%PRIVAD%';

    IF v_errors IS NULL THEN
      v_detail_msg := 'Metadados e-MEC importados com sucesso.' || chr(10) || '• IES distintas no arquivo:       ' || v_raw_count || chr(10) || '• IES atualizadas (com match):    ' || v_total_processed_in_log || chr(10) || '• IES sem match (não cadastradas):' || v_unmatched || chr(10) || '• Total em institutions_info_emec:' || v_emec_total || chr(10) || '• IES com IGC:                    ' || v_with_igc || chr(10) || '• IES com CI:                     ' || v_with_ci || chr(10) || '• Federais / Estaduais / Privadas: ' || v_federal || ' / ' || v_estadual || ' / ' || v_privado;
      UPDATE public.etl_run_logs SET status = 'success', errors = v_detail_msg, finished_at = now() WHERE id = v_log_id;
      TRUNCATE TABLE public.rawemec;
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
