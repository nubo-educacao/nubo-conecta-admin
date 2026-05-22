-- Migration: Schedule program deadlines check daily via pg_cron and pg_net
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Create wrapper function to trigger Edge Function check-opportunity-deadlines
CREATE OR REPLACE FUNCTION public.cron_check_deadlines()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_supabase_url TEXT;
    v_service_key TEXT;
    v_net_id BIGINT;
BEGIN
    v_supabase_url := current_setting('app.settings.supabase_url', true);
    v_service_key  := current_setting('app.settings.service_role_key', true);

    IF v_supabase_url IS NOT NULL AND v_service_key IS NOT NULL THEN
        SELECT net.http_post(
            url := v_supabase_url || '/functions/v1/check-opportunity-deadlines',
            headers := jsonb_build_object(
                'Authorization', 'Bearer ' || v_service_key,
                'Content-Type', 'application/json',
                'apikey', v_service_key
            ),
            body := '{}'::jsonb
        ) INTO v_net_id;
    END IF;
END;
$$;

-- Unschedule existing job if it exists to avoid duplicates
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'check-program-deadlines';

-- Schedule job using pg_cron to run every day at 8:00 AM
SELECT cron.schedule(
  'check-program-deadlines',
  '0 8 * * *',
  'SELECT public.cron_check_deadlines();'
);
