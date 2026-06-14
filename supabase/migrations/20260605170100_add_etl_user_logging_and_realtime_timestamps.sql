-- Add user logging and fix transaction-bound timestamps for ETL run logs
-- 20260605170100_add_etl_user_logging_and_realtime_timestamps.sql

-- 1. Add user_id column to etl_run_logs
ALTER TABLE public.etl_run_logs 
  ADD COLUMN user_id UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL;

-- 2. Create trigger to intercept inserts/updates on etl_run_logs
CREATE OR REPLACE FUNCTION public.trg_etl_run_logs_timestamps()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.started_at := clock_timestamp();
    IF NEW.user_id IS NULL THEN
      NEW.user_id := auth.uid();
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.status IN ('success', 'error') AND (OLD.status = 'running' OR OLD.finished_at IS NULL) THEN
      NEW.finished_at := clock_timestamp();
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER etl_run_logs_timestamps_trigger
  BEFORE INSERT OR UPDATE ON public.etl_run_logs
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_etl_run_logs_timestamps();
