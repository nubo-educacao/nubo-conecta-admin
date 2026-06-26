-- Fix foreign key constraint on etl_run_logs by referencing auth.users and add cached user_name
-- 20260605170500_fix_etl_logs_user_id_fk_and_add_user_name.sql

-- 1. Drop old foreign key constraint
ALTER TABLE public.etl_run_logs DROP CONSTRAINT IF EXISTS etl_run_logs_user_id_fkey;

-- 2. Add foreign key referencing auth.users(id) instead of user_profiles(id)
ALTER TABLE public.etl_run_logs 
  ADD CONSTRAINT etl_run_logs_user_id_fkey 
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;

-- 3. Add user_name text column
ALTER TABLE public.etl_run_logs ADD COLUMN IF NOT EXISTS user_name TEXT;

-- 4. Update trigger function to resolve user_name in SECURITY DEFINER context
CREATE OR REPLACE FUNCTION public.trg_etl_run_logs_timestamps()
RETURNS TRIGGER AS $$
DECLARE
  v_user_id UUID;
  v_email TEXT;
  v_full_name TEXT;
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.started_at := clock_timestamp();
    v_user_id := auth.uid();
    NEW.user_id := v_user_id;
    
    IF v_user_id IS NOT NULL THEN
      -- Try to get from user_profiles first
      SELECT full_name INTO v_full_name FROM public.user_profiles WHERE id = v_user_id;
      
      -- If not in profiles, try auth.users
      IF v_full_name IS NULL OR v_full_name = '' THEN
        SELECT email, COALESCE(raw_user_meta_data->>'full_name', email) 
        INTO v_email, v_full_name 
        FROM auth.users WHERE id = v_user_id;
      END IF;
      
      NEW.user_name := COALESCE(v_full_name, v_email, 'Usuário Desconhecido');
    ELSE
      NEW.user_name := 'Sistema / Automatizado';
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.status IN ('success', 'error') AND (OLD.status = 'running' OR OLD.finished_at IS NULL) THEN
      NEW.finished_at := clock_timestamp();
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
