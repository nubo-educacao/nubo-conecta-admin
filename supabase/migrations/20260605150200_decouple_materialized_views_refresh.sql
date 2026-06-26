-- 20260605150200_decouple_materialized_views_refresh.sql

-- 1. Create independent functions for refreshing the views
CREATE OR REPLACE FUNCTION public.etl_import_refresh_opportunities()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_log_id UUID;
  v_errors TEXT;
BEGIN
  INSERT INTO public.etl_run_logs (etl_type, status, started_at)
  VALUES ('refresh_opportunities', 'running', now())
  RETURNING id INTO v_log_id;

  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.v_unified_opportunities;
  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF v_errors IS NULL THEN
    UPDATE public.etl_run_logs SET status = 'success', finished_at = now() WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs SET status = 'error', errors = v_errors, finished_at = now() WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object('status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('status', 'error', 'errors', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.etl_import_refresh_catalog()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_log_id UUID;
  v_errors TEXT;
BEGIN
  INSERT INTO public.etl_run_logs (etl_type, status, started_at)
  VALUES ('refresh_catalog', 'running', now())
  RETURNING id INTO v_log_id;

  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_course_catalog;
  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF v_errors IS NULL THEN
    UPDATE public.etl_run_logs SET status = 'success', finished_at = now() WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs SET status = 'error', errors = v_errors, finished_at = now() WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object('status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('status', 'error', 'errors', SQLERRM);
END;
$$;


-- 2. Remove REFRESH from etl_import_sisu_vacancies
CREATE OR REPLACE FUNCTION public.etl_import_sisu_vacancies(p_program_id uuid)
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
  v_opp_id            UUID;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN
    RAISE EXCEPTION 'Program not found';
  END IF;

  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (p_program_id, 'sisu_vacancies', 'running', now())
  RETURNING id INTO v_log_id;

  FOR v_rec IN
    SELECT
      "CO_IES"::text AS inst_external_code,
      "NO_CAMPUS" AS campus_name,
      "CO_IES_CURSO"::text AS course_code,
      "DS_TURNO" AS shift,
      "DS_MOD_CONCORRENCIA" AS concurrency_type,
      s
    FROM public.rawsisuvacancies s
    WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL AND "CO_IES_CURSO" IS NOT NULL
  LOOP
    BEGIN
      -- Resolve opportunity_id
      SELECT o.id INTO v_opp_id
      FROM public.opportunities o
      JOIN public.courses c ON c.id = o.course_id
      JOIN public.campus ca ON ca.id = c.campus_id
      JOIN public.institutions i ON i.id = ca.institution_id
      WHERE i.external_code = v_rec.inst_external_code
        AND ca.name = v_rec.campus_name
        AND c.course_code = v_rec.course_code
        AND o.shift = v_rec.shift
        AND o.opportunity_type = 'sisu'
        AND o.year = v_year
        AND o.semester = v_semester
      LIMIT 1;

      IF v_opp_id IS NOT NULL THEN
        INSERT INTO public.opportunities_sisu_vacancies (
          opportunity_id,
          qt_semestre, nu_vagas_autorizadas, qt_vagas_ofertadas,
          nu_percentual_bonus, tp_mod_concorrencia, tp_cota, ds_mod_concorrencia,
          peso_redacao, nota_minima_redacao,
          peso_linguagens, nota_minima_linguagens,
          peso_matematica, nota_minima_matematica,
          peso_ciencias_humanas, nota_minima_ciencias_humanas,
          peso_ciencias_natureza, nota_minima_ciencias_natureza,
          nu_media_minima_enem,
          perc_uf_ibge_ppi, perc_uf_ibge_pp, perc_uf_ibge_i, perc_uf_ibge_q, perc_uf_ibge_pcd,
          nu_perc_lei, nu_perc_ppi, nu_perc_pp, nu_perc_i, nu_perc_q, nu_perc_pcd
        )
        VALUES (
          v_opp_id,
          v_rec.s."QT_SEMESTRE",
          v_rec.s."NU_VAGAS_AUTORIZADAS",
          v_rec.s."QT_VAGAS_OFERTADAS",
          v_rec.s."NU_PERCENTUAL_BONUS",
          v_rec.s."TP_MOD_CONCORRENCIA",
          v_rec.s."TP_COTA",
          v_rec.s."DS_MOD_CONCORRENCIA",
          COALESCE(NULLIF(v_rec.s."PESO_REDACAO", ''), '0')::numeric,
          COALESCE(NULLIF(v_rec.s."NOTA_MINIMA_REDACAO", ''), '0')::numeric,
          COALESCE(NULLIF(v_rec.s."PESO_LINGUAGENS", ''), '0')::numeric,
          COALESCE(NULLIF(v_rec.s."NOTA_MINIMA_LINGUAGENS", ''), '0')::numeric,
          COALESCE(NULLIF(v_rec.s."PESO_MATEMATICA", ''), '0')::numeric,
          COALESCE(NULLIF(v_rec.s."NOTA_MINIMA_MATEMATICA", ''), '0')::numeric,
          COALESCE(NULLIF(v_rec.s."PESO_CIENCIAS_HUMANAS", ''), '0')::numeric,
          COALESCE(NULLIF(v_rec.s."NOTA_MINIMA_CIENCIAS_HUMANAS", ''), '0')::numeric,
          COALESCE(NULLIF(v_rec.s."PESO_CIENCIAS_NATUREZA", ''), '0')::numeric,
          COALESCE(NULLIF(v_rec.s."NOTA_MINIMA_CIENCIAS_NATUREZA", ''), '0')::numeric,
          COALESCE(NULLIF(v_rec.s."NU_MEDIA_MINIMA_ENEM", ''), '0')::numeric,
          v_rec.s."PERC_UF_IBGE_PPI",
          v_rec.s."PERC_UF_IBGE_PP",
          v_rec.s."PERC_UF_IBGE_I",
          v_rec.s."PERC_UF_IBGE_Q",
          v_rec.s."PERC_UF_IBGE_PCD",
          v_rec.s."NU_PERC_LEI",
          v_rec.s."NU_PERC_PPI",
          v_rec.s."NU_PERC_PP",
          v_rec.s."NU_PERC_i",
          v_rec.s."NU_PERC_Q",
          v_rec.s."NU_PERC_PCD"
        )
        ON CONFLICT (opportunity_id)
        DO UPDATE SET
          qt_semestre                   = EXCLUDED.qt_semestre,
          nu_vagas_autorizadas          = EXCLUDED.nu_vagas_autorizadas,
          qt_vagas_ofertadas            = EXCLUDED.qt_vagas_ofertadas,
          nu_percentual_bonus           = EXCLUDED.nu_percentual_bonus,
          tp_mod_concorrencia           = EXCLUDED.tp_mod_concorrencia,
          tp_cota                       = EXCLUDED.tp_cota,
          ds_mod_concorrencia           = EXCLUDED.ds_mod_concorrencia,
          peso_redacao                  = EXCLUDED.peso_redacao,
          nota_minima_redacao           = EXCLUDED.nota_minima_redacao,
          peso_linguagens               = EXCLUDED.peso_linguagens,
          nota_minima_linguagens        = EXCLUDED.nota_minima_linguagens,
          peso_matematica               = EXCLUDED.peso_matematica,
          nota_minima_matematica        = EXCLUDED.nota_minima_matematica,
          peso_ciencias_humanas         = EXCLUDED.peso_ciencias_humanas,
          nota_minima_ciencias_humanas  = EXCLUDED.nota_minima_ciencias_humanas,
          peso_ciencias_natureza        = EXCLUDED.peso_ciencias_natureza,
          nota_minima_ciencias_natureza = EXCLUDED.nota_minima_ciencias_natureza,
          nu_media_minima_enem          = EXCLUDED.nu_media_minima_enem,
          updated_at                    = now();

        v_processed := v_processed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN v_errors := SQLERRM; ELSE v_errors := v_errors || '; ' || SQLERRM; END IF;
    END;
  END LOOP;

  -- Propagação histórica (ano anterior → ano atual)
  BEGIN
    -- cutoff_score
    UPDATE public.opportunities op_curr
    SET cutoff_score = op_prev.cutoff_score
    FROM public.opportunities op_prev
    WHERE op_curr.opportunity_type = 'sisu' AND op_curr.year = v_year AND op_curr.semester = v_semester
      AND op_prev.opportunity_type = 'sisu' AND op_prev.year = v_year - 1 AND op_prev.semester = v_semester
      AND op_curr.course_id = op_prev.course_id
      AND op_curr.shift = op_prev.shift
      AND op_curr.concurrency_type = op_prev.concurrency_type
      AND op_prev.cutoff_score IS NOT NULL
      AND op_curr.cutoff_score IS NULL;

    -- vagas históricas
    UPDATE public.opportunities_sisu_vacancies osv_curr
    SET vagas_ociosas_prev      = osv_prev.vagas_ociosas_prev,
        qt_inscricao_prev       = osv_prev.qt_inscricao_prev,
        qt_vagas_ofertadas_prev = osv_prev.qt_vagas_ofertadas
    FROM public.opportunities o_curr
    JOIN public.opportunities o_prev
      ON o_prev.course_id = o_curr.course_id
     AND o_prev.shift = o_curr.shift
     AND o_prev.concurrency_type = o_curr.concurrency_type
     AND o_prev.year = v_year - 1
     AND o_prev.semester = v_semester
     AND o_prev.opportunity_type = 'sisu'
    JOIN public.opportunities_sisu_vacancies osv_prev ON osv_prev.opportunity_id = o_prev.id
    WHERE osv_curr.opportunity_id = o_curr.id
      AND o_curr.year = v_year
      AND o_curr.semester = v_semester
      AND o_curr.opportunity_type = 'sisu';
  EXCEPTION WHEN OTHERS THEN
    IF v_errors IS NULL THEN v_errors := 'Propagation: ' || SQLERRM; ELSE v_errors := v_errors || '; Propagation: ' || SQLERRM; END IF;
  END;

  IF v_errors IS NULL THEN
    UPDATE public.etl_run_logs SET status = 'success', records_processed = v_processed, finished_at = now() WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs SET status = 'error', records_processed = v_processed, errors = v_errors, finished_at = now() WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object(
    'vacancies_processed', v_processed,
    'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END,
    'errors', v_errors
  );
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$$;

-- 3. Remove REFRESH from etl_import_prouni_vacancies
CREATE OR REPLACE FUNCTION public.etl_import_prouni_vacancies(p_program_id uuid)
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
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN
    RAISE EXCEPTION 'Program not found';
  END IF;

  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (p_program_id, 'prouni_vacancies', 'running', now())
  RETURNING id INTO v_log_id;

  FOR v_rec IN 
    SELECT 
      v."CO_CURSO"::text AS co_curso,
      v."CO_CAMPUS"::text AS co_campus,
      v."DS_TIPO_BOLSA",
      COALESCE(v."BOLSAS_AMPLA_OFERTADA"::integer, 0) AS bolsas_ampla_ofertada,
      COALESCE(v."BOLSAS_COTA_OFERTADA"::integer, 0) AS bolsas_cota_ofertada
    FROM public.rawprounivacancies v
  LOOP
    BEGIN
      SELECT c.id INTO v_course_id
      FROM public.courses c
      JOIN public.campus ca ON ca.id = c.campus_id
      WHERE c.course_code = v_rec.co_curso
        AND ca.external_code = v_rec.co_campus
      LIMIT 1;

      IF v_course_id IS NULL THEN
        CONTINUE;
      END IF;

      INSERT INTO public.courses_prouni_vacancies (
        course_id, ds_tipo_bolsa,
        bolsas_ampla_ofertada, bolsas_cota_ofertada,
        year, semester
      )
      VALUES (
        v_course_id, v_rec."DS_TIPO_BOLSA",
        v_rec.bolsas_ampla_ofertada, v_rec.bolsas_cota_ofertada,
        v_year, v_semester
      )
      ON CONFLICT (course_id, ds_tipo_bolsa, year, semester)
      DO UPDATE SET
        bolsas_ampla_ofertada = EXCLUDED.bolsas_ampla_ofertada,
        bolsas_cota_ofertada  = EXCLUDED.bolsas_cota_ofertada,
        updated_at            = now();

      v_processed := v_processed + 1;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN v_errors := SQLERRM; ELSE v_errors := v_errors || '; ' || SQLERRM; END IF;
    END;
  END LOOP;

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

-- 4. Remove REFRESH from etl_import_prouni_occupied
CREATE OR REPLACE FUNCTION public.etl_import_prouni_occupied(p_program_id uuid)
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
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN
    RAISE EXCEPTION 'Program not found';
  END IF;

  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (p_program_id, 'prouni_occupied', 'running', now())
  RETURNING id INTO v_log_id;

  FOR v_rec IN 
    SELECT 
      o."CO_CURSO"::text AS co_curso,
      o."CO_CAMPUS"::text AS co_campus,
      o."DS_TIPO_BOLSA",
      COALESCE(o."BOLSAS_AMPLA_OCUPADA"::integer, 0) AS bolsas_ampla_ocupada,
      COALESCE(o."BOLSAS_COTA_OCUPADA"::integer, 0) AS bolsas_cota_ocupada
    FROM public.rawprouniocuppied o
  LOOP
    BEGIN
      SELECT c.id INTO v_course_id
      FROM public.courses c
      JOIN public.campus ca ON ca.id = c.campus_id
      WHERE c.course_code = v_rec.co_curso
        AND ca.external_code = v_rec.co_campus
      LIMIT 1;

      IF v_course_id IS NULL THEN
        CONTINUE;
      END IF;

      INSERT INTO public.courses_prouni_vacancies (
        course_id, ds_tipo_bolsa,
        bolsas_ampla_ocupada, bolsas_cota_ocupada,
        year, semester
      )
      VALUES (
        v_course_id, v_rec."DS_TIPO_BOLSA",
        v_rec.bolsas_ampla_ocupada, v_rec.bolsas_cota_ocupada,
        v_year, v_semester
      )
      ON CONFLICT (course_id, ds_tipo_bolsa, year, semester)
      DO UPDATE SET
        bolsas_ampla_ocupada = EXCLUDED.bolsas_ampla_ocupada,
        bolsas_cota_ocupada  = EXCLUDED.bolsas_cota_ocupada,
        updated_at           = now();

      v_processed := v_processed + 1;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN v_errors := SQLERRM; ELSE v_errors := v_errors || '; ' || SQLERRM; END IF;
    END;
  END LOOP;

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
