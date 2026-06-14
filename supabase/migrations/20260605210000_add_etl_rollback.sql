-- 1. Alter status constraint to include 'rolled_back'
ALTER TABLE public.etl_run_logs DROP CONSTRAINT IF EXISTS etl_run_logs_status_check;
ALTER TABLE public.etl_run_logs ADD CONSTRAINT etl_run_logs_status_check CHECK (status IN ('running', 'success', 'error', 'rolled_back'));

-- 2. Create the rollback RPC
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
BEGIN
  -- 1. Fetch log details
  SELECT program_id, etl_type, status INTO v_program_id, v_etl_type, v_status
  FROM public.etl_run_logs WHERE id = p_log_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Log not found';
  END IF;

  IF v_status = 'rolled_back' THEN
    RAISE EXCEPTION 'This log is already rolled back';
  END IF;

  IF v_status = 'running' THEN
    RAISE EXCEPTION 'Cannot rollback a running ETL operation';
  END IF;

  -- 2. Fetch program year/semester if program_id is present
  IF v_program_id IS NOT NULL THEN
    SELECT cycle_year, cycle_semester INTO v_year, v_semester
    FROM public.programs WHERE id = v_program_id;
  END IF;

  -- 3. Execute rollback logic based on etl_type
  IF v_etl_type = 'sisu_vacancies' THEN
    -- Delete detailed vacancies for this program
    DELETE FROM public.opportunities_sisu_vacancies 
    WHERE opportunity_id IN (
      SELECT id FROM public.opportunities 
      WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu'
    );
  ELSIF v_etl_type = 'sisu' THEN
    -- sisu_vacancies relies on opportunities, so we should clean opportunities
    -- Wait, sisu_vacancies rows depend on opportunities. So if we delete opportunities, 
    -- opportunities_sisu_vacancies might fail if no ON DELETE CASCADE. Let's delete both.
    DELETE FROM public.opportunities_sisu_vacancies 
    WHERE opportunity_id IN (
      SELECT id FROM public.opportunities 
      WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu'
    );
    DELETE FROM public.opportunities 
    WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu';
  ELSIF v_etl_type = 'prouni_vacancies' OR v_etl_type = 'prouni_occupied' THEN
    -- Delete vacancies for prouni
    DELETE FROM public.opportunities_prouni_vacancies 
    WHERE year = v_year AND semester = v_semester;
  ELSIF v_etl_type = 'prouni_base' THEN
    -- Delete prouni vacancies first to avoid FK constraint issues
    DELETE FROM public.opportunities_prouni_vacancies 
    WHERE year = v_year AND semester = v_semester;
    -- Delete opportunities
    DELETE FROM public.opportunities 
    WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni';
  ELSIF v_etl_type = 'emec' OR v_etl_type LIKE 'refresh_%' THEN
    RAISE EXCEPTION 'Cannot rollback global or refresh ETL operations';
  ELSE
    RAISE EXCEPTION 'Unknown ETL type for rollback';
  END IF;

  -- 4. Update log status
  UPDATE public.etl_run_logs SET status = 'rolled_back', updated_at = now() WHERE id = p_log_id;

  RETURN jsonb_build_object('status', 'success', 'message', 'Rollback completed successfully');
END;
$$;

GRANT EXECUTE ON FUNCTION public.etl_rollback_log(uuid) TO authenticated, service_role;
