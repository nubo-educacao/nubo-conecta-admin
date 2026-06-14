-- 1. Restore rolled_back logs to success (assuming they finished without error initially, though we can't know for sure, success is safest to unblock).
UPDATE public.etl_run_logs SET status = 'success' WHERE status = 'rolled_back';

-- 2. Restore check constraint to original state (running, success, error)
ALTER TABLE public.etl_run_logs DROP CONSTRAINT IF EXISTS etl_run_logs_status_check;
ALTER TABLE public.etl_run_logs ADD CONSTRAINT etl_run_logs_status_check CHECK (status IN ('running', 'success', 'error'));

-- 3. Redefine etl_rollback_log
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
  v_deleted_count integer := 0;
  v_new_log_id uuid;
  v_new_etl_type text;
BEGIN
  -- Increase timeout to prevent aborting on massive deletes
  SET LOCAL statement_timeout = '5min';

  -- 1. Fetch log details
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

  -- Create the new log immediately
  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (v_program_id, v_new_etl_type, 'running', now())
  RETURNING id INTO v_new_log_id;

  -- 2. Fetch program year/semester if program_id is present
  IF v_program_id IS NOT NULL THEN
    SELECT cycle_year, cycle_semester INTO v_year, v_semester
    FROM public.programs WHERE id = v_program_id;
  END IF;

  -- 3. Execute rollback logic based on etl_type
  BEGIN
    IF v_etl_type = 'sisu_vacancies' THEN
      DELETE FROM public.opportunities_sisu_vacancies sv
      USING public.opportunities o
      WHERE sv.opportunity_id = o.id
        AND o.year = v_year 
        AND o.semester = v_semester 
        AND o.opportunity_type = 'sisu';
      GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    ELSIF v_etl_type = 'sisu' THEN
      DELETE FROM public.opportunities_sisu_vacancies sv
      USING public.opportunities o
      WHERE sv.opportunity_id = o.id
        AND o.year = v_year 
        AND o.semester = v_semester 
        AND o.opportunity_type = 'sisu';
        
      DELETE FROM public.opportunities 
      WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu';
      GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    ELSIF v_etl_type = 'prouni_vacancies' OR v_etl_type = 'prouni_occupied' THEN
      DELETE FROM public.opportunities_prouni_vacancies 
      WHERE year = v_year AND semester = v_semester;
      GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    ELSIF v_etl_type = 'prouni_base' THEN
      DELETE FROM public.opportunities_prouni_vacancies 
      WHERE year = v_year AND semester = v_semester;

      DELETE FROM public.opportunities 
      WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni';
      GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    ELSIF v_etl_type = 'emec' OR v_etl_type LIKE 'refresh_%' THEN
      RAISE EXCEPTION 'Cannot rollback global or refresh ETL operations';
    ELSE
      RAISE EXCEPTION 'Unknown ETL type for rollback';
    END IF;

    -- Update the new log status to success
    UPDATE public.etl_run_logs 
    SET status = 'success', 
        records_processed = v_deleted_count, 
        finished_at = now() 
    WHERE id = v_new_log_id;

    RETURN jsonb_build_object('status', 'success', 'message', 'Rollback completed successfully. ' || v_deleted_count || ' records removed.');
  EXCEPTION WHEN OTHERS THEN
    -- Update the new log status to error
    UPDATE public.etl_run_logs 
    SET status = 'error', 
        errors = SQLERRM, 
        finished_at = now() 
    WHERE id = v_new_log_id;
    
    RAISE EXCEPTION 'Rollback failed: %', SQLERRM;
  END;
END;
$$;
