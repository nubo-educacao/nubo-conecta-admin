-- 20260609204300_optimize_etl_rollback_indexes_and_logic.sql
-- Optimizes the ETL rollback queries by adding indexes to prevent performance timeouts,
-- and updates the etl_rollback_log logic to target only Base SiSU complementary data (leaving Vagas SiSU intact).

-- 1. Create indexes to speed up lookup/updates in target tables
CREATE INDEX IF NOT EXISTS idx_opportunities_year_semester_type 
ON public.opportunities (year, semester, opportunity_type);

CREATE INDEX IF NOT EXISTS idx_opp_sisu_vacancies_opp_id 
ON public.opportunities_sisu_vacancies (opportunity_id);

CREATE INDEX IF NOT EXISTS idx_prouni_vacancies_year_semester 
ON public.courses_prouni_vacancies (year, semester);

-- 2. Redefine etl_rollback_log with optimized sisu logic and execution timing
CREATE OR REPLACE FUNCTION public.etl_rollback_log(p_log_id uuid)
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
  v_opps_before integer := 0;
  v_opps_after integer := 0;
  v_opps_deleted integer := 0;
  
  v_vacancies_before integer := 0;
  v_vacancies_after integer := 0;
  v_vacancies_deleted integer := 0;
  
  v_prouni_vac_before integer := 0;
  v_prouni_vac_after integer := 0;
  v_prouni_vac_deleted integer := 0;
  v_prouni_vac_updated integer := 0;
  v_sisu_vac_updated integer := 0;
BEGIN
  -- Increase local statement timeout to 10 minutes to prevent timeouts
  SET LOCAL statement_timeout = '10min';

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

  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (v_program_id, v_new_etl_type, 'running', now())
  RETURNING id INTO v_new_log_id;

  IF v_program_id IS NOT NULL THEN
    SELECT cycle_year, cycle_semester INTO v_year, v_semester
    FROM public.programs WHERE id = v_program_id;
  END IF;

  BEGIN
    IF v_etl_type = 'sisu_vacancies' THEN
      -- Count before
      SELECT COUNT(*) INTO v_vacancies_before
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities o ON sv.opportunity_id = o.id
      WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu';

      SELECT COUNT(*) INTO v_opps_before
      FROM public.opportunities 
      WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu';

      -- Vagas SiSU is responsible for setup, so rollback deletes BOTH vacancies and opps.
      -- 1. Delete vacancies
      DELETE FROM public.opportunities_sisu_vacancies sv
      USING public.opportunities o
      WHERE sv.opportunity_id = o.id
        AND o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu';
        
      -- 2. Delete opps
      DELETE FROM public.opportunities 
      WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu';
      
      -- Count after
      SELECT COUNT(*) INTO v_vacancies_after
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities o ON sv.opportunity_id = o.id
      WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu';

      SELECT COUNT(*) INTO v_opps_after
      FROM public.opportunities 
      WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu';

      v_vacancies_deleted := v_vacancies_before - v_vacancies_after;
      v_opps_deleted := v_opps_before - v_opps_after;

      v_detail_msg := 'Rollback de Vagas SiSU concluído com sucesso.' || E'\n' ||
                      '• Ciclo: ' || COALESCE(v_year::text, '?') || '.' || COALESCE(v_semester, '?') || E'\n' ||
                      '• Registros de vagas removidos: ' || v_vacancies_deleted || E'\n' ||
                      '• Oportunidades (Base) removidas: ' || v_opps_deleted || E'\n' ||
                      '• Log de origem: ' || p_log_id::text;

    ELSIF v_etl_type = 'sisu' THEN
      -- Base SiSU only complements Vagas SiSU:
      
      -- 1. Count statistics before
      SELECT COUNT(*) INTO v_opps_before
      FROM public.opportunities 
      WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu' 
        AND (cutoff_score IS NOT NULL OR raw_data <> '{}'::jsonb);

      -- 2. Reset qt_inscricao in vacancies (complemented by Base SiSU)
      UPDATE public.opportunities_sisu_vacancies sv
      SET qt_inscricao = NULL, updated_at = now()
      FROM public.opportunities o
      WHERE sv.opportunity_id = o.id
        AND o.year = v_year 
        AND o.semester = v_semester 
        AND o.opportunity_type = 'sisu';
      GET DIAGNOSTICS v_sisu_vac_updated = ROW_COUNT;

      -- 3. Delete opportunities created exclusively by Base SiSU (without any vacancy record)
      DELETE FROM public.opportunities o
      WHERE o.year = v_year 
        AND o.semester = v_semester 
        AND o.opportunity_type = 'sisu'
        AND NOT EXISTS (
          SELECT 1 FROM public.opportunities_sisu_vacancies sv 
          WHERE sv.opportunity_id = o.id
        );
      GET DIAGNOSTICS v_opps_deleted = ROW_COUNT;

      -- 4. Nullify cutoff_score and reset raw_data to '{}'::jsonb for opportunities that have a corresponding vacancy (so they remain as they were in Vagas SiSU)
      UPDATE public.opportunities 
      SET cutoff_score = NULL, raw_data = '{}'::jsonb, updated_at = now()
      WHERE year = v_year 
        AND semester = v_semester 
        AND opportunity_type = 'sisu'
        AND (cutoff_score IS NOT NULL OR raw_data <> '{}'::jsonb);

      v_detail_msg := 'Rollback de Base SiSU concluído com sucesso.' || E'\n' ||
                      '• Ciclo: ' || COALESCE(v_year::text, '?') || '.' || COALESCE(v_semester, '?') || E'\n' ||
                      '• Quantidade de inscrições (Sisu Vacancies) anuladas: ' || v_sisu_vac_updated || E'\n' ||
                      '• Oportunidades criadas pelo Base SiSU e excluídas: ' || v_opps_deleted || E'\n' ||
                      '• Oportunidades do Vagas SiSU restauradas ao estado original: ' || v_opps_before || E'\n' ||
                      '• Log de origem: ' || p_log_id::text;

    ELSIF v_etl_type = 'prouni_vacancies' THEN
      -- Count before
      SELECT COUNT(*) INTO v_prouni_vac_before
      FROM public.courses_prouni_vacancies
      WHERE year = v_year AND semester = v_semester;

      -- Update rows where occupied exists to set offered to 0
      UPDATE public.courses_prouni_vacancies
      SET bolsas_ampla_ofertada = 0, bolsas_cota_ofertada = 0
      WHERE year = v_year AND semester = v_semester
        AND (COALESCE(bolsas_ampla_ocupada, 0) > 0 OR COALESCE(bolsas_cota_ocupada, 0) > 0);
      GET DIAGNOSTICS v_prouni_vac_updated = ROW_COUNT;

      -- Delete rows where occupied doesn't exist
      DELETE FROM public.courses_prouni_vacancies
      WHERE year = v_year AND semester = v_semester
        AND COALESCE(bolsas_ampla_ocupada, 0) = 0 
        AND COALESCE(bolsas_cota_ocupada, 0) = 0;

      -- Count after
      SELECT COUNT(*) INTO v_prouni_vac_after
      FROM public.courses_prouni_vacancies
      WHERE year = v_year AND semester = v_semester;

      v_prouni_vac_deleted := v_prouni_vac_before - v_prouni_vac_after;

      v_detail_msg := 'Rollback de Vagas ProUni concluído com sucesso.' || E'\n' ||
                      '• Ciclo: ' || COALESCE(v_year::text, '?') || '.' || COALESCE(v_semester, '?') || E'\n' ||
                      '• Registros de vagas zerados: ' || v_prouni_vac_updated || E'\n' ||
                      '• Registros de vagas deletados: ' || v_prouni_vac_deleted || E'\n' ||
                      '• Log de origem: ' || p_log_id::text;

    ELSIF v_etl_type = 'prouni_occupied' THEN
      -- Count before
      SELECT COUNT(*) INTO v_prouni_vac_before
      FROM public.courses_prouni_vacancies
      WHERE year = v_year AND semester = v_semester;

      -- Update rows where offered exists to set occupied to 0
      UPDATE public.courses_prouni_vacancies
      SET bolsas_ampla_ocupada = 0, bolsas_cota_ocupada = 0
      WHERE year = v_year AND semester = v_semester
        AND (COALESCE(bolsas_ampla_ofertada, 0) > 0 OR COALESCE(bolsas_cota_ofertada, 0) > 0);
      GET DIAGNOSTICS v_prouni_vac_updated = ROW_COUNT;

      -- Delete rows where offered doesn't exist
      DELETE FROM public.courses_prouni_vacancies
      WHERE year = v_year AND semester = v_semester
        AND COALESCE(bolsas_ampla_ofertada, 0) = 0 
        AND COALESCE(bolsas_cota_ocupada, 0) = 0;

      -- Count after
      SELECT COUNT(*) INTO v_prouni_vac_after
      FROM public.courses_prouni_vacancies
      WHERE year = v_year AND semester = v_semester;

      v_prouni_vac_deleted := v_prouni_vac_before - v_prouni_vac_after;

      v_detail_msg := 'Rollback de Ocupação ProUni concluído com sucesso.' || E'\n' ||
                      '• Ciclo: ' || COALESCE(v_year::text, '?') || '.' || COALESCE(v_semester, '?') || E'\n' ||
                      '• Registros de ocupação zerados: ' || v_prouni_vac_updated || E'\n' ||
                      '• Registros de ocupação deletados: ' || v_prouni_vac_deleted || E'\n' ||
                      '• Log de origem: ' || p_log_id::text;

    ELSIF v_etl_type = 'prouni_base' THEN
      -- Count vacancies before
      SELECT COUNT(*) INTO v_prouni_vac_before
      FROM public.courses_prouni_vacancies
      WHERE year = v_year AND semester = v_semester;

      -- Count opps before
      SELECT COUNT(*) INTO v_opps_before
      FROM public.opportunities
      WHERE year = v_year 
        AND semester = v_semester 
        AND opportunity_type = 'prouni';

      -- Delete vacancies
      DELETE FROM public.courses_prouni_vacancies 
      WHERE year = v_year AND semester = v_semester;

      -- Delete opps
      DELETE FROM public.opportunities 
      WHERE year = v_year 
        AND semester = v_semester 
        AND opportunity_type = 'prouni';

      -- Count vacancies after
      SELECT COUNT(*) INTO v_prouni_vac_after
      FROM public.courses_prouni_vacancies
      WHERE year = v_year AND semester = v_semester;

      -- Count opps after
      SELECT COUNT(*) INTO v_opps_after
      FROM public.opportunities
      WHERE year = v_year 
        AND semester = v_semester 
        AND opportunity_type = 'prouni';

      v_prouni_vac_deleted := v_prouni_vac_before - v_prouni_vac_after;
      v_opps_deleted := v_opps_before - v_opps_after;

      v_detail_msg := 'Rollback de Base ProUni concluído com sucesso.' || E'\n' ||
                      '• Ciclo: ' || COALESCE(v_year::text, '?') || '.' || COALESCE(v_semester, '?') || E'\n' ||
                      '• Oportunidades (Base) removidas: ' || v_opps_deleted || E'\n' ||
                      '• Registros de vagas/ocupação removidos: ' || v_prouni_vac_deleted || E'\n' ||
                      '• Log de origem: ' || p_log_id::text;

    ELSIF v_etl_type = 'emec' OR v_etl_type LIKE 'refresh_%' THEN
      RAISE EXCEPTION 'Cannot rollback global or refresh ETL operations';
    ELSE
      RAISE EXCEPTION 'Unknown ETL type for rollback';
    END IF;

    UPDATE public.etl_run_logs 
    SET status = 'success', 
        records_processed = COALESCE(v_vacancies_deleted, 0) + COALESCE(v_opps_deleted, 0) + COALESCE(v_prouni_vac_deleted, 0) + COALESCE(v_prouni_vac_updated, 0) + COALESCE(v_sisu_vac_updated, 0),
        errors = v_detail_msg,
        finished_at = now() 
    WHERE id = v_new_log_id;

    RETURN jsonb_build_object(
      'status', 'success',
      'message', 'Rollback completed successfully.',
      'new_log_id', v_new_log_id
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
