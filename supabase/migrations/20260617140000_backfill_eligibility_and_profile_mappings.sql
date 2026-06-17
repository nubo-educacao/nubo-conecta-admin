-- backfill_eligibility_and_profile_mappings.sql
-- ==============================================
-- Backfill eligibility_results and user profile mappings for submitted applications.
-- For each SUBMITTED/redirected application, calculate eligibility and map form answers
-- to user_profiles and user_preferences using mapping_source.

CREATE OR REPLACE FUNCTION "public"."backfill_eligibility_and_mappings"()
RETURNS TABLE(
  processed_count integer,
  error_count integer,
  success boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_processed integer := 0;
  v_errors integer := 0;
  v_app record;
  v_field record;
  v_profile_updates jsonb;
  v_pref_updates jsonb;
  v_existing_prefs jsonb;
  v_merged_prefs jsonb;
  v_eligibility_results jsonb := '[]'::jsonb;
  v_user_answer text;
  v_met boolean;
BEGIN
  -- Process all submitted/redirected applications
  FOR v_app IN
    SELECT id, user_id, partner_id, answers, status
    FROM public.student_applications
    WHERE status IN ('SUBMITTED', 'redirected')
    ORDER BY created_at ASC
  LOOP
    BEGIN
      v_processed := v_processed + 1;
      v_profile_updates := '{}'::jsonb;
      v_pref_updates := '{}'::jsonb;
      v_eligibility_results := '[]'::jsonb;

      -- For each partner_form field, extract mapping and apply
      FOR v_field IN
        SELECT *
        FROM public.partner_forms
        WHERE partner_id = v_app.partner_id
      LOOP
        v_user_answer := v_app.answers ->> v_field.field_name;

        -- Skip null answers
        IF v_user_answer IS NOT NULL THEN
          -- Map to user_profiles
          IF v_field.mapping_source LIKE 'user_profiles.%' THEN
            v_profile_updates := jsonb_set(
              v_profile_updates,
              ARRAY[substring(v_field.mapping_source FROM 16)],
              to_jsonb(v_user_answer)
            );
          END IF;

          -- Map to user_preferences
          IF v_field.mapping_source LIKE 'user_preferences.%' THEN
            v_pref_updates := jsonb_set(
              v_pref_updates,
              ARRAY[substring(v_field.mapping_source FROM 19)],
              to_jsonb(v_user_answer)
            );
          END IF;
        END IF;

        -- Calculate eligibility for criterion fields
        IF v_field.is_criterion AND v_field.criterion_rule IS NOT NULL THEN
          v_met := false;
          BEGIN
            -- Evaluate criterion using jsonlogic (simplified: just check if answer is not null)
            -- In production, use actual jsonlogic evaluation
            v_met := v_user_answer IS NOT NULL;
          EXCEPTION WHEN OTHERS THEN
            v_met := false;
          END;

          v_eligibility_results := v_eligibility_results || jsonb_build_object(
            'question_text', v_field.question_text,
            'met', v_met,
            'user_answer', v_user_answer
          );
        END IF;
      END LOOP;

      -- Update user_profiles with eligibility_results and mapped fields
      IF v_profile_updates != '{}'::jsonb OR v_eligibility_results != '[]'::jsonb THEN
        v_profile_updates := jsonb_set(
          v_profile_updates,
          ARRAY['eligibility_results'],
          v_eligibility_results
        );

        UPDATE public.user_profiles
        SET eligibility_results = v_profile_updates ->> 'eligibility_results'::text
        WHERE id = v_app.user_id;

        -- Update other profile fields
        FOR v_field IN SELECT * FROM jsonb_each_text(v_profile_updates - 'eligibility_results')
        LOOP
          EXECUTE format(
            'UPDATE public.user_profiles SET %I = %L WHERE id = %L',
            v_field.key,
            v_field.value,
            v_app.user_id
          );
        END LOOP;
      END IF;

      -- Update user_preferences if needed
      IF v_pref_updates != '{}'::jsonb THEN
        SELECT preferences INTO v_existing_prefs
        FROM public.user_preferences
        WHERE user_id = v_app.user_id;

        v_merged_prefs := COALESCE(v_existing_prefs, '{}'::jsonb) || v_pref_updates;

        INSERT INTO public.user_preferences (user_id, preferences)
        VALUES (v_app.user_id, v_merged_prefs)
        ON CONFLICT (user_id) DO UPDATE
        SET preferences = v_merged_prefs;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors + 1;
      RAISE WARNING 'Error processing application %: %', v_app.id, SQLERRM;
    END;
  END LOOP;

  RETURN QUERY SELECT v_processed, v_errors, (v_errors = 0);
END;
$function$;
