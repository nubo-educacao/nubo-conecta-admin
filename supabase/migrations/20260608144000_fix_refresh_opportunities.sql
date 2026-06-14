-- 20260608144000_fix_refresh_opportunities.sql

CREATE OR REPLACE FUNCTION public.etl_import_refresh_opportunities()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_log_id UUID;
BEGIN
  INSERT INTO public.etl_run_logs (etl_type, status, started_at)
  VALUES ('refresh_opportunities', 'running', now())
  RETURNING id INTO v_log_id;

  -- Since v_unified_opportunities is now a regular VIEW (not MATERIALIZED),
  -- we no longer need to REFRESH it. We just log success instantly to keep
  -- the Admin UI pipeline green and functional.

  UPDATE public.etl_run_logs SET status = 'success', records_processed = 0, finished_at = now() WHERE id = v_log_id;

  RETURN jsonb_build_object('processed', 0, 'status', 'success', 'errors', null);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$$;
