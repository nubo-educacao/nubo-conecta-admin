-- Migration: Add DB triggers that fire calculate-match-v3 Edge Function asynchronously
-- Sprint 10 — [BACKEND] Refactor Match Engine (Ranking V3)
--
-- Depends on:
--   • 20260430240000_enable_pg_net.sql      (pg_net extension active)
--   • 20260430200000_calculate_match_v3_*   (calculate_match V3 RPC)
--   • 20260406100300_create_user_oppor*.sql (user_opportunity_matches table)
--
-- BDD: Given user preferences are updated
--      When the database trigger fires
--      Then an Edge Function is called asynchronously via pg_net
-- =============================================================================

-- =============================================================================
-- 1. Trigger function: fire calculate-match-v3 via pg_net (fire-and-forget)
--    Reads SUPABASE_URL and SERVICE_ROLE_KEY from database settings.
--    Set these via Supabase Dashboard → Database → Configuration → app.settings
-- =============================================================================

CREATE OR REPLACE FUNCTION public.trg_enqueue_calculate_match_v3()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_supabase_url TEXT;
    v_service_key  TEXT;
    v_profile_id   UUID;
BEGIN
    -- Resolve profile_id: user_preferences and user_enem_scores both use user_id column
    v_profile_id := NEW.user_id;

    v_supabase_url := current_setting('app.settings.supabase_url',    true);
    v_service_key  := current_setting('app.settings.service_role_key', true);

    -- Fail gracefully if settings are absent (e.g. local dev without config)
    IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
        RAISE WARNING 'trg_enqueue_calculate_match_v3: app.settings not configured — skipping async match for profile %', v_profile_id;
        RETURN NEW;
    END IF;

    -- Mark match as queued so the UI can show a loading state
    UPDATE public.user_preferences
       SET match_status  = 'processing',
           last_match_at = now()
     WHERE user_id = v_profile_id;

    -- Asynchronous HTTP POST via pg_net — returns immediately
    PERFORM extensions.http_post(
        url     := v_supabase_url || '/functions/v1/calculate-match-v3',
        headers := jsonb_build_object(
            'Authorization', 'Bearer ' || v_service_key,
            'Content-Type',  'application/json'
        ),
        body    := jsonb_build_object('profile_id', v_profile_id)
    );

    RETURN NEW;
END;
$$;

-- =============================================================================
-- 2. Attach trigger to user_preferences
--    Fires after any INSERT or UPDATE so new profiles and preference changes
--    both kick off a re-rank.
-- =============================================================================

DROP TRIGGER IF EXISTS after_preferences_upsert_enqueue_match_v3
    ON public.user_preferences;

CREATE TRIGGER after_preferences_upsert_enqueue_match_v3
    AFTER INSERT OR UPDATE ON public.user_preferences
    FOR EACH ROW
    EXECUTE FUNCTION public.trg_enqueue_calculate_match_v3();

-- =============================================================================
-- 3. Attach trigger to user_enem_scores
--    Fires when a student submits or corrects a year's scores, so the engine
--    automatically re-evaluates which year produces the best weighted average.
-- =============================================================================

DROP TRIGGER IF EXISTS after_enem_scores_upsert_enqueue_match_v3
    ON public.user_enem_scores;

CREATE TRIGGER after_enem_scores_upsert_enqueue_match_v3
    AFTER INSERT OR UPDATE ON public.user_enem_scores
    FOR EACH ROW
    EXECUTE FUNCTION public.trg_enqueue_calculate_match_v3();
