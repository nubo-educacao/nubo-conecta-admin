-- 20260608145500_enrich_refresh_logs.sql

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
  
  v_opps_count INTEGER := 0;
  v_inst_count INTEGER := 0;
  v_campus_count INTEGER := 0;
  v_details TEXT;
BEGIN
  INSERT INTO public.etl_run_logs (etl_type, status, started_at)
  VALUES ('refresh_opportunities', 'running', now())
  RETURNING id INTO v_log_id;

  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.v_unified_opportunities;
    
    -- Contar registros pós-refresh
    SELECT count(*) INTO v_processed FROM public.v_unified_opportunities;
    v_opps_count := v_processed;
    
    SELECT count(*) INTO v_inst_count FROM public.v_unified_institutions;
    
    SELECT count(DISTINCT c.campus_id) INTO v_campus_count
    FROM public.opportunities o
    JOIN public.programs p ON p.cycle_year = o.year AND p.cycle_semester = o.semester AND p.type = o.opportunity_type
    JOIN public.courses c ON c.id = o.course_id
    WHERE p.status IN ('incoming', 'opened', 'closed');
    
    -- Listar ciclos ativos sincronizados
    SELECT string_agg(title || ' (' || status || ')', ', ')
    INTO v_cycles
    FROM public.programs 
    WHERE status != 'inactive';
    
    v_details := 'Ciclos Sincronizados: ' || COALESCE(v_cycles, 'Nenhum') || E'\n' ||
                 'Oportunidades (Cursos): ' || v_opps_count || E'\n' ||
                 'Câmpus: ' || COALESCE(v_campus_count, 0) || E'\n' ||
                 'Instituições: ' || v_inst_count;
                 
  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF v_errors IS NULL THEN
    UPDATE public.etl_run_logs 
    SET status = 'success', 
        records_processed = v_processed, 
        errors = v_details,
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

-- Add enriched logs to refresh_catalog as well
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
  v_details TEXT;
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
    
    v_details := 'Ciclos Sincronizados: ' || COALESCE(v_cycles, 'Nenhum') || E'\n' ||
                 'Cursos no Catálogo: ' || v_processed;
                 
  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF v_errors IS NULL THEN
    UPDATE public.etl_run_logs 
    SET status = 'success', 
        records_processed = v_processed,
        errors = v_details,
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
