-- 20260612132943_fix_etl_rollback_batch_size.sql
-- Reduces default batch size in etl_rollback_log to avoid PostgREST statement timeouts.
-- The PostgREST gateway has a hard ~15s HTTP timeout that cannot be overridden by SET LOCAL.
-- With 500 rows per batch (instead of 5000), each call completes well within that limit.

CREATE OR REPLACE FUNCTION public.etl_rollback_log(
  p_log_id uuid,
  p_limit integer DEFAULT 500,
  p_active_rollback_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_program_id uuid;
  v_etl_type text;
  v_status text;
  v_year integer;
  v_semester text;
  v_new_log_id uuid;
  v_new_etl_type text;
  v_detail_msg text;
  
  -- Counters
  v_opps_deleted integer := 0;
  v_vacancies_deleted integer := 0;
  v_prouni_vac_deleted integer := 0;
  v_prouni_vac_updated integer := 0;
  v_sisu_vac_updated integer := 0;

  v_has_more boolean := false;
  v_total_processed integer := 0;
BEGIN
  -- Fetch details of the log we are rolling back
  SELECT program_id, etl_type, status INTO v_program_id, v_etl_type, v_status
  FROM public.etl_run_logs WHERE id = p_log_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Log not found';
  END IF;

  IF v_status = 'running' THEN
    RAISE EXCEPTION 'Cannot rollback a running ETL operation';
  END IF;

  IF v_etl_type LIKE 'rollback_%' THEN
    RAISE EXCEPTION 'Cannot rollback a rollback operation';
  END IF;

  v_new_etl_type := 'rollback_' || v_etl_type;

  -- Create or reuse the rollback log entry
  IF p_active_rollback_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed)
    VALUES (v_program_id, v_new_etl_type, 'running', now(), 0)
    RETURNING id INTO v_new_log_id;
  ELSE
    v_new_log_id := p_active_rollback_id;
  END IF;

  IF v_program_id IS NOT NULL THEN
    SELECT cycle_year, cycle_semester INTO v_year, v_semester
    FROM public.programs WHERE id = v_program_id;
    
    UPDATE public.programs SET is_fully_imported = false WHERE id = v_program_id;
  END IF;

  BEGIN
    IF v_etl_type = 'sisu_vacancies' THEN
      DELETE FROM public.opportunities_sisu_vacancies sv
      WHERE sv.ctid IN (
        SELECT sv_inner.ctid FROM public.opportunities_sisu_vacancies sv_inner
        JOIN public.opportunities o ON sv_inner.opportunity_id = o.id
        WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu'
        LIMIT p_limit
      );
      GET DIAGNOSTICS v_vacancies_deleted = ROW_COUNT;

      IF v_vacancies_deleted < p_limit THEN
        DELETE FROM public.opportunities o
        WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu'
        AND o.id IN (
          SELECT o_inner.id FROM public.opportunities o_inner
          WHERE o_inner.year = v_year AND o_inner.semester = v_semester AND o_inner.opportunity_type = 'sisu'
          LIMIT (p_limit - v_vacancies_deleted)
        );
        GET DIAGNOSTICS v_opps_deleted = ROW_COUNT;
      END IF;

      v_has_more := (v_vacancies_deleted + COALESCE(v_opps_deleted, 0)) >= p_limit;

    ELSIF v_etl_type = 'sisu' THEN
      WITH to_update AS (
        SELECT sv_inner.opportunity_id, sv_inner.tp_mod_concorrencia 
        FROM public.opportunities_sisu_vacancies sv_inner
        JOIN public.opportunities o ON sv_inner.opportunity_id = o.id
        WHERE o.year = v_year 
          AND o.semester = v_semester 
          AND o.opportunity_type = 'sisu'
          AND sv_inner.qt_inscricao IS NOT NULL
        LIMIT p_limit
      )
      UPDATE public.opportunities_sisu_vacancies sv
      SET qt_inscricao = NULL, updated_at = now()
      FROM to_update
      WHERE sv.opportunity_id = to_update.opportunity_id AND sv.tp_mod_concorrencia = to_update.tp_mod_concorrencia;
      GET DIAGNOSTICS v_sisu_vac_updated = ROW_COUNT;

      IF v_sisu_vac_updated < p_limit THEN
        DELETE FROM public.opportunities o
        WHERE o.year = v_year 
          AND o.semester = v_semester 
          AND o.opportunity_type = 'sisu'
          AND NOT EXISTS (
            SELECT 1 FROM public.opportunities_sisu_vacancies sv 
            WHERE sv.opportunity_id = o.id
          )
        AND o.id IN (
          SELECT o_inner.id FROM public.opportunities o_inner
          WHERE o_inner.year = v_year 
            AND o_inner.semester = v_semester 
            AND o_inner.opportunity_type = 'sisu'
            AND NOT EXISTS (
              SELECT 1 FROM public.opportunities_sisu_vacancies sv_inner 
              WHERE sv_inner.opportunity_id = o_inner.id
            )
          LIMIT (p_limit - v_sisu_vac_updated)
        );
        GET DIAGNOSTICS v_opps_deleted = ROW_COUNT;
      END IF;

      v_has_more := (v_sisu_vac_updated + COALESCE(v_opps_deleted, 0)) >= p_limit;

    ELSIF v_etl_type = 'prouni_vacancies' THEN
      WITH to_update AS (
        SELECT pv_inner.id FROM public.courses_prouni_vacancies pv_inner
        WHERE pv_inner.year = v_year AND pv_inner.semester = v_semester
          AND (COALESCE(pv_inner.bolsas_ampla_ocupada, 0) > 0 OR COALESCE(pv_inner.bolsas_cota_ocupada, 0) > 0)
          AND (COALESCE(pv_inner.bolsas_ampla_ofertada, 0) > 0 OR COALESCE(pv_inner.bolsas_cota_ofertada, 0) > 0)
        LIMIT p_limit
      )
      UPDATE public.courses_prouni_vacancies pv
      SET bolsas_ampla_ofertada = 0, bolsas_cota_ofertada = 0
      FROM to_update
      WHERE pv.id = to_update.id;
      GET DIAGNOSTICS v_prouni_vac_updated = ROW_COUNT;

      IF v_prouni_vac_updated < p_limit THEN
        DELETE FROM public.courses_prouni_vacancies pv
        WHERE pv.year = v_year AND pv.semester = v_semester
          AND COALESCE(pv.bolsas_ampla_ocupada, 0) = 0 
          AND COALESCE(pv.bolsas_cota_ocupada, 0) = 0
        AND pv.id IN (
          SELECT pv_inner.id FROM public.courses_prouni_vacancies pv_inner
          WHERE pv_inner.year = v_year AND pv_inner.semester = v_semester
            AND COALESCE(pv_inner.bolsas_ampla_ocupada, 0) = 0 
            AND COALESCE(pv_inner.bolsas_cota_ocupada, 0) = 0
          LIMIT (p_limit - v_prouni_vac_updated)
        );
        GET DIAGNOSTICS v_prouni_vac_deleted = ROW_COUNT;
      END IF;

      v_has_more := (v_prouni_vac_updated + COALESCE(v_prouni_vac_deleted, 0)) >= p_limit;

    ELSIF v_etl_type = 'prouni_occupied' THEN
      WITH to_update AS (
        SELECT pv_inner.id FROM public.courses_prouni_vacancies pv_inner
        WHERE pv_inner.year = v_year AND pv_inner.semester = v_semester
          AND (COALESCE(pv_inner.bolsas_ampla_ofertada, 0) > 0 OR COALESCE(pv_inner.bolsas_cota_ofertada, 0) > 0)
          AND (COALESCE(pv_inner.bolsas_ampla_ocupada, 0) > 0 OR COALESCE(pv_inner.bolsas_cota_ocupada, 0) > 0)
        LIMIT p_limit
      )
      UPDATE public.courses_prouni_vacancies pv
      SET bolsas_ampla_ocupada = 0, bolsas_cota_ocupada = 0
      FROM to_update
      WHERE pv.id = to_update.id;
      GET DIAGNOSTICS v_prouni_vac_updated = ROW_COUNT;

      IF v_prouni_vac_updated < p_limit THEN
        DELETE FROM public.courses_prouni_vacancies pv
        WHERE pv.year = v_year AND pv.semester = v_semester
          AND COALESCE(pv.bolsas_ampla_ofertada, 0) = 0 
          AND COALESCE(pv.bolsas_cota_ofertada, 0) = 0
        AND pv.id IN (
          SELECT pv_inner.id FROM public.courses_prouni_vacancies pv_inner
          WHERE pv_inner.year = v_year AND pv_inner.semester = v_semester
            AND COALESCE(pv_inner.bolsas_ampla_ofertada, 0) = 0 
            AND COALESCE(pv_inner.bolsas_cota_ofertada, 0) = 0
          LIMIT (p_limit - v_prouni_vac_updated)
        );
        GET DIAGNOSTICS v_prouni_vac_deleted = ROW_COUNT;
      END IF;

      v_has_more := (v_prouni_vac_updated + COALESCE(v_prouni_vac_deleted, 0)) >= p_limit;

    ELSIF v_etl_type = 'prouni_base' THEN
      DELETE FROM public.courses_prouni_vacancies pv
      WHERE pv.year = v_year AND pv.semester = v_semester
      AND pv.id IN (
        SELECT pv_inner.id FROM public.courses_prouni_vacancies pv_inner
        WHERE pv_inner.year = v_year AND pv_inner.semester = v_semester
        LIMIT p_limit
      );
      GET DIAGNOSTICS v_prouni_vac_deleted = ROW_COUNT;

      IF v_prouni_vac_deleted < p_limit THEN
        DELETE FROM public.opportunities o
        WHERE o.year = v_year 
          AND o.semester = v_semester 
          AND o.opportunity_type = 'prouni'
        AND o.id IN (
          SELECT o_inner.id FROM public.opportunities o_inner
          WHERE o_inner.year = v_year 
            AND o_inner.semester = v_semester 
            AND o_inner.opportunity_type = 'prouni'
          LIMIT (p_limit - v_prouni_vac_deleted)
        );
        GET DIAGNOSTICS v_opps_deleted = ROW_COUNT;
      END IF;

      v_has_more := (v_prouni_vac_deleted + COALESCE(v_opps_deleted, 0)) >= p_limit;

    ELSIF v_etl_type = 'emec' OR v_etl_type LIKE 'refresh_%' THEN
      RAISE EXCEPTION 'Cannot rollback global or refresh ETL operations';
    ELSE
      RAISE EXCEPTION 'Unknown ETL type for rollback: %', v_etl_type;
    END IF;

    v_total_processed := COALESCE(v_vacancies_deleted, 0) + COALESCE(v_opps_deleted, 0) 
      + COALESCE(v_prouni_vac_deleted, 0) + COALESCE(v_prouni_vac_updated, 0) 
      + COALESCE(v_sisu_vac_updated, 0);

    UPDATE public.etl_run_logs 
    SET records_processed = records_processed + v_total_processed
    WHERE id = v_new_log_id;

    IF NOT v_has_more THEN
      v_detail_msg := 'Rollback concluído com sucesso.' || E'\n' ||
                      '• Ciclo: ' || COALESCE(v_year::text, '?') || '.' || COALESCE(v_semester, '?') || E'\n' ||
                      '• Log de origem: ' || p_log_id::text;
                      
      UPDATE public.etl_run_logs 
      SET status = 'success', 
          errors = v_detail_msg,
          finished_at = now() 
      WHERE id = v_new_log_id;
    END IF;

    RETURN jsonb_build_object(
      'status', 'success',
      'message', 'Rollback batch processed.',
      'processed', v_total_processed,
      'has_more', v_has_more,
      'log_id', v_new_log_id
    );
  EXCEPTION WHEN OTHERS THEN
    UPDATE public.etl_run_logs 
    SET status = 'error', 
        errors = SQLERRM, 
        finished_at = now() 
    WHERE id = v_new_log_id;
    
    RAISE EXCEPTION 'Rollback failed: %', SQLERRM;
  END;
END;
$$;
