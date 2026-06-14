-- 20260608145000_fix_refresh_opportunities_timeout.sql

CREATE OR REPLACE FUNCTION public.etl_import_refresh_opportunities()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '10min'
AS $$
DECLARE
  v_log_id UUID;
  v_errors TEXT;
  v_processed INTEGER := 0;
  v_cycles TEXT;
BEGIN
  INSERT INTO public.etl_run_logs (etl_type, status, started_at)
  VALUES ('refresh_opportunities', 'running', now())
  RETURNING id INTO v_log_id;

  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.v_unified_opportunities;
    
    -- Contar registros pós-refresh
    SELECT count(*) INTO v_processed FROM public.v_unified_opportunities;
    
    -- Listar ciclos ativos sincronizados
    SELECT string_agg(title || ' (' || status || ')', ', ')
    INTO v_cycles
    FROM public.programs 
    WHERE status != 'inactive';
    
  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF v_errors IS NULL THEN
    UPDATE public.etl_run_logs 
    SET status = 'success', 
        records_processed = v_processed, 
        errors = 'Ciclos Sincronizados: ' || COALESCE(v_cycles, 'Nenhum'),
        finished_at = now() 
    WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs 
    SET status = 'error', 
        errors = v_errors, 
        finished_at = now() 
    WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$$;

-- Add statement_timeout to refresh_catalog as well just in case
CREATE OR REPLACE FUNCTION public.etl_import_refresh_catalog()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '10min'
AS $$
DECLARE
  v_log_id UUID;
  v_errors TEXT;
  v_processed INTEGER := 0;
  v_cycles TEXT;
BEGIN
  INSERT INTO public.etl_run_logs (etl_type, status, started_at)
  VALUES ('refresh_catalog', 'running', now())
  RETURNING id INTO v_log_id;

  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_course_catalog;
    
    SELECT count(*) INTO v_processed FROM public.mv_course_catalog;
    
    SELECT string_agg(title || ' (' || status || ')', ', ')
    INTO v_cycles
    FROM public.programs 
    WHERE status != 'inactive';
    
  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF v_errors IS NULL THEN
    UPDATE public.etl_run_logs 
    SET status = 'success', 
        records_processed = v_processed,
        errors = 'Ciclos Sincronizados: ' || COALESCE(v_cycles, 'Nenhum'),
        finished_at = now() 
    WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs SET status = 'error', errors = v_errors, finished_at = now() WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$$;
