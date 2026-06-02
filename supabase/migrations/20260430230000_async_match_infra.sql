-- Migration: Async Match Infrastructure
-- Adds state management for background match calculation

-- 1. Update user_preferences table
ALTER TABLE public.user_preferences 
ADD COLUMN IF NOT EXISTS match_status TEXT DEFAULT 'idle', -- idle | processing | ready | error
ADD COLUMN IF NOT EXISTS last_match_at TIMESTAMPTZ;

-- 2. Create worker function
CREATE OR REPLACE FUNCTION public.calculate_match_async_worker(p_profile_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Marcar como processando
    UPDATE public.user_preferences 
    SET match_status = 'processing', last_match_at = now()
    WHERE user_id = p_profile_id;

    -- Executar o motor pesado (V3/V4)
    -- Note: calculate_match returns a table, but here we just want the side effect (inserting into user_opportunity_matches)
    PERFORM public.calculate_match(p_profile_id);

    -- Marcar como concluído
    UPDATE public.user_preferences 
    SET match_status = 'ready'
    WHERE user_id = p_profile_id;
EXCEPTION WHEN OTHERS THEN
    -- Marcar erro em caso de falha
    UPDATE public.user_preferences 
    SET match_status = 'error'
    WHERE user_id = p_profile_id;
    RAISE;
END;
$$;

-- 3. Create the trigger RPC (to be called by Edge Function or directly)
-- This uses pg_net to call the worker via HTTP so it runs in background
CREATE OR REPLACE FUNCTION public.trigger_match_calculation(p_profile_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_net_id BIGINT;
BEGIN
    -- Mark as starting
    UPDATE public.user_preferences 
    SET match_status = 'processing'
    WHERE user_id = p_profile_id;

    -- Call the worker RPC via pg_net (HTTP POST to itself)
    -- This offloads the 30s+ execution to a background request
    SELECT net.http_post(
        url := current_setting('request.header.origin', true) || '/rest/v1/rpc/calculate_match_async_worker',
        headers := jsonb_build_object(
            'Authorization', current_setting('request.header.authorization', true),
            'Content-Type', 'application/json',
            'apikey', current_setting('request.header.apikey', true)
        ),
        body := jsonb_build_object('p_profile_id', p_profile_id)
    ) INTO v_net_id;

    RETURN jsonb_build_object('status', 'accepted', 'job_id', v_net_id);
END;
$$;
