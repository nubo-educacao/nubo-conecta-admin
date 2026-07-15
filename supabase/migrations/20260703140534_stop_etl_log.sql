-- Migration to add etl_stop_log RPC

CREATE OR REPLACE FUNCTION public.etl_stop_log(p_log_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pid INTEGER;
BEGIN
  -- 1. Marcar o log como cancelado no banco
  UPDATE public.etl_run_logs 
  SET status = 'cancelled', errors = 'Cancelado pelo usuário', finished_at = now() 
  WHERE id = p_log_id AND status = 'running';
  
  -- 2. Procurar se há um processo (backend) no PostgreSQL rodando esta importação
  -- Pegamos qualquer query que contenha o ID do log (o PostgREST envia como texto na query RPC)
  SELECT pid INTO v_pid
  FROM pg_stat_activity
  WHERE state != 'idle'
    AND query ILIKE '%etl_import_%'
    AND query ILIKE '%' || p_log_id::text || '%'
    AND pid != pg_backend_pid()
  LIMIT 1;
  
  -- 3. Se encontrar o processo, cancela a query rodando nele (interrompe de verdade no Supabase)
  IF v_pid IS NOT NULL THEN
    PERFORM pg_cancel_backend(v_pid);
  END IF;
  
  RETURN jsonb_build_object('status', 'success', 'pid_cancelled', v_pid);
END;
$$;

GRANT EXECUTE ON FUNCTION public.etl_stop_log(UUID) TO service_role, authenticated;
