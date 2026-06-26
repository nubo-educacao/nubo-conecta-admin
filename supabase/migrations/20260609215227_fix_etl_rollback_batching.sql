-- 20260609215227_fix_etl_rollback_batching.sql
-- Optimizes the ETL rollback by introducing a batched execution logic to avoid statement timeouts.
-- Changes `etl_rollback_log` to accept `p_limit` and `p_active_rollback_id`, and to return `has_more`.

CREATE OR REPLACE FUNCTION public.etl_rollback_log(
  p_log_id uuid,
  p_limit integer DEFAULT 5000,
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
  -- Increase local statement timeout to 10 minutes to prevent timeouts within the chunk
  SET LOCAL statement_timeout = '10min';

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
    
    -- Reset the program's fully imported status since a step is being reverted
    UPDATE public.programs SET is_fully_imported = false WHERE id = v_program_id;
  END IF;

  BEGIN
    IF v_etl_type = 'sisu_vacancies' THEN
      -- Delete vacancies in batches
      DELETE FROM public.opportunities_sisu_vacancies sv
      WHERE sv.ctid IN (
        SELECT sv_inner.ctid FROM public.opportunities_sisu_vacancies sv_inner
        JOIN public.opportunities o ON sv_inner.opportunity_id = o.id
        WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu'
        LIMIT p_limit
      );
      GET DIAGNOSTICS v_vacancies_deleted = ROW_COUNT;

      -- If we didn't hit the limit on vacancies, we can delete opportunities
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
      -- Reset qt_inscricao in vacancies (complemented by Base SiSU) in batches
      -- Using a CTE for batches
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
        -- Delete opportunities created exclusively by Base SiSU
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

      IF (v_sisu_vac_updated + COALESCE(v_opps_deleted, 0)) < p_limit THEN
        -- Nullify cutoff_score and reset raw_data to '{}'::jsonb
        WITH to_update AS (
          SELECT o_inner.id FROM public.opportunities o_inner
          WHERE o_inner.year = v_year 
            AND o_inner.semester = v_semester 
            AND o_inner.opportunity_type = 'sisu'
            AND (o_inner.cutoff_score IS NOT NULL OR o_inner.raw_data <> '{}'::jsonb)
          LIMIT (p_limit - v_sisu_vac_updated - COALESCE(v_opps_deleted, 0))
        )
        UPDATE public.opportunities o
        SET cutoff_score = NULL, raw_data = '{}'::jsonb, updated_at = now()
        FROM to_update
        WHERE o.id = to_update.id;
        GET DIAGNOSTICS v_total_processed = ROW_COUNT; -- reusing variable just for counts
      END IF;

      v_has_more := (v_sisu_vac_updated + COALESCE(v_opps_deleted, 0) + COALESCE(v_total_processed, 0)) >= p_limit;

    ELSIF v_etl_type = 'prouni_vacancies' THEN
      -- Update rows where occupied exists to set offered to 0
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
        -- Delete rows where occupied doesn't exist
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
      -- Update rows where offered exists to set occupied to 0
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
        -- Delete rows where offered doesn't exist
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
      -- Delete vacancies
      DELETE FROM public.courses_prouni_vacancies pv
      WHERE pv.year = v_year AND pv.semester = v_semester
      AND pv.id IN (
        SELECT pv_inner.id FROM public.courses_prouni_vacancies pv_inner
        WHERE pv_inner.year = v_year AND pv_inner.semester = v_semester
        LIMIT p_limit
      );
      GET DIAGNOSTICS v_prouni_vac_deleted = ROW_COUNT;

      IF v_prouni_vac_deleted < p_limit THEN
        -- Delete opps
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
      RAISE EXCEPTION 'Unknown ETL type for rollback';
    END IF;

    -- Update logs
    v_total_processed := COALESCE(v_vacancies_deleted, 0) + COALESCE(v_opps_deleted, 0) + COALESCE(v_prouni_vac_deleted, 0) + COALESCE(v_prouni_vac_updated, 0) + COALESCE(v_sisu_vac_updated, 0);

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
