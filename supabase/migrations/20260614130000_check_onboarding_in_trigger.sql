-- Migration: Check onboarding completed in match calculation trigger
-- Sprint 15 - onboarding / preference refinement logic cap

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
    v_profile_id := NEW.user_id;

    v_supabase_url := current_setting('app.settings.supabase_url',    true);
    v_service_key  := current_setting('app.settings.service_role_key', true);

    IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
        RAISE WARNING 'trg_enqueue_calculate_match_v3: app.settings not configured — skipping async match for profile %', v_profile_id;
        RETURN NEW;
    END IF;

    -- Skip if onboarding is not completed in auth.users metadata
    IF NOT EXISTS (
        SELECT 1 FROM auth.users
        WHERE id = v_profile_id
          AND raw_user_meta_data->>'onboarding_completed' = 'true'
    ) THEN
        RETURN NEW;
    END IF;

    UPDATE public.user_preferences
       SET match_status  = 'processing',
           last_match_at = now()
     WHERE user_id = v_profile_id;

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
