-- Migration: Fix trigger_match_calculation to use service_role key
-- The previous version relied on request.header.origin which is null
-- when called from Edge Functions. Use SUPABASE_URL and service_role instead.

CREATE OR REPLACE FUNCTION public.trigger_match_calculation(p_profile_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_net_id BIGINT;
    v_supabase_url TEXT;
    v_service_key TEXT;
BEGIN
    -- Read from Supabase Vault / app.settings (set via Dashboard > Database > Settings)
    v_supabase_url := current_setting('app.settings.supabase_url', true);
    v_service_key  := current_setting('app.settings.service_role_key', true);

    IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
        RAISE EXCEPTION 'Missing app.settings.supabase_url or app.settings.service_role_key in database configuration';
    END IF;

    -- Mark as starting
    UPDATE public.user_preferences
    SET match_status = 'processing'
    WHERE user_id = p_profile_id;

    -- Call the worker RPC via pg_net (background HTTP POST)
    SELECT net.http_post(
        url := v_supabase_url || '/rest/v1/rpc/calculate_match_async_worker',
        headers := jsonb_build_object(
            'Authorization', 'Bearer ' || v_service_key,
            'Content-Type', 'application/json',
            'apikey', v_service_key
        ),
        body := jsonb_build_object('p_profile_id', p_profile_id)
    ) INTO v_net_id;

    RETURN jsonb_build_object('status', 'accepted', 'job_id', v_net_id);
END;
$$;
